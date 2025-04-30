#!/bin/bash

VERSION="0.1.0"
TOOL_DIR="$(dirname "$(readlink -f "$0")")"
DEFAULT_CONFIG_FILE="${HOME}/.dokku-migration-config"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print banner
print_banner() {
    echo -e "${BLUE}"
    echo "╔════════════════════════════════════════════════╗"
    echo "║                                                ║"
    echo "║              Dokku Migration Tool              ║"
    echo "║                                                ║"
    echo "║                    v${VERSION}                      ║"
    echo "║                                                ║"
    echo "╚════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Print help
print_help() {
    echo -e "Usage: dokku-migration [OPTIONS] COMMAND"
    echo
    echo -e "A tool for migrating Dokku applications and databases between servers."
    echo
    echo -e "Commands:"
    echo -e "  export              Export data from source server"
    echo -e "  import-db           Import databases to destination server"
    echo -e "  import-apps         Import applications to destination server"
    echo -e "  cleanup             Clean up temporary files"
    echo -e "  run-all             Run complete migration (all steps)"
    echo -e "  version             Display version information"
    echo
    echo -e "Options:"
    echo -e "  -c, --config FILE   Use specific config file (default: ~/.dokku-migration-config)"
    echo -e "  -s, --source IP     Source server IP address"
    echo -e "  -d, --dest IP       Destination server IP address"
    echo -e "  --source-port PORT  Source server SSH port (default: 22)"
    echo -e "  --dest-port PORT    Destination server SSH port (default: 22)"
    echo -e "  --source-key FILE   Source server SSH key file (default: ~/.ssh/id_rsa)"
    echo -e "  --dest-key FILE     Destination server SSH key file (default: ~/.ssh/id_rsa)"
    echo -e "  --apps \"app1 app2\"  Space-separated list of apps to migrate"
    echo -e "  --dbs \"db1 db2\"     Space-separated list of databases to migrate"
    echo -e "  --email EMAIL       Email for Let's Encrypt certificates"
    echo -e "  -v, --verbose       Enable verbose output"
    echo -e "  -h, --help          Display this help message"
    echo
    echo -e "Examples:"
    echo -e "  dokku-migration --config /path/to/config run-all"
    echo -e "  dokku-migration -s 192.168.1.10 -d 192.168.1.20 export"
    echo -e "  dokku-migration --apps \"app1 app2\" --dbs \"db1 db2\" run-all"
}

# Load config file
load_config() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        echo -e "${RED}Config file not found: $config_file${NC}"
        exit 1
    fi
    
    source "$config_file"
    
    # Set defaults if not specified in config
    SOURCE_SERVER_PORT="${SOURCE_SERVER_PORT:-22}"
    DEST_SERVER_PORT="${DEST_SERVER_PORT:-22}"
    SOURCE_SERVER_KEY="${SOURCE_SERVER_KEY:-~/.ssh/id_rsa}"
    DEST_SERVER_KEY="${DEST_SERVER_KEY:-~/.ssh/id_rsa}"
    SOURCE_SERVER_NAME="${SOURCE_SERVER_NAME:-source}"
    DEST_SERVER_NAME="${DEST_SERVER_NAME:-destination}"
    
    # Override with command line parameters if provided
    [ -n "$CLI_SOURCE_IP" ] && SOURCE_SERVER_IP="$CLI_SOURCE_IP"
    [ -n "$CLI_DEST_IP" ] && DEST_SERVER_IP="$CLI_DEST_IP"
    [ -n "$CLI_SOURCE_PORT" ] && SOURCE_SERVER_PORT="$CLI_SOURCE_PORT"
    [ -n "$CLI_DEST_PORT" ] && DEST_SERVER_PORT="$CLI_DEST_PORT"
    [ -n "$CLI_SOURCE_KEY" ] && SOURCE_SERVER_KEY="$CLI_SOURCE_KEY"
    [ -n "$CLI_DEST_KEY" ] && DEST_SERVER_KEY="$CLI_DEST_KEY"
    [ -n "$CLI_EMAIL" ] && LETSENCRYPT_EMAIL="$CLI_EMAIL"
    
    if [ -n "$CLI_APPS" ]; then
        # Convert space-separated list to array
        IFS=' ' read -r -a APPS <<< "$CLI_APPS"
    fi
    
    if [ -n "$CLI_DBS" ]; then
        # Convert space-separated list to array
        IFS=' ' read -r -a DBS <<< "$CLI_DBS"
    fi
    
    # Define SSH commands
    SOURCE_SSH="ssh -i $SOURCE_SERVER_KEY -p $SOURCE_SERVER_PORT root@$SOURCE_SERVER_IP"
    DEST_SSH="ssh -i $DEST_SERVER_KEY -p $DEST_SERVER_PORT root@$DEST_SERVER_IP"

    # Define SCP commands
    SOURCE_SCP="scp -i $SOURCE_SERVER_KEY -P $SOURCE_SERVER_PORT"
    DEST_SCP="scp -i $DEST_SERVER_KEY -P $DEST_SERVER_PORT"
    
    # Validate required config
    if [ -z "$SOURCE_SERVER_IP" ]; then
        echo -e "${RED}Source server IP is required${NC}"
        exit 1
    fi
    
    if [ -z "$DEST_SERVER_IP" ]; then
        echo -e "${RED}Destination server IP is required${NC}"
        exit 1
    fi
    
    if [ ${#APPS[@]} -eq 0 ]; then
        echo -e "${RED}No apps specified for migration${NC}"
        exit 1
    fi
    
    if [ ${#DBS[@]} -eq 0 ]; then
        echo -e "${RED}No databases specified for migration${NC}"
        exit 1
    fi
    
    # Create app-database mapping if not specified
    if [ -z "$APP_DB_MAP" ]; then
        declare -A APP_DB_MAP
        for ((i=0; i<${#APPS[@]}; i++)); do
            if [ $i -lt ${#DBS[@]} ]; then
                APP_DB_MAP[${APPS[$i]}]=${DBS[$i]}
            fi
        done
    fi
    
    # Set Prisma apps if not specified
    if [ -z "$PRISMA_APPS" ]; then
        PRISMA_APPS=()
    fi
    
    # Set volume data apps if not specified
    if [ -z "$VOLUME_DATA_APPS" ]; then
        VOLUME_DATA_APPS=()
    fi
}

# Export command
run_export() {
    echo -e "${GREEN}Running export command...${NC}"
    TEMP_DIR="$TOOL_DIR/tmp/migration_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$TEMP_DIR"
    
    # Create temporary config file
    create_temp_config "$TEMP_DIR"
    
    # Run export script
    "$TOOL_DIR/lib/export.sh" -c "$TEMP_DIR/config.sh"
    
    echo -e "${GREEN}Export completed successfully!${NC}"
    echo -e "Temporary directory: ${YELLOW}$TEMP_DIR${NC}"
    
    # Save temp dir for other commands
    echo "$TEMP_DIR" > "$TOOL_DIR/tmp/last_migration"
}

# Import database command
run_import_db() {
    echo -e "${GREEN}Running database import command...${NC}"
    
    # Get last migration temp dir
    if [ -f "$TOOL_DIR/tmp/last_migration" ]; then
        TEMP_DIR=$(cat "$TOOL_DIR/tmp/last_migration")
    else
        echo -e "${RED}No previous migration found. Run export first.${NC}"
        exit 1
    fi
    
    # Run import-db script
    "$TOOL_DIR/lib/import-db.sh" -c "$TEMP_DIR/config.sh"
    
    echo -e "${GREEN}Database import completed successfully!${NC}"
}

# Import apps command
run_import_apps() {
    echo -e "${GREEN}Running apps import command...${NC}"
    
    # Get last migration temp dir
    if [ -f "$TOOL_DIR/tmp/last_migration" ]; then
        TEMP_DIR=$(cat "$TOOL_DIR/tmp/last_migration")
    else
        echo -e "${RED}No previous migration found. Run export first.${NC}"
        exit 1
    fi
    
    # Run import-apps script
    "$TOOL_DIR/lib/import-apps.sh" -c "$TEMP_DIR/config.sh"
    
    echo -e "${GREEN}Apps import completed successfully!${NC}"
}

# Cleanup command
run_cleanup() {
    echo -e "${GREEN}Running cleanup command...${NC}"
    
    # Get last migration temp dir
    if [ -f "$TOOL_DIR/tmp/last_migration" ]; then
        TEMP_DIR=$(cat "$TOOL_DIR/tmp/last_migration")
    else
        echo -e "${RED}No previous migration found. Nothing to clean up.${NC}"
        exit 1
    fi
    
    # Run cleanup script
    "$TOOL_DIR/lib/cleanup.sh" -c "$TEMP_DIR/config.sh"
    
    # Remove last migration file
    rm "$TOOL_DIR/tmp/last_migration"
    
    echo -e "${GREEN}Cleanup completed successfully!${NC}"
}

# Run all commands
run_all() {
    echo -e "${GREEN}Running complete migration process...${NC}"
    
    run_export && run_import_db && run_import_apps && run_cleanup
    
    echo -e "${GREEN}Complete migration finished successfully!${NC}"
}

# Create temporary config file with current settings
create_temp_config() {
    local temp_dir="$1"
    
    cat > "$temp_dir/config.sh" << EOL
#!/bin/bash

# Source server configuration
SOURCE_SERVER_NAME="$SOURCE_SERVER_NAME"
SOURCE_SERVER_IP="$SOURCE_SERVER_IP"
SOURCE_SERVER_PORT="$SOURCE_SERVER_PORT"
SOURCE_SERVER_KEY="$SOURCE_SERVER_KEY"

# Destination server configuration
DEST_SERVER_NAME="$DEST_SERVER_NAME"
DEST_SERVER_IP="$DEST_SERVER_IP"
DEST_SERVER_PORT="$DEST_SERVER_PORT"
DEST_SERVER_KEY="$DEST_SERVER_KEY"

# Define SSH commands
SOURCE_SSH="$SOURCE_SSH"
DEST_SSH="$DEST_SSH"

# Define SCP commands
SOURCE_SCP="$SOURCE_SCP"
DEST_SCP="$DEST_SCP"

# Define apps and databases
APPS=(${APPS[@]@Q})
DBS=(${DBS[@]@Q})

# Define MongoDB and Redis databases if they exist
MONGO_DBS=(${MONGO_DBS[@]@Q})
REDIS_DBS=(${REDIS_DBS[@]@Q})

# Let's Encrypt configuration
LETSENCRYPT_EMAIL="$LETSENCRYPT_EMAIL"

# Temporary directory
TEMP_DIR="$temp_dir"

# Color codes
GREEN='$GREEN'
YELLOW='$YELLOW'
RED='$RED'
NC='$NC'

# Verbose mode
VERBOSE="$VERBOSE"

# Define app-database mapping
$(
    for app in "${!APP_DB_MAP[@]}"; do
        echo "APP_DB_MAP[\"$app\"]=\"${APP_DB_MAP[$app]}\""
    done
)

# Define Prisma apps
PRISMA_APPS=(${PRISMA_APPS[@]@Q})

# Define volume data apps
VOLUME_DATA_APPS=(${VOLUME_DATA_APPS[@]@Q})
EOL
    
    chmod +x "$temp_dir/config.sh"
}

# Parse command line arguments
CONFIG_FILE="$DEFAULT_CONFIG_FILE"
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -s|--source)
            CLI_SOURCE_IP="$2"
            shift 2
            ;;
        -d|--dest)
            CLI_DEST_IP="$2"
            shift 2
            ;;
        --source-port)
            CLI_SOURCE_PORT="$2"
            shift 2
            ;;
        --dest-port)
            CLI_DEST_PORT="$2"
            shift 2
            ;;
        --source-key)
            CLI_SOURCE_KEY="$2"
            shift 2
            ;;
        --dest-key)
            CLI_DEST_KEY="$2"
            shift 2
            ;;
        --apps)
            CLI_APPS="$2"
            shift 2
            ;;
        --dbs)
            CLI_DBS="$2"
            shift 2
            ;;
        --email)
            CLI_EMAIL="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            print_banner
            print_help
            exit 0
            ;;
        export)
            COMMAND="export"
            shift
            ;;
        import-db)
            COMMAND="import-db"
            shift
            ;;
        import-apps)
            COMMAND="import-apps"
            shift
            ;;
        cleanup)
            COMMAND="cleanup"
            shift
            ;;
        run-all)
            COMMAND="run-all"
            shift
            ;;
        version)
            echo "Dokku Migration Tool v$VERSION"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            print_help
            exit 1
            ;;
    esac
done

# Create tmp directory if not exists
mkdir -p "$TOOL_DIR/tmp"

# Print banner
print_banner

# Load configuration
load_config "$CONFIG_FILE"

# Check if command is specified
if [ -z "$COMMAND" ]; then
    echo -e "${RED}No command specified${NC}"
    print_help
    exit 1
fi

# Run selected command
case $COMMAND in
    export)
        run_export
        ;;
    import-db)
        run_import_db
        ;;
    import-apps)
        run_import_apps
        ;;
    cleanup)
        run_cleanup
        ;;
    run-all)
        run_all
        ;;
    *)
        echo -e "${RED}Unknown command: $COMMAND${NC}"
        print_help
        exit 1
        ;;
esac