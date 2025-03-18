#!/bin/bash

# Set error handling
set -e
set -o pipefail

# Source the utils
source "$(dirname "$0")/dokku-migrate-utils.sh"

# Get temporary directory
TEMP_DIR=$(cat "$(dirname "$0")/migration_temp_dir.txt")

# Confirm before proceeding
echo -e "${YELLOW}This script will delete the temporary migration files in:${NC}"
echo -e "${YELLOW}$TEMP_DIR${NC}"
read -p "Do you want to continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo -e "${RED}Cleanup aborted. Temporary files kept in $TEMP_DIR${NC}"
  exit 1
fi

# Remove the temporary directory
rm -rf "$TEMP_DIR"
log "Deleted temporary directory $TEMP_DIR"

# Remove the temp dir file
rm "$(dirname "$0")/migration_temp_dir.txt"
log "Removed migration_temp_dir.txt"

log "${GREEN}Cleanup completed successfully!${NC}"
log "Migration process is now fully complete."
log "Please verify that all apps are working correctly on the destination server."
log "If everything is working, you can safely delete the original apps and databases from the source server."