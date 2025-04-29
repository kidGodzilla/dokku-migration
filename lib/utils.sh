#!/bin/bash

# ===== Color Codes =====
if [ -z "$GREEN" ]; then
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  RED='\033[0;31m'
  BLUE='\033[0;34m'
  NC='\033[0m' # No Color
fi

log() {
  echo -e "$@"
}

# ===== Configuration Functions =====
# Function to validate required config variables
validate_config() {
  local errors=0
  
  if [ -z "$SOURCE_SERVER_IP" ]; then
    echo -e "${RED}ERROR: SOURCE_SERVER_IP is not set${NC}"
    ((errors++))
  fi
  
  if [ -z "$DEST_SERVER_IP" ]; then
    echo -e "${RED}ERROR: DEST_SERVER_IP is not set${NC}"
    ((errors++))
  fi
  
  if [ ${#APPS[@]} -eq 0 ]; then
    echo -e "${RED}ERROR: No apps specified for migration${NC}"
    ((errors++))
  fi
  
  if [ ${#DBS[@]} -eq 0 ]; then
    echo -e "${RED}ERROR: No databases specified for migration${NC}"
    ((errors++))
  fi
  
  return $errors
}

# ===== Server Connection Functions =====
# Function to test SSH connection
test_ssh_connection() {
  local server_name="$1"
  local ssh_command="$2"
  
  echo -e "Testing connection to $server_name..."
  if $ssh_command "echo 'Connection successful'" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Connection to $server_name successful${NC}"
    return 0
  else
    echo -e "${RED}✗ Failed to connect to $server_name${NC}"
    return 1
  fi
}

test_connections() {
  test_ssh_connection "$SOURCE_SERVER_NAME" "$SOURCE_SSH"
  test_ssh_connection "$DEST_SERVER_NAME" "$DEST_SSH"
}

# ===== Resource Existence Check Functions =====
# Function to check if app exists
app_exists() {
  local app="$1"
  local ssh_command="$2"
  
  $ssh_command "dokku apps:exists $app" &> /dev/null
  return $?
}

app_exists_on_dest() {
  local app="$1"
  $DEST_SSH "dokku apps:exists $app" &> /dev/null
}

# Function to check if database exists
db_exists() {
  local db="$1"
  local db_type="${2:-postgres}"
  local ssh_command="$3"
  
  $ssh_command "dokku $db_type:exists $db" &> /dev/null
  return $?
}

# ===== Environment Variables Functions =====
# Function to import environment variables
import_env_vars() {
  local app="$1"
  local env_file="$2"
  local ssh_command="$3"
  
  # Create a temporary script to parse and import the environment variables
  local temp_script=$(mktemp)
  
  cat > "$temp_script" << 'EOF'
#!/bin/bash
app="$1"
env_file="$2"

# Check if file exists
if [ ! -f "$env_file" ]; then
  echo "Environment file $env_file not found"
  exit 1
fi

# Read each line and extract key/value pairs
while IFS= read -r line || [[ -n "$line" ]]; do
  # Skip empty lines and comments
  if [[ -z "$line" || "$line" == \#* ]]; then
    continue
  fi
  
  # Extract key and value, handling 'export' prefix
  if [[ "$line" =~ ^(export[[:space:]]+)?([^=]+)=(.*)$ ]]; then
    key="${BASH_REMATCH[2]}"
    value="${BASH_REMATCH[3]}"
    
    # Remove all types of quotes (single and double)
    # First, remove surrounding double quotes
    value="${value#\"}"
    value="${value%\"}"
    
    # Then, remove surrounding single quotes
    value="${value#\'}"
    value="${value%\'}"
    
    echo "Setting $key"
    
    # Set the environment variable
    dokku config:set "$app" "$key=$value" --no-restart
  fi
done < "$env_file"

echo "Environment variables imported for $app"
EOF
  
  chmod +x "$temp_script"
  local temp_script_name=$(basename "$temp_script")
  
  # Copy the script to the server
  scp_command=$(echo "$ssh_command" | sed 's/ssh/scp/' | sed 's/ root@.*$//')
  $scp_command "$temp_script" "root@$(echo "$ssh_command" | grep -oP '(?<=root@)[^\s]+')":/tmp/
  $ssh_command "chmod +x /tmp/$temp_script_name"
  
  # Copy the env file to the server
  local env_file_name=$(basename "$env_file")
  $scp_command "$env_file" "root@$(echo "$ssh_command" | grep -oP '(?<=root@)[^\s]+')":/tmp/
  
  # Execute the script
  $ssh_command "bash /tmp/$temp_script_name $app /tmp/$env_file_name"
  
  # Clean up
  $ssh_command "rm /tmp/$temp_script_name /tmp/$env_file_name"
  rm "$temp_script"
}

import_env_vars2() {
  local app="$1"
  local env_file="$2"
  local ssh_command="$3"
  local scp_command="$4"
  local server_ip="$5"
  
  log "Importing environment variables for $app..."
  
  # Create a temporary script to parse and import the environment variables
  local temp_script=$(mktemp)
  
  cat > "$temp_script" << 'EOF'
#!/bin/bash
app="\$1"
env_file="\$2"

# Check if file exists
if [ ! -f "\$env_file" ]; then
  echo "Environment file \$env_file not found"
  exit 1
fi

# Read each line and extract key/value pairs
while IFS= read -r line || [[ -n "\$line" ]]; do
  if [[ -z "\$line" || "\$line" == \#* ]]; then
    continue
  fi
  
  if [[ "\$line" =~ ^(export[[:space:]]+)?([^=]+)=(.*)\$ ]]; then
    key="\${BASH_REMATCH[2]}"
    value="\${BASH_REMATCH[3]}"
    
    # Remove quotes
    value="\${value#\"}"
    value="\${value%\"}"
    value="\${value#\'}"
    value="\${value%\'}"
    
    echo "Setting \$key"
    
    dokku config:set "\$app" "\$key=\$value" --no-restart
  fi
done < "\$env_file"

echo "Environment variables imported for \$app"
EOF

  chmod +x "$temp_script"
  local temp_script_name=$(basename "$temp_script")
  
  # Copy temp script
  $scp_command "$temp_script" "root@$server_ip:/tmp/$temp_script_name"
  $ssh_command "chmod +x /tmp/$temp_script_name"
  
  # Copy env file
  local env_file_name=$(basename "$env_file")
  $scp_command "$env_file" "root@$server_ip:/tmp/$env_file_name"
  
  # Execute script
  $ssh_command "bash /tmp/$temp_script_name $app /tmp/$env_file_name"
  
  # Cleanup
  $ssh_command "rm /tmp/$temp_script_name /tmp/$env_file_name"
  rm "$temp_script"
}

# ===== Database Functions =====
# Function to disable foreign key constraints
disable_foreign_keys() {
  local db="$1"
  local db_type="${2:-postgres}"
  local ssh_command="$3"
  
  $ssh_command "dokku $db_type:connect $db -c 'SET session_replication_role = replica;'" || true
}

# Function to enable foreign key constraints
enable_foreign_keys() {
  local db="$1"
  local db_type="${2:-postgres}"
  local ssh_command="$3"
  
  $ssh_command "dokku $db_type:connect $db -c 'SET session_replication_role = DEFAULT;'" || true
}

# ===== File Size Functions =====
# Function to get file size in MB
get_file_size_mb() {
  local file="$1"
  local size_bytes=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file")
  echo $((size_bytes/1024/1024))
}

# Function to check if enough disk space is available
check_disk_space() {
  local ssh_command="$1"
  local required_mb="$2"
  
  local available_mb=$($ssh_command "df -m / | tail -1 | awk '{print \$4}'")
  
  if [ "$available_mb" -lt "$required_mb" ]; then
    return 1
  else
    return 0
  fi
}

# ===== Progress Functions =====
# Function to show a simple progress indicator
show_progress() {
  local current="$1"
  local total="$2"
  local width=50
  local percentage=$((current * 100 / total))
  local filled=$((width * current / total))
  local empty=$((width - filled))
  
  printf "\r["
  printf "%${filled}s" | tr ' ' '#'
  printf "%${empty}s" | tr ' ' ' '
  printf "] %d%%" "$percentage"
}

# Function to extract domain names from dokku domains report
extract_domains() {
  local domains_file="$1"
  
  if [ ! -f "$domains_file" ]; then
    echo ""
    return
  fi
  
  grep "Domains app vhosts:" "$domains_file" | sed 's/Domains app vhosts://' | tr -d ' ' | tr ',' ' '
}

# ===== Validation Functions =====
# Function to validate app deployment
validate_app_deployment() {
  local app="$1"
  local ssh_command="$2"
  
  # Check if app exists
  if ! app_exists "$app" "$ssh_command"; then
    echo -e "${RED}App $app does not exist${NC}"
    return 1
  fi
  
  # Check if app is running
  local app_status=$($ssh_command "dokku ps:report $app --format json" 2>/dev/null | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
  
  if [ "$app_status" != "running" ]; then
    echo -e "${RED}App $app is not running (status: $app_status)${NC}"
    return 1
  fi
  
  # Check if app has domains
  local has_domains=$($ssh_command "dokku domains:report $app" | grep -c "Domains app vhosts:")
  
  if [ "$has_domains" -eq 0 ]; then
    echo -e "${YELLOW}Warning: App $app has no custom domains${NC}"
  fi
  
  echo -e "${GREEN}App $app is deployed and running${NC}"
  return 0
}

# Function to get the app's database
get_app_database() {
  local app="$1"
  
  # Check if APP_DB_MAP is defined
  if [ -n "$APP_DB_MAP" ]; then
    echo "${APP_DB_MAP[$app]}"
  else
    # Try to guess the database name
    case "$app" in
      *-staging) echo "${app%-staging}-staging-db" ;;
      *) echo "$app-db" ;;
    esac
  fi
}

# Function to check if app is a Prisma app
is_prisma_app() {
  local app="$1"
  
  for prisma_app in "${PRISMA_APPS[@]}"; do
    if [ "$app" = "$prisma_app" ]; then
      return 0
    fi
  done
  
  return 1
}

# Function to check if app needs volume data transfer
needs_volume_transfer() {
  local app="$1"
  
  for volume_app in "${VOLUME_DATA_APPS[@]}"; do
    if [ "$app" = "$volume_app" ]; then
      return 0
    fi
  done
  
  return 1
}
