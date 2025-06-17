#!/bin/bash

# Script: proxmox-lxc-docker-setup.sh
# Description: Automated Proxmox LXC container setup with Alpine, Docker, and Portainer
# Created by: harshsinghmp
# Date: 2025-06-17

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Fancy loader function
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local msg="$2"
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf "${YELLOW} %s %c ${NC} %s" "[PROCESSING]" "$spinstr" "$msg"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\r"
    done
    printf "${GREEN} %s ${NC} %s\n" "[DONE]" "$msg"
}

# Error handling
error_exit() {
    printf "${RED}[ERROR] ${1}${NC}\n" 1>&2
    exit 1
}

# Input validation
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        return 0
    else
        return 1
    fi
}

validate_domain() {
    local domain=$1
    if [[ $domain =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# User input with validation
echo "=== Proxmox LXC Container Setup ==="
echo "Please provide the following information:"
echo

# Container ID
while true; do
    read -p "Container ID (100-999): " CTID
    [[ $CTID =~ ^[1-9][0-9]{2}$ ]] && break
    echo "${RED}Invalid container ID. Please use a number between 100 and 999.${NC}"
done

# Hostname
while true; do
    read -p "Container hostname: " HOSTNAME
    [[ $HOSTNAME =~ ^[a-zA-Z0-9-]+$ ]] && break
    echo "${RED}Invalid hostname. Use only letters, numbers, and hyphens.${NC}"
done

# Domain
while true; do
    read -p "Domain name (e.g., myapp.example.com): " DOMAIN
    validate_domain "$DOMAIN" && break
    echo "${RED}Invalid domain format.${NC}"
done

# Network Configuration
while true; do
    read -p "Container static IP (e.g., 192.168.1.100/24): " CT_IP
    validate_ip "$CT_IP" && break
    echo "${RED}Invalid IP format. Use CIDR notation (e.g., 192.168.1.100/24)${NC}"
done

read -p "Gateway IP: " GATEWAY
read -p "DNS servers (comma-separated): " DNS

# Resources
read -p "Storage pool (e.g., local-lvm): " STORAGE
read -p "CPU cores: " CPU
read -p "RAM in MB (e.g., 2048): " RAM
read -p "Disk size in GB: " DISK

echo
echo "=== Configuration Summary ==="
echo "Container ID: $CTID"
echo "Hostname: $HOSTNAME"
echo "Domain: $DOMAIN"
echo "IP Address: $CT_IP"
echo "Gateway: $GATEWAY"
echo "DNS: $DNS"
echo "Storage: $STORAGE"
echo "CPU Cores: $CPU"
echo "RAM: ${RAM}MB"
echo "Disk: ${DISK}GB"
echo

read -p "Continue with installation? [y/N] " confirm
[[ $confirm =~ ^[Yy]$ ]] || exit 1

# Download Alpine template
echo "Downloading latest Alpine template..."
pveam update >/dev/null 2>&1
ALPINE_TEMPLATE=$(pveam available | grep alpine | sort -V | tail -1 | awk '{print $2}')
(pveam download $STORAGE $ALPINE_TEMPLATE) & spinner $! "Downloading Alpine template"

# Create container
echo "Creating LXC container..."
pct create $CTID $STORAGE:vztmpl/$ALPINE_TEMPLATE \
    -hostname $HOSTNAME \
    -cores $CPU \
    -memory $RAM \
    -rootfs $STORAGE:${DISK}G \
    -net0 name=eth0,bridge=vmbr0,ip=$CT_IP,gw=$GATEWAY \
    -nameserver $DNS \
    -features nesting=1 \
    -unprivileged 1 \
    -onboot 1

# Start container
echo "Starting container..."
pct start $CTID & spinner $! "Starting LXC container"

# Wait for container to be ready
sleep 5

# Setup Alpine and install Docker
echo "Installing Docker and dependencies..."
pct exec $CTID -- /bin/sh -c "
    # Update package lists
    apk update
    
    # Install required packages
    apk add --no-cache \
        docker \
        docker-cli-compose \
        curl \
        bash \
        shadow \
        tzdata
    
    # Configure Docker
    rc-update add docker default
    service docker start
    
    # Create docker network for Portainer
    docker network create portainer_agent_network || true
    
    # Run Portainer agent
    docker run -d \
        --name portainer_agent \
        --restart always \
        --network portainer_agent_network \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v /var/lib/docker/volumes:/var/lib/docker/volumes \
        -e AGENT_CLUSTER_ADDR=tasks.portainer_agent \
        -p 9001:9001 \
        portainer/agent:latest
    
    # Set timezone to UTC
    cp /usr/share/zoneinfo/UTC /etc/localtime
    
    # Create environment file
    echo \"DOMAIN=${DOMAIN}\" > /root/.env
" & spinner $! "Setting up Docker and Portainer agent"

# Get Container IP
CONTAINER_IP=${CT_IP%%/*}

# Final output
echo
echo "=== Setup Complete! ==="
echo "----------------------------------------"
echo "Container Details:"
echo "  Name: $HOSTNAME"
echo "  IP: $CONTAINER_IP"
echo "  Domain: $DOMAIN"
echo
echo "Portainer Agent:"
echo "  URL: http://$CONTAINER_IP:9001"
echo "  Add this endpoint to your Portainer server"
echo
echo "Docker Commands (execute inside container):"
echo "  pct enter $CTID"
echo "  docker ps"
echo "  docker-compose up -d"
echo
echo "To use domain with your applications:"
echo "1. Configure DNS records for $DOMAIN"
echo "2. Use the domain in your docker-compose files"
echo "3. Consider setting up a reverse proxy (e.g., Traefik, Nginx Proxy Manager)"
echo "----------------------------------------"
