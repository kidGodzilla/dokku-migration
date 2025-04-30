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

# Debug: Show config file contents
echo "DEBUG: Config file contents from $CONFIG_FILE"
cat "$CONFIG_FILE"
echo "END OF CONFIG FILE"

# Source the config file
echo "Sourcing config file: $CONFIG_FILE"
source "$CONFIG_FILE"

# Source utility functions
source "$(dirname "$0")/utils.sh"

# DEBUG: Show arrays exactly as they appear
echo "===== DEBUG: ARRAY CONTENTS ====="
echo "DBS array declaration: DBS=(${DBS[@]@Q})"
echo "MONGO_DBS array declaration: MONGO_DBS=(${MONGO_DBS[@]@Q})"
echo "REDIS_DBS array declaration: REDIS_DBS=(${REDIS_DBS[@]@Q})"
echo "DBS count: ${#DBS[@]}"
echo "MONGO_DBS count: ${#MONGO_DBS[@]}"
echo "REDIS_DBS count: ${#REDIS_DBS[@]}"

# DEBUG: Verify array contents with loop
echo "DBS array contents:"
for i in "${!DBS[@]}"; do
    echo "  [$i] = ${DBS[$i]}"
done

echo "MONGO_DBS array contents:"
for i in "${!MONGO_DBS[@]}"; do
    echo "  [$i] = ${MONGO_DBS[$i]}"
done

echo "REDIS_DBS array contents:"
for i in "${!REDIS_DBS[@]}"; do
    echo "  [$i] = ${REDIS_DBS[$i]}"
done

# If MONGO_DBS isn't set, initialize it as an empty array
if [ -z "${MONGO_DBS+x}" ]; then
    echo "MONGO_DBS not set, initializing as empty array"
    MONGO_DBS=()
fi

# If REDIS_DBS isn't set, initialize it as an empty array
if [ -z "${REDIS_DBS+x}" ]; then
    echo "REDIS_DBS not set, initializing as empty array"
    REDIS_DBS=()
fi

# Create an array of all databases
ALL_DBS=("${DBS[@]}" "${MONGO_DBS[@]}" "${REDIS_DBS[@]}")

# DEBUG: Verify ALL_DBS contents
echo "ALL_DBS array contents:"
for i in "${!ALL_DBS[@]}"; do
    echo "  [$i] = ${ALL_DBS[$i]}"
done

# Test SSH connections
test_connections

# More detailed output for DB lists
echo "DEBUG DB ARRAYS IN DETAIL:"
echo "Postgres DBs (${#DBS[@]} total):"
for idx in "${!DBS[@]}"; do
    echo "  $idx: ${DBS[$idx]}"
done

echo "MongoDB DBs (${#MONGO_DBS[@]} total):"
for idx in "${!MONGO_DBS[@]}"; do
    echo "  $idx: ${MONGO_DBS[$idx]}"
done

echo "Redis DBs (${#REDIS_DBS[@]} total):"
for idx in "${!REDIS_DBS[@]}"; do
    echo "  $idx: ${REDIS_DBS[$idx]}"
done

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
  
  # DEBUG: Show what we're checking
  echo "DEBUG: Checking type for db=$db"
  
  # Check if db is in MONGO_DBS
  for mongo_db in "${MONGO_DBS[@]}"; do
    echo "  Comparing with mongo_db=$mongo_db"
    if [[ "$db" == "$mongo_db" ]]; then
      echo "  MATCH FOUND in MONGO_DBS!"
      echo "mongo"
      return
    fi
  done
  
  # Check if db is in REDIS_DBS
  for redis_db in "${REDIS_DBS[@]}"; do
    echo "  Comparing with redis_db=$redis_db"
    if [[ "$db" == "$redis_db" ]]; then
      echo "  MATCH FOUND in REDIS_DBS!"
      echo "redis"
      return
    fi
  done
  
  # Default to postgres
  echo "  No match in special arrays, defaulting to postgres"
  echo "postgres"
}

# DEBUG: Test get_db_type function for each database
echo "===== TESTING TYPE DETECTION ====="
for db in "${ALL_DBS[@]}"; do
    echo "Testing type detection for $db:"
    db_type=$(get_db_type "$db")
    echo "Result: $db is a $db_type database"
    echo ""
done

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

# Debug database types
log "Debug: Checking database types..."
for db in "${ALL_DBS[@]}"; do
  db_type=$(get_db_type "$db")
  log "Database $db is of type $db_type"
done

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
