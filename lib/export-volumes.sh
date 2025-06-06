#!/bin/bash

set -e
set -o pipefail

# Get last migration temp dir
if [ ! -f "/root/.dokku-migration/tmp/last_migration" ]; then
    echo -e "${RED}Error: Could not find last migration file${NC}"
    exit 1
fi

TEMP_DIR=$(cat "/root/.dokku-migration/tmp/last_migration")
if [ ! -d "$TEMP_DIR" ]; then
    echo -e "${RED}Error: Migration directory $TEMP_DIR does not exist${NC}"
    exit 1
fi

# Source the config file
if [ ! -f "/root/.dokku-migration-config" ]; then
    echo -e "${RED}Error: Could not find config file${NC}"
    exit 1
fi
source "/root/.dokku-migration-config"

# Source utility functions
source "$(dirname "$0")/utils.sh"

# Debug SSH connection
echo "Debugging SSH connection..."
echo "Source server: $SOURCE_SERVER_IP"
echo "Source port: $SOURCE_SERVER_PORT"
echo "Source key: $SOURCE_SERVER_KEY"
echo "SSH command: $SOURCE_SSH"

# Test SSH connection directly
echo "Testing direct SSH connection..."
if ! ssh -i "$SOURCE_SERVER_KEY" -p "$SOURCE_SERVER_PORT" root@"$SOURCE_SERVER_IP" "echo 'SSH connection successful'"; then
    echo -e "${RED}Failed to connect to source server${NC}"
    echo "Please check:"
    echo "1. SSH key permissions (should be 600)"
    echo "2. SSH key is correct"
    echo "3. Server is accessible"
    echo "4. Port is correct"
    echo "5. User has access"
    exit 1
fi

# Confirm before proceeding
echo -e "${YELLOW}This script will export volume data for the following apps:${NC}"
printf "Apps: %s\n" "${VOLUME_DATA_APPS[@]}"
echo -e "${YELLOW}From $SOURCE_SERVER_NAME ($SOURCE_SERVER_IP)${NC}"
read -p "Do you want to continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${RED}Volume export aborted.${NC}"
    exit 1
fi

# Create volumes directory if it doesn't exist
mkdir -p "$TEMP_DIR/volumes"

# Export volume data for each app
for app in "${VOLUME_DATA_APPS[@]}"; do
    log "Processing volume data for $app..."
    
    # Check if app exists on source server using direct SSH command
    if ! ssh -i "$SOURCE_SERVER_KEY" -p "$SOURCE_SERVER_PORT" root@"$SOURCE_SERVER_IP" "dokku apps:exists $app" &>/dev/null; then
        log "${RED}App $app does not exist on source server${NC}"
        continue
    fi
    
    # Get volume configuration using direct SSH command
    volumes=$(ssh -i "$SOURCE_SERVER_KEY" -p "$SOURCE_SERVER_PORT" root@"$SOURCE_SERVER_IP" "dokku storage:list $app 2>/dev/null || echo 'No volumes'")
    if [[ "$volumes" == "No volumes" ]]; then
        log "${YELLOW}No volumes found for app $app${NC}"
        continue
    fi
    
    # Save volume configuration
    echo "$volumes" > "$TEMP_DIR/apps/$app/volumes"
    log "Saved volume configuration for $app"
    
    # Create app volumes directory
    mkdir -p "$TEMP_DIR/volumes/$app"
    
    # Debug: Print the volumes content
    echo "Debug: Volumes content for $app:"
    echo "$volumes"
    
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
            
            # Check if volume directory exists on source using direct SSH command
            if ! ssh -i "$SOURCE_SERVER_KEY" -p "$SOURCE_SERVER_PORT" root@"$SOURCE_SERVER_IP" "[ -d \"/var/lib/dokku/data/storage/$host_path\" ]"; then
                log "${RED}Volume directory not found on source: /var/lib/dokku/data/storage/$host_path${NC}"
                continue
            fi
            
            # Create tar of the volume using direct SSH command
            log "Creating tar archive for volume $volume_name..."
            if ssh -i "$SOURCE_SERVER_KEY" -p "$SOURCE_SERVER_PORT" root@"$SOURCE_SERVER_IP" "cd /var/lib/dokku/data/storage && tar -czf /tmp/$volume_name.tar.gz $host_path"; then
                log "Successfully created tar archive for volume $volume_name"
                
                # Download the tar archive using direct SCP command
                log "Downloading volume archive..."
                if scp -i "$SOURCE_SERVER_KEY" -P "$SOURCE_SERVER_PORT" "root@$SOURCE_SERVER_IP:/tmp/$volume_name.tar.gz" "$TEMP_DIR/volumes/$app/"; then
                    log "Successfully downloaded volume archive for $volume_name"
                    ssh -i "$SOURCE_SERVER_KEY" -p "$SOURCE_SERVER_PORT" root@"$SOURCE_SERVER_IP" "rm /tmp/$volume_name.tar.gz"
                    log "Exported volume $volume_name for $app"
                    
                    # Verify the file was downloaded
                    if [ -f "$TEMP_DIR/volumes/$app/$volume_name.tar.gz" ]; then
                        log "Verified downloaded file: $TEMP_DIR/volumes/$app/$volume_name.tar.gz"
                    else
                        log "${RED}Failed to verify downloaded file: $TEMP_DIR/volumes/$app/$volume_name.tar.gz${NC}"
                    fi
                else
                    log "${RED}Failed to download volume archive for $volume_name${NC}"
                fi
            else
                log "${RED}Failed to create tar archive for volume $volume_name${NC}"
            fi
        else
            log "Debug: Line did not match volume pattern: $line"
        fi
    done < <(echo "$volumes")
    
    log "${GREEN}✅ Completed volume export for app $app${NC}"
done

log "${GREEN}Volume export completed successfully!${NC}"
log "All volume data has been exported to $TEMP_DIR/volumes"

# Create checkpoint
echo "export-volumes" > "$TEMP_DIR/checkpoint" 