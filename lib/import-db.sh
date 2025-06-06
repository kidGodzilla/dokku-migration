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

# If MONGO_DBS isn't set, initialize it as an empty array
if [ -z "${MONGO_DBS+x}" ]; then
    log "MONGO_DBS not set, initializing as empty array"
    MONGO_DBS=()
fi

# If REDIS_DBS isn't set, initialize it as an empty array
if [ -z "${REDIS_DBS+x}" ]; then
    log "REDIS_DBS not set, initializing as empty array"
    REDIS_DBS=()
fi

# Create an array of all databases
ALL_DBS=("${DBS[@]}" "${MONGO_DBS[@]}" "${REDIS_DBS[@]}")

# Test SSH connections
test_connections

# Confirm before proceeding
echo -e "${YELLOW}This script will import the following databases:${NC}"
echo "Postgres DBs:"
for db in "${DBS[@]}"; do
    echo "  - $db"
done

echo "MongoDB DBs:"
for db in "${MONGO_DBS[@]}"; do
    echo "  - $db"
done

echo "Redis DBs:"
for db in "${REDIS_DBS[@]}"; do
    echo "  - $db"
done
echo -e "${YELLOW}To $DEST_SERVER_NAME ($DEST_SERVER_IP)${NC}"
read -p "Do you want to continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo -e "${RED}Database import aborted.${NC}"
  exit 1
fi

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

# Check if database exists on destination
db_exists_on_dest() {
  local db="$1"
  local db_type="$2"
  local output
  
  output=$($DEST_SSH "dokku $db_type:list" | grep -w "$db" || echo "")
  
  if [[ -n "$output" ]]; then
    return 0  # exists
  else
    return 1  # doesn't exist
  fi
}

# Import databases
log "${GREEN}Importing databases to $DEST_SERVER_NAME...${NC}"
for db in "${ALL_DBS[@]}"; do
  # Get the database type for this database
  db_type=$(get_db_type "$db")
  
  log "Importing $db_type database: $db..."
  
  # Check database dump path
  DB_DUMP_PATH="$TEMP_DIR/databases/$db_type/$db/data.dump"
  if [ ! -f "$DB_DUMP_PATH" ]; then
      log "${RED}Database dump not found: $DB_DUMP_PATH${NC}"
      log "${YELLOW}Skipping database $db import${NC}"
      continue
  fi
 
  # Check if database exists
  if db_exists_on_dest "$db" "$db_type"; then
    read -p "Database $db already exists on destination. Destroy and recreate? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      $DEST_SSH "dokku $db_type:destroy $db --force"
      log "Destroyed existing database $db on destination"
    else
      log "Skipping database $db import"
      continue
    fi
  fi
 
  # Create the database
  $DEST_SSH "dokku $db_type:create $db"
  log "Created database $db on destination"
 
  # Upload the database dump
  log "Uploading database dump for $db..."
  $DEST_SCP "$DB_DUMP_PATH" "root@$DEST_SERVER_IP:/tmp/$db.dump"

  # Import the data
  log "Importing database dump..."
  case "$db_type" in
    postgres)
      $DEST_SSH "cat /tmp/$db.dump | dokku postgres:import $db"
      ;;
    mongo)
      $DEST_SSH "cat /tmp/$db.dump | dokku mongo:import $db"
      ;;
    redis)
      $DEST_SSH "cat /tmp/$db.dump | dokku redis:import $db"
      ;;
  esac

  # Clean up
  $DEST_SSH "rm -f /tmp/$db.dump"
 
  # Verify the import
  log "Verifying database import for $db..."
  $DEST_SSH "dokku $db_type:info $db"
 
  # Get and save the DSN for later use (if available for this database type)
  if [[ "$db_type" == "postgres" || "$db_type" == "mongo" ]]; then
    if $DEST_SSH "dokku $db_type:info $db --dsn > /dev/null 2>&1"; then
      db_dsn=$($DEST_SSH "dokku $db_type:info $db --dsn")
      echo "$db_dsn" > "$TEMP_DIR/databases/$db_type/$db/dsn.new"
      log "Saved database DSN for $db"
    else
      log "${YELLOW}DSN info not available for $db${NC}"
    fi
  fi
  
  log "${GREEN}✅ Completed import of $db_type database $db${NC}"
done

log "${GREEN}Database import completed successfully!${NC}"
log "To import the apps, run the import-apps command"

# Create checkpoint
echo "import-db" > "$TEMP_DIR/checkpoint"
