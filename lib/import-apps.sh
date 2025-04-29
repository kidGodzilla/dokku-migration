#!/bin/bash

# Set error handling
set -e
set -o pipefail

# Default config file
CONFIG_FILE=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check if config file is provided
if [ -z "$CONFIG_FILE" ]; then
    echo "Error: Config file is required"
    echo "Usage: $0 -c CONFIG_FILE"
    exit 1
fi

# Source the config file
source "$CONFIG_FILE"

# Source utility functions
source "$(dirname "$0")/utils.sh"

# Test SSH connections
test_connections

# Confirm before proceeding
echo -e "${YELLOW}This script will import the following apps:${NC}"
printf "Apps: %s\n" "${APPS[@]}"
echo -e "${YELLOW}To $DEST_SERVER_NAME ($DEST_SERVER_IP)${NC}"
read -p "Do you want to continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo -e "${RED}App import aborted.${NC}"
  exit 1
fi

# Import apps
log "${GREEN}Importing apps to $DEST_SERVER_NAME...${NC}"
for app in "${APPS[@]}"; do
  log "Importing app $app..."
  
  # Check if app already exists
  if app_exists_on_dest "$app"; then
    read -p "App $app already exists on destination. Destroy and recreate? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      $DEST_SSH "dokku apps:destroy $app --force"
      log "Destroyed existing app $app on destination"
    else
      log "Skipping app $app import"
      continue
    fi
  fi
  
  # Create the app
  $DEST_SSH "dokku apps:create $app"
  log "Created app $app on destination"
  
  # Import Docker image if available
  if [ -f "$TEMP_DIR/apps/$app/app.docker.tar.gz" ]; then
    log "Importing Docker image for $app..."
    $DEST_SCP "$TEMP_DIR/apps/$app/app.docker.tar.gz" "root@$DEST_SERVER_IP:/tmp/"
    $DEST_SSH "docker load < /tmp/app.docker.tar.gz"
    $DEST_SSH "rm /tmp/app.docker.tar.gz"
    
    # Get image ID and tag
    app_image_id=$(cat "$TEMP_DIR/apps/$app/image_id" 2>/dev/null || echo "")
    app_image_tag=$(cat "$TEMP_DIR/apps/$app/image_tag" 2>/dev/null || echo "")
    
    if [[ -n "$app_image_id" && -n "$app_image_tag" ]]; then
      # Tag the image directly as dokku app image
      $DEST_SSH "docker tag $app_image_id dokku/$app:latest"
      log "Tagged Docker image for $app"
    else
      log "WARNING: Missing image ID or tag for $app"
    fi
    
    log "Imported Docker image for $app"
  else
    log "WARNING: No Docker image available for $app."
  fi
  
  # Import environment variables using custom function
  if [ -f "$TEMP_DIR/apps/$app/env" ]; then
    import_env_vars "$app" "$TEMP_DIR/apps/$app/env" "$DEST_SSH" "$DEST_SCP" "$DEST_SERVER_IP"
    log "Imported environment variables for $app"
  else
    log "WARNING: No environment file found for $app"
  fi
  
  # Link the database using APP_DB_MAP
  db_name=""
  if [ -n "${APP_DB_MAP[$app]}" ]; then
    db_name="${APP_DB_MAP[$app]}"
  fi

  if [ -n "$db_name" ]; then
    log "Linking database $db_name to app $app..."
    
    # Check if database exists before linking
    if ! db_exists_on_dest "$db_name"; then
      log "ERROR: Database $db_name does not exist on destination."
      log "Please run the database import script first."
      exit 1
    fi
    
    # Unlink first in case it was previously linked
    $DEST_SSH "dokku postgres:unlink $db_name $app" || true
    
    # Link the database
    $DEST_SSH "dokku postgres:link $db_name $app"
    log "Linked database $db_name to app $app"
    
    # Get the database DSN from saved file or directly
    if [ -f "$TEMP_DIR/databases/$db_name.dsn" ]; then
      db_dsn=$(cat "$TEMP_DIR/databases/$db_name.dsn")
    else
      db_dsn=$($DEST_SSH "dokku postgres:info $db_name --dsn")
    fi
    
    # Set DATABASE_URL explicitly
    $DEST_SSH "dokku config:set $app DATABASE_URL='$db_dsn'"
    log "Explicitly set DATABASE_URL for $app"
    
    # Verify DATABASE_URL is set correctly
    has_db_url=$($DEST_SSH "dokku config:get $app DATABASE_URL || echo ''")
    if [ -z "$has_db_url" ]; then
      log "ERROR: Failed to set DATABASE_URL for $app"
    else
      log "DATABASE_URL is properly set for $app"
    fi
    
    # For Prisma applications, set the direct connection URL if needed
    for prisma_app in "${PRISMA_APPS[@]}"; do
      if [[ "$app" == "$prisma_app" ]]; then
        # Extract host, port, user, password and database from DSN
        if [[ "$db_dsn" =~ postgres://([^:]+):([^@]+)@([^:]+):([^/]+)/(.+) ]]; then
          db_user="${BASH_REMATCH[1]}"
          db_pass="${BASH_REMATCH[2]}"
          db_host="${BASH_REMATCH[3]}"
          db_port="${BASH_REMATCH[4]}"
          db_name="${BASH_REMATCH[5]}"
          
          # Set direct URL for Prisma
          direct_url="postgresql://${db_user}:${db_pass}@${db_host}:${db_port}/${db_name}?schema=public"
          $DEST_SSH "dokku config:set $app DIRECT_URL='$direct_url'"
          log "Set DIRECT_URL for Prisma in $app"
        fi
        break
      fi
    done
  else
    log "No database mapping found for app $app"
  fi
  
  # Import volume configuration (if exists)
  if [ -f "$TEMP_DIR/apps/$app/volumes" ]; then
    log "Importing volume configuration for $app..."
    
    # Check if app needs volume data transfer
    needs_volume_transfer=false
    for volume_app in "${VOLUME_DATA_APPS[@]}"; do
      if [[ "$app" == "$volume_app" ]]; then
        needs_volume_transfer=true
        break
      fi
    done
    
    if [ "$needs_volume_transfer" = true ]; then
      while read -r line; do
        if [[ "$line" =~ \/var\/lib\/dokku\/data\/storage\/(.*):\/(.*)\ \[(.*)\] ]]; then
          host_path="${BASH_REMATCH[1]}"
          container_path="${BASH_REMATCH[2]}"
          permissions="${BASH_REMATCH[3]}"
          volume_name=$(basename "$host_path")
          
          # Transfer and extract volume data
          if [ -f "$TEMP_DIR/volumes/$app/$volume_name.tar.gz" ]; then
            $DEST_SCP "$TEMP_DIR/volumes/$app/$volume_name.tar.gz" "root@$DEST_SERVER_IP:/tmp/"
            $DEST_SSH "mkdir -p /var/lib/dokku/data/storage/$host_path && tar -xzf /tmp/$volume_name.tar.gz -C /var/lib/dokku/data/storage/ && rm /tmp/$volume_name.tar.gz"
            log "Imported volume data for $volume_name"
          fi
          
          # Mount the volume
          $DEST_SSH "dokku storage:mount $app /var/lib/dokku/data/storage/$host_path:$container_path:$permissions"
          log "Mounted volume $volume_name for $app"
        fi
      done < "$TEMP_DIR/apps/$app/volumes"
    else
      # For other apps, just recreate the mounts without data transfer
      while read -r line; do
        if [[ "$line" =~ \/var\/lib\/dokku\/data\/storage\/(.*):\/(.*)\ \[(.*)\] ]]; then
          host_path="${BASH_REMATCH[1]}"
          container_path="${BASH_REMATCH[2]}"
          permissions="${BASH_REMATCH[3]}"
          
          # Create directory and mount
          $DEST_SSH "mkdir -p /var/lib/dokku/data/storage/$host_path"
          $DEST_SSH "dokku storage:mount $app /var/lib/dokku/data/storage/$host_path:$container_path:$permissions"
          log "Mounted volume $host_path for $app"
        fi
      done < "$TEMP_DIR/apps/$app/volumes"
    fi
  fi
  
  # Set up domains
  if [ -f "$TEMP_DIR/apps/$app/domains" ]; then
    domains=$(grep "Domains app vhosts:" "$TEMP_DIR/apps/$app/domains" | sed 's/Domains app vhosts://' | tr -d ' ')
    IFS=',' read -ra DOMAIN_LIST <<< "$domains"
    
    # Clear existing domains including the default domain
    $DEST_SSH "dokku domains:clear $app"
    
    # Remove the default domain explicitly
    default_domain=$($DEST_SSH "hostname -f" | tr -d '\n')
    $DEST_SSH "dokku domains:remove $app $app.$default_domain" || true
    
    # Add each custom domain
    for domain in "${DOMAIN_LIST[@]}"; do
      if [ -n "$domain" ] && [ "$domain" != "null" ]; then
        $DEST_SSH "dokku domains:add $app $domain"
        log "Added domain $domain to $app"
      fi
    done
    
    # Verify domains after setup
    $DEST_SSH "dokku domains:report $app"
    log "Verified domain configuration for $app"
  fi
  
  # Set up Let's Encrypt with email
  $DEST_SSH "dokku letsencrypt:set $app email $LETSENCRYPT_EMAIL"
  log "Set Let's Encrypt email for $app"
  $DEST_SSH "dokku letsencrypt:enable $app" || true
  log "Attempted to enable Let's Encrypt for $app"
  
  # Deploy the app
  $DEST_SSH "dokku ps:rebuild $app" || true
  log "Attempted to rebuild app $app"
  
  # Restart the app
  $DEST_SSH "dokku ps:restart $app" || true
  log "Attempted to restart app $app"

  # Apply process scaling if information exists
  if [ -f "$TEMP_DIR/apps/$app/scale" ]; then
    log "Setting up process scaling for $app..."
    
    # Skip the header lines and process the actual scale information
    # Format is typically:
    # -----> Scaling for app
    # proctype: qty
    # --------: ---
    # web:  1
    # worker:  2
    
    # Read the file line by line, skipping header lines
    process_section=false
    declare -A process_scales
    
    while IFS= read -r line; do
      # Check if we've reached the actual process data section
      if [[ "$line" =~ ^-+:\ -+ ]]; then
        process_section=true
        continue
      fi
      
      # Process the scale information once we're in the right section
      if [ "$process_section" = true ] && [[ "$line" =~ ([a-zA-Z0-9_\-]+):\ +([0-9]+) ]]; then
        process="${BASH_REMATCH[1]}"
        count="${BASH_REMATCH[2]}"
        process_scales["$process"]=$count
      fi
    done < "$TEMP_DIR/apps/$app/scale"
    
    # Build the scale command with all process types at once
    scale_cmd=""
    for process in "${!process_scales[@]}"; do
      count="${process_scales[$process]}"
      if [ "$count" -gt 0 ]; then
        scale_cmd+="$process=$count "
      fi
    done
    
    # Apply the scaling if we have any processes to scale
    if [ -n "$scale_cmd" ]; then
      $DEST_SSH "dokku ps:scale $app $scale_cmd"
      log "Scaled $app processes: $scale_cmd"
      
      # Ensure processes are started
      $DEST_SSH "dokku ps:start $app"
      log "Started processes for $app with proper scaling"
    else
      log "No valid process scaling found for $app"
    fi
  else
    log "No process scaling information found for $app"
  fi
done

log "${GREEN}App import completed successfully!${NC}"
log "To clean up the temporary files, run the cleanup command"

# Create checkpoint
echo "import-apps" > "$TEMP_DIR/checkpoint"
