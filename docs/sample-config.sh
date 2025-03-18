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
