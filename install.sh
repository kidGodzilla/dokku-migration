#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print header
echo -e "${BLUE}╔════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                                                ║${NC}"
echo -e "${BLUE}║          Dokku Migration Tool Installer        ║${NC}"
echo -e "${BLUE}║                                                ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════╝${NC}"

# Parse command line arguments
FORCE_UPDATE=false
SKIP_PATH_UPDATE=false
INSTALL_DIR="${HOME}/.dokku-migration"
BRANCH="main"

while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE_UPDATE=true
            shift
            ;;
        --skip-path)
            SKIP_PATH_UPDATE=true
            shift
            ;;
        --dir)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        --help)
            echo "Usage: install.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --force        Force update even if already installed"
            echo "  --skip-path    Skip updating PATH in shell config files"
            echo "  --dir DIR      Specify installation directory (default: ~/.dokku-migration)"
            echo "  --branch NAME  Specify git branch to use (default: main)"
            echo "  --help         Show this help message"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Create installation directory
echo -e "\n${YELLOW}Creating installation directory...${NC}"
mkdir -p "${INSTALL_DIR}"

# Check if Git is installed
if ! command -v git &> /dev/null; then
    echo -e "${RED}Git is not installed. Please install Git and try again.${NC}"
    exit 1
fi

# Clone or update the repository
if [ -d "${INSTALL_DIR}/.git" ] && [ "$FORCE_UPDATE" = false ]; then
    echo -e "${YELLOW}Updating existing installation...${NC}"
    cd "${INSTALL_DIR}" && git fetch && git reset --hard origin/"${BRANCH}" && git clean -fd
else
    if [ -d "${INSTALL_DIR}/.git" ]; then
        echo -e "${YELLOW}Forcing clean installation...${NC}"
        rm -rf "${INSTALL_DIR}"
        mkdir -p "${INSTALL_DIR}"
    fi
    echo -e "${YELLOW}Cloning repository...${NC}"
    git clone -b "${BRANCH}" https://github.com/kidGodzilla/dokku-migration.git "${INSTALL_DIR}"
fi

