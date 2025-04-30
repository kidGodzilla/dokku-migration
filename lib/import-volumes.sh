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

# Confirm before proceeding
echo -e "${YELLOW}This script will import volume data for the following apps:${NC}"
printf "Apps with volumes: %s\n" "${VOLUME_DATA_APPS[@]}"
read -p "Do you want to continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${RED}Volume import aborted.${NC}"
    exit 1
fi

# Create the necessary directories
mkdir -p "/var/lib/dokku/data/storage"

# Import volume data for each app
for app in "${VOLUME_DATA_APPS[@]}"; do
    log "Processing volume data for $app..."
    
    # Check if app exists
    if ! dokku apps:exists "$app" &>/dev/null; then
        log "${RED}App $app does not exist${NC}"
        log "${YELLOW}Create the app first before importing volumes${NC}"
        continue
    fi
    
    # Check if volume directory exists in the temp dir
    if [ ! -d "$TEMP_DIR/volumes/$app" ]; then
        log "${YELLOW}No volume data found for $app in $TEMP_DIR/volumes/$app${NC}"
        continue
    fi
    
    # Check if there are any tar files in the volume directory
    volume_archives=$(find "$TEMP_DIR/volumes/$app" -name "*.tar.gz" -type f)
    if [ -z "$volume_archives" ]; then
        log "${YELLOW}No volume archives found for $app${NC}"
        continue
    fi
    
    log "Found volume archives for $app"
    
    # Get volume configuration from the exported data
    if [ ! -f "$TEMP_DIR/apps/$app/volumes" ]; then
        log "${YELLOW}No volume configuration found for $app${NC}"
        continue
    fi
    
    # Process each volume archive
    for archive in $volume_archives; do
        volume_name=$(basename "$archive" .tar.gz)
        log "Processing volume archive: $volume_name"
        
        # Extract volume data
        log "Extracting volume data to /var/lib/dokku/data/storage..."
        if tar -xzf "$archive" -C "/var/lib/dokku/data/storage/"; then
            log "${GREEN}Successfully extracted volume data for $volume_name${NC}"
        else
            log "${RED}Failed to extract volume data for $volume_name${NC}"
            continue
        fi
    done
    
    # Process volume mounts from the configuration
    log "Configuring volume mounts for $app..."
    
    while read -r line; do
        # Skip header lines
        if [[ "$line" == *"volume bind-mounts:"* ]]; then
            continue
        fi
        
        # Match the volume path format
        if [[ "$line" =~ ^[[:space:]]*\/var\/lib\/dokku\/data\/storage\/([^:]+):\/([^[:space:]]+) ]]; then
            host_path="${BASH_REMATCH[1]}"
            container_path="${BASH_REMATCH[2]}"
            
            log "Found mount: /var/lib/dokku/data/storage/$host_path:/$container_path"
            
            # Check if directory exists
            if [ ! -d "/var/lib/dokku/data/storage/$host_path" ]; then
                log "${YELLOW}Warning: Directory /var/lib/dokku/data/storage/$host_path does not exist${NC}"
                log "Creating directory..."
                mkdir -p "/var/lib/dokku/data/storage/$host_path"
            fi
            
            # Mount the volume exactly as in docs
            mount_path="/var/lib/dokku/data/storage/$host_path:/$container_path"
            log "Mounting volume for $app: $mount_path"
            if dokku storage:mount "$app" "$mount_path"; then
                log "${GREEN}Successfully mounted volume for $app${NC}"
            else
                log "${RED}Failed to mount volume for $app${NC}"
            fi
        fi
    done < "$TEMP_DIR/apps/$app/volumes"
    
    log "${GREEN}✅ Completed volume import for app $app${NC}"
done

log "${GREEN}Volume import completed successfully!${NC}"

# Create checkpoint
echo "import-volumes" > "$TEMP_DIR/checkpoint" 