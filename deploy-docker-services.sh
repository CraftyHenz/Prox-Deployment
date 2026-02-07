#!/usr/bin/env bash

#---------------------------------------------------------------------#
#     Automated Docker Services Deployment for Proxmox               #
#---------------------------------------------------------------------#
# This script runs on the Proxmox HOST and automatically:
# 1. Creates an LXC container
# 2. Installs Docker
# 3. Deploys all services via docker-compose
# 4. Shows access URLs
#---------------------------------------------------------------------#

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

msg_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
msg_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
msg_error() { echo -e "${RED}[ERROR]${NC} $1"; }
msg_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
    msg_error "This script must be run as root on the Proxmox host"
    exit 1
fi

echo "======================================"
echo "  Docker Services Auto-Deployment"
echo "======================================"
echo ""

# Configuration
read -p "Enter Container ID (default: 200): " CTID
CTID=${CTID:-200}

read -p "Enter Hostname (default: docker-services): " HOSTNAME
HOSTNAME=${HOSTNAME:-docker-services}

read -p "Enter IP address with CIDR (e.g., 10.1.10.20/24): " IP_ADDRESS
while [[ -z "$IP_ADDRESS" ]]; do
    msg_error "IP address is required!"
    read -p "Enter IP address with CIDR (e.g., 10.1.10.20/24): " IP_ADDRESS
done

read -p "Enter Gateway (default: 10.1.10.254): " GATEWAY
GATEWAY=${GATEWAY:-10.1.10.254}

read -p "Enter DNS server (default: 10.1.10.254): " DNS
DNS=${DNS:-10.1.10.254}

read -p "Enter Storage (default: VM_Data): " STORAGE
STORAGE=${STORAGE:-VM_Data}

read -p "Enter Bridge (default: vmbr0): " BRIDGE
BRIDGE=${BRIDGE:-vmbr0}

msg_info ""
msg_info "Configuration Summary:"
msg_info "  Container ID: $CTID"
msg_info "  Hostname: $HOSTNAME"
msg_info "  IP: $IP_ADDRESS"
msg_info "  Gateway: $GATEWAY"
msg_info "  DNS: $DNS"
msg_info "  Storage: $STORAGE"
msg_info "  Bridge: $BRIDGE"
msg_info ""
read -p "Continue? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    msg_info "Aborted by user"
    exit 0
fi

# Check for template
msg_info "Checking for Debian 12 template..."
pveam update
TEMPLATE_NAME=$(pveam available | grep -i "debian-12-standard" | sort -V | tail -n1 | awk '{print $2}')

if [ -z "$TEMPLATE_NAME" ]; then
    msg_error "No Debian 12 template found"
    exit 1
fi

TEMPLATE_PATH="/var/lib/vz/template/cache/$TEMPLATE_NAME"
if [ ! -f "$TEMPLATE_PATH" ]; then
    msg_info "Downloading template: $TEMPLATE_NAME"
    pveam download local "$TEMPLATE_NAME"
fi
msg_ok "Template ready: $TEMPLATE_NAME"

# Create container
msg_info "Creating LXC container..."
pct create $CTID local:vztmpl/$TEMPLATE_NAME \
    --hostname $HOSTNAME \
    --cores 4 \
    --memory 4096 \
    --swap 512 \
    --net0 name=eth0,bridge=$BRIDGE,ip=$IP_ADDRESS,gw=$GATEWAY \
    --storage $STORAGE \
    --rootfs $STORAGE:32 \
    --unprivileged 1 \
    --features nesting=1 \
    --nameserver $DNS \
    --onboot 1 \
    --start 0

# Add AppArmor unconfined for Docker support
echo "lxc.apparmor.profile: unconfined" >> /etc/pve/lxc/${CTID}.conf

msg_ok "Container $CTID created"

# Start container
msg_info "Starting container..."
pct start $CTID
sleep 5
msg_ok "Container started"