# Make scripts executable
echo -e "${YELLOW}Making scripts executable...${NC}"
chmod +x "${INSTALL_DIR}"/*.sh
chmod +x "${INSTALL_DIR}"/lib/*.sh

# Create symlink to /usr/local/bin if not exists
echo -e "${YELLOW}Creating symlink in /usr/local/bin...${NC}"
if [ -f "/usr/local/bin/dokku-migration" ] && [ "$FORCE_UPDATE" = true ]; then
    if [ -w "/usr/local/bin" ]; then
        rm -f "/usr/local/bin/dokku-migration"
    else
        sudo rm -f "/usr/local/bin/dokku-migration"
    fi
fi

if [ ! -f "/usr/local/bin/dokku-migration" ]; then
    if [ -w "/usr/local/bin" ]; then
        ln -s "${INSTALL_DIR}/dokku-migration.sh" /usr/local/bin/dokku-migration
    else
        echo -e "${YELLOW}Creating symlink requires sudo permissions${NC}"
        sudo ln -s "${INSTALL_DIR}/dokku-migration.sh" /usr/local/bin/dokku-migration
    fi
else
    echo -e "${YELLOW}Symlink already exists${NC}"
fi

# Create default config file if it doesn't exist
DEFAULT_CONFIG_FILE="${HOME}/.dokku-migration-config"
if [ ! -f "${DEFAULT_CONFIG_FILE}" ] || [ "$FORCE_UPDATE" = true ]; then
    echo -e "${YELLOW}Creating default configuration file at ${DEFAULT_CONFIG_FILE}...${NC}"
    cat > "${DEFAULT_CONFIG_FILE}" << 'EOF'
#!/bin/bash

# ===== Server Configuration =====
# Source server configuration
SOURCE_SERVER_NAME="source-server"
SOURCE_SERVER_IP="192.168.1.100"
SOURCE_SERVER_PORT="22"
SOURCE_SERVER_KEY="~/.ssh/id_rsa"

# Destination server configuration
DEST_SERVER_NAME="dest-server"
DEST_SERVER_IP="192.168.1.200"
DEST_SERVER_PORT="22"
DEST_SERVER_KEY="~/.ssh/id_rsa"

# ===== Apps and Databases =====
# Define apps and databases to migrate
APPS=("app1" "app2")
DBS=("app1-db" "app2-db")

# ===== Let's Encrypt Configuration =====
LETSENCRYPT_EMAIL="your-email@example.com"

# ===== Advanced Settings (Optional) =====
# Apps that use Prisma (need special database URL handling)
PRISMA_APPS=("app1")

# Apps that need volume data transfer (not just mount configuration)
VOLUME_DATA_APPS=("app2")
EOF
    chmod +x "${DEFAULT_CONFIG_FILE}"
else
    echo -e "${YELLOW}Using existing configuration file at ${DEFAULT_CONFIG_FILE}${NC}"
fi

# Create tmp directory
mkdir -p "${INSTALL_DIR}/tmp"

# Update PATH in shell config files if needed
if [ "$SKIP_PATH_UPDATE" = false ]; then
    echo -e "${YELLOW}Checking if /usr/local/bin is in your PATH...${NC}"
    
    PATH_UPDATED=false
    PATH_ALREADY_SET=false
    
    # Check if /usr/local/bin is in PATH
    if echo "$PATH" | grep -q "/usr/local/bin"; then
        echo -e "${GREEN}/usr/local/bin is already in your PATH${NC}"
        PATH_ALREADY_SET=true
    else
        # Determine shell config file to update
        SHELL_CONFIG=""
        if [ -n "$ZSH_VERSION" ]; then
            # ZSH
            if [ -f "$HOME/.zshrc" ]; then
                SHELL_CONFIG="$HOME/.zshrc"
                SHELL_NAME="zsh"
            fi
        elif [ -n "$BASH_VERSION" ]; then
            # Bash
            if [ -f "$HOME/.bashrc" ]; then
                SHELL_CONFIG="$HOME/.bashrc"
                SHELL_NAME="bash"
            elif [ -f "$HOME/.bash_profile" ]; then
                SHELL_CONFIG="$HOME/.bash_profile"
                SHELL_NAME="bash"
            fi
        fi
        
        # Check if we found a shell config file
        if [ -n "$SHELL_CONFIG" ]; then
            # Check if the PATH update is already in the config
            if grep -q "export PATH=/usr/local/bin:\$PATH" "$SHELL_CONFIG"; then
                echo -e "${GREEN}PATH update already in $SHELL_CONFIG${NC}"
                PATH_ALREADY_SET=true
            else
                echo -e "${YELLOW}Adding /usr/local/bin to PATH in $SHELL_CONFIG${NC}"
                echo -e "\n# Added by Dokku Migration Tool installer" >> "$SHELL_CONFIG"
                echo "export PATH=/usr/local/bin:\$PATH" >> "$SHELL_CONFIG"
                PATH_UPDATED=true
            fi
        else
            echo -e "${YELLOW}Could not identify shell config file${NC}"
        fi
    fi
fi

echo -e "\n${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           Installation Complete!                ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"

# Print path information if needed
if [ "$PATH_UPDATED" = true ]; then
    echo -e "\n${YELLOW}IMPORTANT:${NC} Your shell configuration has been updated."
    echo -e "Please run the following command or restart your terminal to update your PATH:"
    echo -e "${BLUE}source $SHELL_CONFIG${NC}"
elif [ "$PATH_ALREADY_SET" = false ] && [ "$SKIP_PATH_UPDATE" = false ]; then
    echo -e "\n${YELLOW}IMPORTANT:${NC} Could not automatically update your PATH."
    echo -e "Please add the following line to your shell configuration file:"
    echo -e "${BLUE}export PATH=/usr/local/bin:\$PATH${NC}"
fi

echo -e "\nYou can now use the tool by running: ${YELLOW}dokku-migration${NC}"
echo -e "Default configuration file is at: ${YELLOW}${DEFAULT_CONFIG_FILE}${NC}"
echo -e "To see available commands, run: ${YELLOW}dokku-migration --help${NC}"
echo -e "\n${GREEN}Enjoy using Dokku Migration Tool!${NC}"

# Print version information
TOOL_VERSION=$(cd "${INSTALL_DIR}" && git describe --tags --always 2>/dev/null || echo "unknown")
echo -e "\nInstalled version: ${BLUE}${TOOL_VERSION}${NC}"

# Check for updates information
echo -e "\nTo update the tool in the future, run:"
echo -e "${BLUE}curl -fsSL https://raw.githubusercontent.com/kidGodzilla/dokku-migration/${BRANCH}/install.sh | bash${NC}"
echo -e "or"
echo -e "${BLUE}curl -fsSL https://raw.githubusercontent.com/kidGodzilla/dokku-migration/${BRANCH}/install.sh | bash -s -- --force${NC}"