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

# Database type (default to postgres but can be set via environment)
DB_TYPE="${DB_TYPE:-postgres}"

# Test SSH connections
test_connections

# Confirm before proceeding
echo -e "${YELLOW}This script will import the following $DB_TYPE databases:${NC}"
printf "Databases: %s\n" "${DBS[@]}"
echo -e "${YELLOW}To $DEST_SERVER_NAME ($DEST_SERVER_IP)${NC}"
read -p "Do you want to continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo -e "${RED}Database import aborted.${NC}"
  exit 1
fi

# Check if database exists on destination
db_exists_on_dest() {
  local db="$1"
  local output
  
  output=$($DEST_SSH "dokku $DB_TYPE:list" | grep -w "$db" || echo "")
  
  if [[ -n "$output" ]]; then
    return 0  # exists
  else
    return 1  # doesn't exist
  fi
}

# Import databases
log "${GREEN}Importing $DB_TYPE databases to $DEST_SERVER_NAME...${NC}"
for db in "${DBS[@]}"; do
  log "Importing database $db..."
  
  # Check database dump path
  DB_DUMP_PATH="$TEMP_DIR/databases/$db.dump"
  if [ ! -f "$DB_DUMP_PATH" ]; then
      log "${RED}Database dump not found: $DB_DUMP_PATH${NC}"
      log "${YELLOW}Skipping database $db import${NC}"
      continue
  }
 
  # Check if database exists
  if db_exists_on_dest "$db"; then
    read -p "Database $db already exists on destination. Destroy and recreate? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      $DEST_SSH "dokku $DB_TYPE:destroy $db --force"
      log "Destroyed existing database $db on destination"
    else
      log "Skipping database $db import"
      continue
    fi
  fi
 
  # Create the database
  $DEST_SSH "dokku $DB_TYPE:create $db"
  log "Created database $db on destination"
 
  # Upload the database dump
  log "Uploading database dump for $db..."
  $DEST_SCP "$DB_DUMP_PATH" "root@$DEST_SERVER_IP:/tmp/$db.dump"

  # Import the data
  log "Importing database dump..."
  $DEST_SSH "cat /tmp/$db.dump | dokku $DB_TYPE:import $db"

  # Clean up
  $DEST_SSH "rm -f /tmp/$db.dump"
 
  # Verify the import
  log "Verifying database import for $db..."
  $DEST_SSH "dokku $DB_TYPE:info $db"
 
  # Get and save the DSN for later use (if available)
  if $DEST_SSH "dokku $DB_TYPE:info $db --dsn > /dev/null 2>&1"; then
    db_dsn=$($DEST_SSH "dokku $DB_TYPE:info $db --dsn")
    echo "$db_dsn" > "$TEMP_DIR/databases/$db.dsn"
    log "Saved database DSN for $db"
  else
    log "${YELLOW}DSN info not available for $db${NC}"
  fi
done

log "${GREEN}Database import completed successfully!${NC}"
log "To import the apps, run the import-apps command"

# Create checkpoint
echo "import-db" > "$TEMP_DIR/checkpoint"