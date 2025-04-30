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
echo -e "${YELLOW}This script will export the following databases:${NC}"
printf "Postgres DBs: %s\n" "${DBS[@]}"
printf "MongoDB DBs: %s\n" "${MONGO_DBS[@]}"
printf "Redis DBs: %s\n" "${REDIS_DBS[@]}"
echo -e "${YELLOW}From $SOURCE_SERVER_NAME ($SOURCE_SERVER_IP)${NC}"
read -p "Do you want to continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${RED}Database export aborted.${NC}"
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

# Create databases directory if it doesn't exist
mkdir -p "$TEMP_DIR/databases"

# Export databases
log "${GREEN}Exporting databases from $SOURCE_SERVER_NAME...${NC}"
for db in "${ALL_DBS[@]}"; do
  # Get the database type for this database
  db_type=$(get_db_type "$db")
  
  log "Exporting $db_type database: $db..."
  
  # Create a directory for this database
  mkdir -p "$TEMP_DIR/databases/$db_type/$db"
  
  # Save the database type
  echo "$db_type" > "$TEMP_DIR/databases/$db_type/$db/type"
  
  # Check if database exists on source server using direct SSH command
  if ! ssh -i "$SOURCE_SERVER_KEY" -p "$SOURCE_SERVER_PORT" root@"$SOURCE_SERVER_IP" "dokku $db_type:exists $db" &>/dev/null; then
      log "${RED}Database $db does not exist on source server${NC}"
      continue
  fi
  
  # Export database
  log "Creating database dump for $db_type database $db..."
  
  case "$db_type" in
    postgres)
      # PostgreSQL dump
      ssh -i "$SOURCE_SERVER_KEY" -p "$SOURCE_SERVER_PORT" root@"$SOURCE_SERVER_IP" "dokku postgres:export $db" > "$TEMP_DIR/databases/$db_type/$db/data.dump" || log "${RED}Failed to export postgres database $db${NC}"
      
      # Check if dump was successful
      if [ ! -s "$TEMP_DIR/databases/$db_type/$db/data.dump" ]; then
        log "${RED}Database dump for $db is empty or failed${NC}"
        continue
      fi
      ;;
      
    mongo)
      # MongoDB dump
      ssh -i "$SOURCE_SERVER_KEY" -p "$SOURCE_SERVER_PORT" root@"$SOURCE_SERVER_IP" "dokku mongo:export $db" > "$TEMP_DIR/databases/$db_type/$db/data.dump" || log "${RED}Failed to export mongo database $db${NC}"
      
      # Check if dump was successful
      if [ ! -s "$TEMP_DIR/databases/$db_type/$db/data.dump" ]; then
        log "${RED}MongoDB dump for $db is empty or failed${NC}"
        continue
      fi
      ;;
      
    redis)
      # Redis dump
      ssh -i "$SOURCE_SERVER_KEY" -p "$SOURCE_SERVER_PORT" root@"$SOURCE_SERVER_IP" "dokku redis:export $db" > "$TEMP_DIR/databases/$db_type/$db/data.dump" || log "${RED}Failed to export redis database $db${NC}"
      
      # Check if dump was successful
      if [ ! -s "$TEMP_DIR/databases/$db_type/$db/data.dump" ]; then
        log "${RED}Redis dump for $db is empty or failed${NC}"
        continue
      fi
      ;;
  esac
  
  # Get database info
  ssh -i "$SOURCE_SERVER_KEY" -p "$SOURCE_SERVER_PORT" root@"$SOURCE_SERVER_IP" "dokku $db_type:info $db" > "$TEMP_DIR/databases/$db_type/$db/info" 2>/dev/null || log "${YELLOW}Failed to get database info for $db${NC}"
  
  # Try to get DSN if applicable
  if [[ "$db_type" == "postgres" || "$db_type" == "mongo" ]]; then
    if ssh -i "$SOURCE_SERVER_KEY" -p "$SOURCE_SERVER_PORT" root@"$SOURCE_SERVER_IP" "dokku $db_type:info $db --dsn" &>/dev/null; then
      ssh -i "$SOURCE_SERVER_KEY" -p "$SOURCE_SERVER_PORT" root@"$SOURCE_SERVER_IP" "dokku $db_type:info $db --dsn" > "$TEMP_DIR/databases/$db_type/$db/dsn" || log "${YELLOW}Failed to get database DSN for $db${NC}"
    fi
  fi
  
  log "${GREEN}✅ Completed export of $db_type database $db${NC}"
done

log "${GREEN}Database export completed successfully!${NC}"
log "All database data has been exported to $TEMP_DIR/databases"

# Create checkpoint
echo "export-dbs" > "$TEMP_DIR/checkpoint" 