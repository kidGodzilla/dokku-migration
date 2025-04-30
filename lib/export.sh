#!/bin/bash

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

# If MONGO_DBS isn't set, initialize it as an empty array
if [ -z "${MONGO_DBS+x}" ]; then
    MONGO_DBS=()
fi

# If REDIS_DBS isn't set, initialize it as an empty array
if [ -z "${REDIS_DBS+x}" ]; then
    REDIS_DBS=()
fi

# Create an array of all databases
ALL_DBS=("${DBS[@]}" "${MONGO_DBS[@]}" "${REDIS_DBS[@]}")

# Confirm before proceeding
echo -e "${YELLOW}This script will export the following apps and databases:${NC}"
printf "Apps: %s\n" "${APPS[@]}"
printf "Postgres DBs: %s\n" "${DBS[@]}"
printf "MongoDB DBs: %s\n" "${MONGO_DBS[@]}"
printf "Redis DBs: %s\n" "${REDIS_DBS[@]}"
echo -e "${YELLOW}From $SOURCE_SERVER_NAME ($SOURCE_SERVER_IP)${NC}"
read -p "Do you want to continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo -e "${RED}Export aborted.${NC}"
  exit 1
fi

# Create subdirectories
mkdir -p "$TEMP_DIR/apps"
mkdir -p "$TEMP_DIR/databases"
mkdir -p "$TEMP_DIR/volumes"
mkdir -p "$TEMP_DIR/logs"

# Helper function to get database type
get_db_type() {
  local db="$1"
  
  # Check if db is in MONGO_DBS
  for mongo_db in "${MONGO_DBS[@]}"; do
    if [[ "$db" == "$mongo_db" ]]; then
      echo "mongo"
      return
    fi
  done
  
  # Check if db is in REDIS_DBS
  for redis_db in "${REDIS_DBS[@]}"; do
    if [[ "$db" == "$redis_db" ]]; then
      echo "redis"
      return
    fi
  done
  
  # Default to postgres
  echo "postgres"
}

# Step 1: Export app configurations
log "${GREEN}Step 1: Exporting app configurations from $SOURCE_SERVER_NAME...${NC}"
for app in "${APPS[@]}"; do
  log "Exporting app configuration for $app..."
  
  # Create app directory
  mkdir -p "$TEMP_DIR/apps/$app"
  
  # Get environment variables
  $SOURCE_SSH "dokku config:export $app" > "$TEMP_DIR/apps/$app/env" 2>/dev/null || log "${YELLOW}Failed to export environment variables for $app${NC}"
  log "Exported environment variables for $app"
  
  # Get domains
  $SOURCE_SSH "dokku domains:report $app" > "$TEMP_DIR/apps/$app/domains" 2>/dev/null || log "${YELLOW}Failed to export domains for $app${NC}"
  log "Exported domains for $app"
  
  # Check for persistent storage (volumes)
  volumes=$($SOURCE_SSH "dokku storage:list $app 2>/dev/null || echo 'No volumes'")
  if [[ "$volumes" != "No volumes" ]]; then
    echo "$volumes" > "$TEMP_DIR/apps/$app/volumes"
    log "Exported volume configuration for $app"
    
    # Check if this app needs volume data transfer
    needs_volume_transfer=false
    for volume_app in "${VOLUME_DATA_APPS[@]}"; do
        if [[ "$app" == "$volume_app" ]]; then
            needs_volume_transfer=true
            log "App $app requires volume data transfer"
            break
        fi
    done
    
    if [ "$needs_volume_transfer" = true ]; then
        log "Exporting volume data for $app..."
        mkdir -p "$TEMP_DIR/volumes/$app"
        
        # Process each volume
        while read -r line; do
            # Skip header lines
            if [[ "$line" == *"volume bind-mounts:"* ]]; then
                continue
            fi
            
            # Match the actual volume path format
            if [[ "$line" =~ ^[[:space:]]*\/var\/lib\/dokku\/data\/storage\/([^:]+):\/([^[:space:]]+) ]]; then
                host_path="${BASH_REMATCH[1]}"
                container_path="${BASH_REMATCH[2]}"
                volume_name="$host_path"
                
                log "Found volume: $volume_name"
                log "Source path: /var/lib/dokku/data/storage/$host_path"
                
                # Create tar of the volume
                log "Creating tar archive for volume $volume_name..."
                if $SOURCE_SSH "cd /var/lib/dokku/data/storage && tar -czf /tmp/$volume_name.tar.gz $host_path"; then
                    log "Successfully created tar archive for volume $volume_name"
                    
                    log "Downloading volume archive..."
                    if $SOURCE_SCP "root@$SOURCE_SERVER_IP:/tmp/$volume_name.tar.gz" "$TEMP_DIR/volumes/$app/"; then
                        log "Successfully downloaded volume archive for $volume_name"
                        $SOURCE_SSH "rm /tmp/$volume_name.tar.gz"
                        log "Exported volume $volume_name for $app"
                    else
                        log "${RED}Failed to download volume archive for $volume_name${NC}"
                    fi
                else
                    log "${RED}Failed to create tar archive for volume $volume_name${NC}"
                fi
            fi
        done < "$TEMP_DIR/apps/$app/volumes"
    else
        log "No volume data transfer required for $app"
    fi
  fi
  
  # Get app image
  log "Exporting Docker image for $app..."
  container_id=$($SOURCE_SSH "docker ps -a --filter 'name=$app\.' --format '{{.ID}}' | head -n1")
  if [[ -n "$container_id" ]]; then
    # Get the image ID from the container
    app_image=$($SOURCE_SSH "docker inspect --format='{{.Image}}' $container_id")
    echo "$app_image" > "$TEMP_DIR/apps/$app/image_id"
    
    # Get the image tag
    app_image_tag=$($SOURCE_SSH "docker inspect --format='{{.Config.Image}}' $container_id")
    echo "$app_image_tag" > "$TEMP_DIR/apps/$app/image_tag"
    
    log "Found app image ID: $app_image"
    log "Found app image tag: $app_image_tag"
    
    # Save Docker image
    log "Saving Docker image to tar archive..."
    $SOURCE_SSH "docker save $app_image | gzip > /tmp/$app.docker.tar.gz"
    
    log "Downloading Docker image archive..."
    $SOURCE_SCP "root@$SOURCE_SERVER_IP:/tmp/$app.docker.tar.gz" "$TEMP_DIR/apps/$app/app.docker.tar.gz"
    $SOURCE_SSH "rm /tmp/$app.docker.tar.gz"
    log "Exported Docker image for $app"
  else
    log "${YELLOW}No Docker container/image found for $app${NC}"
  fi
  
  # Get the git URL (for reference)
  $SOURCE_SSH "dokku urls $app" > "$TEMP_DIR/apps/$app/urls" 2>/dev/null || echo "No URLs" > "$TEMP_DIR/apps/$app/urls"
  log "Saved app URLs for $app"

  # Get process scaling information
  $SOURCE_SSH "dokku ps:scale $app" > "$TEMP_DIR/apps/$app/scale" 2>/dev/null || echo "No scaling info" > "$TEMP_DIR/apps/$app/scale"
  log "Exported process scaling configuration for $app"
  
  log "${GREEN}✅ Completed export of app $app${NC}"
