#!/usr/bin/env bash

# Project: Modern Proxmox Portainer LXC Setup
# Author: harshsinghmp
# Date: 2025-06-17 21:07:44
# License: GPL 3.0

# Enable strict error handling
set -euo pipefail
IFS=$'\n\t'

# Default values
HOSTNAME=${HOSTNAME:-"portainer"}
DISK_SIZE=${DISK_SIZE:-"8G"}
MEMORY=${MEMORY:-"1024"}
CORES=${CORES:-"2"}
DOMAIN=${DOMAIN:-""}
CT_PASSWORD=${CT_PASSWORD:-""}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

# Spinner for long-running processes
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf "\r${YELLOW} %c ${NC} %s" "$spinstr" "$2"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
    done
    printf "\r${GREEN}✓${NC} %s\n" "$2"
}

# Wait for container to be running and ready
wait_for_container() {
    local ctid=$1
    local max_attempts=30
    local attempt=1

    log "Waiting for container to start..."
    while [ $attempt -le $max_attempts ]; do
        if pct status $ctid | grep -q "status: running"; then
            # Additional check for network
            if pct exec $ctid -- ping -c 1 8.8.8.8 >/dev/null 2>&1; then
                log "Container is running and has network connectivity"
                return 0
            fi
        fi
        printf "."
        sleep 2
        attempt=$((attempt + 1))
    done
    error "Container failed to start properly within 60 seconds"
}

# Cleanup function
cleanup() {
    if [ -n "${CTID:-}" ]; then
        if pct status $CTID &>/dev/null; then
            if [ "$(pct status $CTID | awk '{print $2}')" == "running" ]; then
                pct stop $CTID
            fi
            pct destroy $CTID
        fi
    fi
}

# Trap errors
trap cleanup ERR

# Check if running on Proxmox
if [ ! -f /etc/pve/local/pve-ssl.key ]; then
    error "This script must be run on a Proxmox VE server!"
fi

# Get next available CTID
CTID=$(pvesh get /cluster/nextid)
log "Using container ID: $CTID"

# Select storage location
select_storage() {
    local storage_list=$(pvesm status -content rootdir | awk 'NR>1 {print $1}')
    if [ -z "$storage_list" ]; then
        error "No valid storage locations found!"
    fi
    
    # Use first available storage if only one exists
    if [ $(echo "$storage_list" | wc -l) -eq 1 ]; then
        echo "$storage_list"
        return
    fi
    
    echo "Available storage locations:"
    select storage in $storage_list; do
        if [ -n "$storage" ]; then
            echo "$storage"
            return
        fi
    done
}

STORAGE=$(select_storage)
log "Using storage: $STORAGE"

# Download Alpine template
log "Updating template list..."
pveam update >/dev/null 2>&1 & spinner $! "Updating template list"

log "Downloading Alpine template..."
TEMPLATE=$(pveam available | grep alpine | sort -V | tail -1 | awk '{print $2}')
pveam download $STORAGE $TEMPLATE >/dev/null 2>&1 & spinner $! "Downloading Alpine template"

# Create LXC container
log "Creating LXC container..."
pct create $CTID $STORAGE:vztmpl/$TEMPLATE \
    --hostname $HOSTNAME \
    --cores $CORES \
    --memory $MEMORY \
    --swap 0 \
    --rootfs $STORAGE:$DISK_SIZE \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 >/dev/null 2>&1

# Start the container
log "Starting container..."
pct start $CTID

# Wait for container to be ready
wait_for_container $CTID

# Prepare the setup script
log "Preparing container setup script..."
cat > /tmp/container_setup.sh <<'EOF'
#!/bin/sh

# Update repositories and install required packages
apk update
apk add --no-cache \
    docker \
    docker-cli-compose \
    curl \
    bash \
    shadow \
    tzdata \
    nginx

# Enable and start Docker
rc-update add docker default
service docker start

# Wait for Docker to be ready
timeout=30
while ! docker info >/dev/null 2>&1; do
    timeout=$((timeout - 1))
    if [ $timeout -le 0 ]; then
        echo "Docker failed to start"
        exit 1
    fi
    sleep 1
done

# Create Docker networks
docker network create portainer_agent_network || true

# Install Portainer
docker volume create portainer_data
docker run -d \
    --name portainer \
    --restart always \
    --network portainer_agent_network \
    -p 9443:9443 \
    -p 8000:8000 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest

# Setup timezone
cp /usr/share/zoneinfo/UTC /etc/localtime

echo "Setup completed successfully"
EOF

# Copy and execute setup script
log "Copying setup script to container..."
pct push $CTID /tmp/container_setup.sh /setup.sh
pct exec $CTID -- chmod +x /setup.sh

log "Executing setup script in container..."
pct exec $CTID -- /setup.sh

# Get container IP
IP=$(pct exec $CTID -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

# Final output
cat <<EOF

${GREEN}=== Setup Complete! ===${NC}

${BLUE}Container Information:${NC}
  ID: $CTID
  Hostname: $HOSTNAME
  IP Address: $IP

${BLUE}Portainer Access:${NC}
  Web Interface: https://$IP:9443
  API Endpoint: http://$IP:8000

${YELLOW}Initial Setup:${NC}
1. Access Portainer at https://$IP:9443
2. Create your admin account
3. Choose your environment type

${BLUE}Docker Commands (inside container):${NC}
  pct enter $CTID
  docker ps
  docker-compose up -d

${YELLOW}Note:${NC} First login will require creating an admin user.
For security, please change the default credentials immediately.
EOF

# Cleanup
rm -f /tmp/container_setup.sh
