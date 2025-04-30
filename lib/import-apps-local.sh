#!/bin/bash

set -e
set -o pipefail

# Source colors and utility functions
source "$(dirname "$0")/utils.sh"

# Read the last migration directory
if [ ! -f "/root/.dokku-migration/tmp/last_migration" ]; then
    log "${RED}Error: Could not find last migration file${NC}"
    exit 1
fi

TEMP_DIR=$(cat "/root/.dokku-migration/tmp/last_migration")
if [ ! -d "$TEMP_DIR" ]; then
    log "${RED}Error: Migration directory $TEMP_DIR does not exist${NC}"
    exit 1
fi

# Source the config file
if [ ! -f "/root/.dokku-migration-config" ]; then
    log "${RED}Error: Could not find config file${NC}"
    exit 1
fi
source "/root/.dokku-migration-config"

# Validate and initialize APP_DB_MAP if needed
if [ ${#APP_DB_MAP[@]} -eq 0 ]; then
    log "WARNING: APP_DB_MAP is empty, creating default mapping"
    declare -A APP_DB_MAP
    for ((i=0; i<${#APPS[@]}; i++)); do
        if [ $i -lt ${#DBS[@]} ]; then
            APP_DB_MAP[${APPS[$i]}]=${DBS[$i]}
            log "Mapped app ${APPS[$i]} to database ${DBS[$i]}"
        fi
    done
fi

# Confirm before proceeding
echo -e "${YELLOW}This script will import the following apps:${NC}"
printf "Apps: %s\n" "${APPS[@]}"
read -p "Do you want to continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${RED}App import aborted.${NC}"
    exit 1
fi

# Import apps
log "${GREEN}Importing apps...${NC}"
for app in "${APPS[@]}"; do
    log "Importing app $app..."
    
    # Check if app already exists
    if dokku apps:exists "$app" &>/dev/null; then
        read -p "App $app already exists. Destroy and recreate? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            dokku apps:destroy "$app" --force
            log "Destroyed existing app $app"
        else
            log "Skipping app $app import"
            continue
        fi
    fi
    
    # Create the app
    dokku apps:create "$app"
    log "Created app $app"
    
    # Import Docker image if available
    if [ -f "$TEMP_DIR/apps/$app/app.docker.tar.gz" ]; then
        log "Importing Docker image for $app..."
        docker load < "$TEMP_DIR/apps/$app/app.docker.tar.gz"
        
        # Get image ID and tag
        app_image_id=$(cat "$TEMP_DIR/apps/$app/image_id" 2>/dev/null || echo "")
        app_image_tag=$(cat "$TEMP_DIR/apps/$app/image_tag" 2>/dev/null || echo "")
        
        if [[ -n "$app_image_id" && -n "$app_image_tag" ]]; then
            # Tag the image directly as dokku app image
            docker tag "$app_image_id" "dokku/$app:latest"
            log "Tagged Docker image for $app"
        else
            log "WARNING: Missing image ID or tag for $app"
        fi
        
        log "Imported Docker image for $app"
    else
        log "WARNING: No Docker image available for $app."
    fi
    
    # Import environment variables
    if [ -f "$TEMP_DIR/apps/$app/env" ]; then
        # Read each line and set environment variables
        while IFS= read -r line; do
            if [[ -n "$line" && "$line" != "#"* ]]; then
                # Remove 'export' keyword if present
                key_value="${line#export }"
                # Strip any single or double quotes from the value
                key_value=$(echo "$key_value" | sed -E "s/^([^=]+)=['\"](.*)['\"]$/\1=\2/")
                dokku config:set "$app" "$key_value" --no-restart
            fi
        done < "$TEMP_DIR/apps/$app/env"
        log "Imported environment variables for $app"
    else
        log "WARNING: No environment file found for $app"
    fi
    
    # Link database if needed
    if [ -n "${APP_DB_MAP[$app]}" ]; then
        db_name="${APP_DB_MAP[$app]}"
        log "Linking database $db_name to app $app..."
        
        # Get the database type
        db_type="postgres"  # Default to postgres
        
        # Check if it's in MONGO_DBS
        for mongo_db in "${MONGO_DBS[@]}"; do
          if [[ "$db_name" == "$mongo_db" ]]; then
            db_type="mongo"
            break
          fi
        done
        
        # Check if it's in REDIS_DBS
        for redis_db in "${REDIS_DBS[@]}"; do
          if [[ "$db_name" == "$redis_db" ]]; then
            db_type="redis"
            break
          fi
        done
        
        # Check if database exists before linking
        if ! dokku "$db_type:exists" "$db_name" &>/dev/null; then
            log "${RED}Database $db_name does not exist${NC}"
            log "${YELLOW}Please run the database import first${NC}"
        else
            # Unlink first in case it was previously linked
            dokku "$db_type:unlink" "$db_name" "$app" || true
            
            # Link the database
            dokku "$db_type:link" "$db_name" "$app"
            log "Linked database $db_name to app $app"
        fi
    fi
    
    # Import volume configuration (if exists)
    if [ -f "$TEMP_DIR/apps/$app/volumes" ]; then
        log "Importing volume configuration for $app..."
        
        # Check if app needs volume data transfer
        needs_volume_transfer=false
        for volume_app in "${VOLUME_DATA_APPS[@]}"; do
            if [[ "$app" == "$volume_app" ]]; then
                needs_volume_transfer=true
                log "App $app requires volume data transfer"
                break
            fi
        done
        
        if [ "$needs_volume_transfer" = true ]; then
            log "Processing volume data transfer for $app"
            while read -r line; do
                if [[ "$line" =~ ^[[:space:]]*\/var\/lib\/dokku\/data\/storage\/([^:]+):\/([^[:space:]]+) ]]; then
                    host_path="${BASH_REMATCH[1]}"
                    container_path="${BASH_REMATCH[2]}"
                    
                    log "Found volume: $host_path"
                    log "Source path: $TEMP_DIR/volumes/$app/$host_path.tar.gz"
                    
                    # Transfer and extract volume data
                    if [ -f "$TEMP_DIR/volumes/$app/$host_path.tar.gz" ]; then
                        log "Extracting volume data for $host_path"
                        mkdir -p "/var/lib/dokku/data/storage/$host_path"
                        tar -xzf "$TEMP_DIR/volumes/$app/$host_path.tar.gz" -C "/var/lib/dokku/data/storage/"
                        log "Imported volume data for $host_path"
                    else
                        log "WARNING: Volume data file not found: $TEMP_DIR/volumes/$app/$host_path.tar.gz"
                    fi
                    
                    # Mount the volume
                    dokku storage:mount "$app" "/var/lib/dokku/data/storage/$host_path:/$container_path"
                    log "Mounted volume $host_path for $app"
                fi
            done < "$TEMP_DIR/apps/$app/volumes"
        else
            log "No volume data transfer required for $app"
            # For other apps, just recreate the mounts without data transfer
            while read -r line; do
                if [[ "$line" =~ ^[[:space:]]*\/var\/lib\/dokku\/data\/storage\/([^:]+):\/([^[:space:]]+) ]]; then
                    host_path="${BASH_REMATCH[1]}"
                    container_path="${BASH_REMATCH[2]}"
                    
                    # Create directory and mount
                    mkdir -p "/var/lib/dokku/data/storage/$host_path"
                    dokku storage:mount "$app" "/var/lib/dokku/data/storage/$host_path:/$container_path"
                    log "Mounted volume $host_path for $app"
                fi
            done < "$TEMP_DIR/apps/$app/volumes"
        fi
    fi
    
    # Set up domains
    if [ -f "$TEMP_DIR/apps/$app/domains" ]; then
        # Read domains and split by space
        domains=$(grep "Domains app vhosts:" "$TEMP_DIR/apps/$app/domains" | sed 's/Domains app vhosts://')
        # Split into array, preserving spaces between domains
        read -ra DOMAIN_LIST <<< "$domains"
        
        # Clear existing domains including the default domain
        dokku domains:clear "$app"
        
        # Remove the default domain explicitly
        default_domain=$(hostname -f)
        dokku domains:remove "$app" "$app.$default_domain" || true
        
        # Add each custom domain
        for domain in "${DOMAIN_LIST[@]}"; do
            if [ -n "$domain" ] && [ "$domain" != "null" ]; then
                dokku domains:add "$app" "$domain"
                log "Added domain $domain to $app"
            fi
        done
        
        # Verify domains after setup
        dokku domains:report "$app"
        log "Verified domain configuration for $app"
    fi
    
#    # Set up Let's Encrypt with email
#    dokku letsencrypt:set "$app" email "$LETSENCRYPT_EMAIL"
#    log "Set Let's Encrypt email for $app"
#    dokku letsencrypt:enable "$app" || true
#    log "Attempted to enable Let's Encrypt for $app"
#
#    # Only set up Let's Encrypt if this app is in the LETSENCRYPT_APPS array
#    if [[ " ${LETSENCRYPT_APPS[@]} " =~ " ${app} " ]]; then
#        dokku letsencrypt:set "$app" email "$LETSENCRYPT_EMAIL"
#        log "Set Let's Encrypt email for $app"
#        dokku letsencrypt:enable "$app" || true
#        log "Enabled Let's Encrypt for $app"
#    fi
    
    # Deploy the app
    dokku ps:rebuild "$app" || true
    log "Attempted to rebuild app $app"
    
    # Restart the app
    dokku ps:restart "$app" || true
    log "Attempted to restart app $app"

    # Apply process scaling if information exists
    if [ -f "$TEMP_DIR/apps/$app/scale" ]; then
        log "Setting up process scaling for $app..."
        
        # Skip the header lines and process the actual scale information
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
                # Only add to process_scales if count is a valid positive number
                if [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -gt 0 ]; then
                    process_scales["$process"]=$count
                else
                    log "WARNING: Invalid process count '$count' for process '$process'"
                fi
            fi
        done < "$TEMP_DIR/apps/$app/scale"
        
        # Build the scale command with all process types at once
        scale_cmd=""
        for process in "${!process_scales[@]}"; do
            count="${process_scales[$process]}"
            scale_cmd+="$process=$count "
        done
        
        # Apply the scaling if we have any processes to scale
        if [ -n "$scale_cmd" ]; then
            dokku ps:scale "$app" $scale_cmd
            log "Scaled $app processes: $scale_cmd"
            
            # Ensure processes are started
            dokku ps:start "$app"
            log "Started processes for $app with proper scaling"
        else
            log "No valid process scaling found for $app"
        fi
    else
        log "No process scaling information found for $app"
    fi

    # After all config changes, restart the app once
    dokku ps:restart "$app"
    log "Restarted app $app after all configuration changes"
done

log "${GREEN}App import completed successfully!${NC}"

# Create checkpoint
echo "import-apps" > "$TEMP_DIR/checkpoint" 