done

# Step 2: Export databases
log "${GREEN}Step 2: Exporting databases from $SOURCE_SERVER_NAME...${NC}"
for db in "${ALL_DBS[@]}"; do
  # Get the database type for this database
  db_type=$(get_db_type "$db")
  
  log "Exporting $db_type database: $db..."
  
  # Create a directory for this database
  mkdir -p "$TEMP_DIR/databases/$db_type/$db"
  
  # Save the database type
  echo "$db_type" > "$TEMP_DIR/databases/$db_type/$db/type"
  
  # Check if database exists
  if ! $SOURCE_SSH "dokku $db_type:exists $db" &>/dev/null; then
    log "${RED}Database $db does not exist on source server${NC}"
    continue
  fi
  
  # Export database
  log "Creating database dump for $db_type database $db..."
  
  case "$db_type" in
    postgres)
      # PostgreSQL dump
      $SOURCE_SSH "dokku postgres:export $db" > "$TEMP_DIR/databases/$db_type/$db/data.dump" || log "${RED}Failed to export postgres database $db${NC}"
      
      # Check if dump was successful
      if [ ! -s "$TEMP_DIR/databases/$db_type/$db/data.dump" ]; then
        log "${RED}Database dump for $db is empty or failed${NC}"
        continue
      fi
      ;;
      
    mongo)
      # MongoDB dump
      $SOURCE_SSH "dokku mongo:export $db" > "$TEMP_DIR/databases/$db_type/$db/data.dump" || log "${RED}Failed to export mongo database $db${NC}"
      
      # Check if dump was successful
      if [ ! -s "$TEMP_DIR/databases/$db_type/$db/data.dump" ]; then
        log "${RED}MongoDB dump for $db is empty or failed${NC}"
        continue
      fi
      ;;
      
    redis)
      # Redis dump
      $SOURCE_SSH "dokku redis:export $db" > "$TEMP_DIR/databases/$db_type/$db/data.dump" || log "${RED}Failed to export redis database $db${NC}"
      
      # Check if dump was successful
      if [ ! -s "$TEMP_DIR/databases/$db_type/$db/data.dump" ]; then
        log "${RED}Redis dump for $db is empty or failed${NC}"
        continue
      fi
      ;;
  esac
  
  # Get database info
  $SOURCE_SSH "dokku $db_type:info $db" > "$TEMP_DIR/databases/$db_type/$db/info" 2>/dev/null || log "${YELLOW}Failed to get database info for $db${NC}"
  
  # Try to get DSN if applicable
  if [[ "$db_type" == "postgres" || "$db_type" == "mongo" ]]; then
    if $SOURCE_SSH "dokku $db_type:info $db --dsn" &>/dev/null; then
      $SOURCE_SSH "dokku $db_type:info $db --dsn" > "$TEMP_DIR/databases/$db_type/$db/dsn" || log "${YELLOW}Failed to get database DSN for $db${NC}"
    fi
  fi
  
  log "${GREEN}✅ Completed export of $db_type database $db${NC}"
done

# Create manifest file
log "Creating migration manifest..."
cat > "$TEMP_DIR/manifest.json" << EOF
{
  "timestamp": "$(date +%Y-%m-%d\ %H:%M:%S)",
  "source_server": "$SOURCE_SERVER_NAME ($SOURCE_SERVER_IP)",
  "destination_server": "$DEST_SERVER_NAME ($DEST_SERVER_IP)",
  "apps": [$(printf '"%s",' "${APPS[@]}" | sed 's/,$//')]
}
EOF

# Set permissions
chmod -R 700 "$TEMP_DIR"

log "${GREEN}Export completed successfully!${NC}"
log "All data has been exported to $TEMP_DIR"
log "To import the data, run the import-db command followed by import-apps"

# Create checkpoint
echo "export" > "$TEMP_DIR/checkpoint"