#!/bin/bash

# Get last migration temp dir
if [ ! -f "/root/.dokku-migration/tmp/last_migration" ]; then
    echo "Error: Could not find last migration file"
    exit 1
fi

TEMP_DIR=$(cat "/root/.dokku-migration/tmp/last_migration")
CONFIG_FILE="$TEMP_DIR/config.sh"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file not found: $CONFIG_FILE"
    exit 1
fi

# Source the main config file to get values
if [ ! -f "/root/.dokku-migration-config" ]; then
    echo "Error: Could not find main config file"
    exit 1
fi
source "/root/.dokku-migration-config"

echo "Updating config file $CONFIG_FILE"

# Add MONGO_DBS array
echo "Adding MONGO_DBS array with: displays-qzsktbqije profiles-mvsooxlpdbs states-vhlwzyths"
sed -i "/# Let's Encrypt configuration/i\\
\\
# Define MongoDB databases\\
MONGO_DBS=('displays-qzsktbqije' 'profiles-mvsooxlpdbs' 'states-vhlwzyths')\\
" "$CONFIG_FILE"

# Add REDIS_DBS array
echo "Adding REDIS_DBS array with: bq-kdrjoeevnc"
sed -i "/# Let's Encrypt configuration/i\\
# Define Redis databases\\
REDIS_DBS=('bq-kdrjoeevnc')\\
" "$CONFIG_FILE"

echo "Config file updated: $CONFIG_FILE" 