# Install Docker
msg_info "Installing Docker..."
pct exec $CTID -- bash -c "apt-get update && apt-get upgrade -y"
pct exec $CTID -- bash -c "apt-get install -y curl ca-certificates"
pct exec $CTID -- bash -c "install -m 0755 -d /etc/apt/keyrings"
pct exec $CTID -- bash -c "curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc"
pct exec $CTID -- bash -c "chmod a+r /etc/apt/keyrings/docker.asc"
pct exec $CTID -- bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'
pct exec $CTID -- bash -c "apt-get update"
pct exec $CTID -- bash -c "apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin"

msg_ok "Docker installed"

# Create directory structure
msg_info "Setting up docker-compose..."
pct exec $CTID -- bash -c "mkdir -p /opt/docker-services"
pct exec $CTID -- bash -c "cd /opt/docker-services && mkdir -p homarr/appdata portainer/data trilium/data pihole/etc-pihole pihole/etc-dnsmasq.d unifi/config unifi/db"

# Download docker-compose file
msg_info "Downloading docker-compose.yml..."
pct exec $CTID -- bash -c "curl -sL https://github.com/CraftyHenz/Prox-Deployment/raw/main/docker-compose-master.yml -o /opt/docker-services/docker-compose.yml"

# Generate passwords
HOMARR_KEY=$(openssl rand -hex 32)
PIHOLE_PASS=$(openssl rand -base64 12)
UNIFI_PASS=$(openssl rand -base64 12)
HOST_IP_ONLY=${IP_ADDRESS%/*}

# Create .env file
msg_info "Creating environment file..."
pct exec $CTID -- bash -c "cat > /opt/docker-services/.env << EOF
HOMARR_ENCRYPTION_KEY=$HOMARR_KEY
PIHOLE_PASSWORD=$PIHOLE_PASS
UNIFI_DB_PASSWORD=$UNIFI_PASS
HOST_IP=$HOST_IP_ONLY
HOSTNAME=$HOSTNAME
TWINGATE_ACCESS_TOKEN=
TWINGATE_REFRESH_TOKEN=
EOF"

# Start services
msg_info "Starting Docker services..."
pct exec $CTID -- bash -c "cd /opt/docker-services && docker compose up -d"

msg_ok ""
msg_ok "======================================"
msg_ok "  Deployment Complete!"
msg_ok "======================================"
msg_info ""
msg_info "Access your services:"
msg_info "  Homarr Dashboard:  http://$HOST_IP_ONLY:7575"
msg_info "  Portainer:         https://$HOST_IP_ONLY:9443 (or http://$HOST_IP_ONLY:9000)"
msg_info "  Trilium Notes:     http://$HOST_IP_ONLY:8081"
msg_info "  Pi-hole Admin:     http://$HOST_IP_ONLY:8082/admin"
msg_info "  UniFi Controller:  https://$HOST_IP_ONLY:8443"
msg_info ""
msg_warn "IMPORTANT - Save these credentials:"
msg_info "  Pi-hole Password: $PIHOLE_PASS"
msg_info "  UniFi DB Password: $UNIFI_PASS"
msg_info ""
msg_info "To enable Twingate:"
msg_info "  1. Get tokens from: https://billwindle21.twingate.com/connectors"
msg_info "  2. Edit: pct exec $CTID -- nano /opt/docker-services/.env"
msg_info "  3. Add your TWINGATE_ACCESS_TOKEN and TWINGATE_REFRESH_TOKEN"
msg_info "  4. Edit: pct exec $CTID -- nano /opt/docker-services/docker-compose.yml"
msg_info "  5. Uncomment the twingate service section"
msg_info "  6. Run: pct exec $CTID -- bash -c 'cd /opt/docker-services && docker compose up -d'"
msg_info ""
msg_info "Useful commands:"
msg_info "  Enter container:   pct enter $CTID"
msg_info "  View logs:         pct exec $CTID -- docker compose -f /opt/docker-services/docker-compose.yml logs -f"
msg_info "  Restart services:  pct exec $CTID -- docker compose -f /opt/docker-services/docker-compose.yml restart"
msg_info "  Update services:   pct exec $CTID -- bash -c 'cd /opt/docker-services && docker compose pull && docker compose up -d'"
msg_info ""
msg_ok "Done! 🎉"
