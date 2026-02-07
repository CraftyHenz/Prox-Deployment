#!/usr/bin/env bash

# Proxmox LXC Auto-Deployment Script
# Deploys containers based on config file

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
    msg_error "This script must be run as root"
    exit 1
fi

# Check if config file exists
CONFIG_FILE="${1:-/root/deployment-config.conf}"

if [ ! -f "$CONFIG_FILE" ]; then
    msg_error "Config file not found: $CONFIG_FILE"
    msg_info "Creating example config file..."

    cat > "$CONFIG_FILE" << 'EOF'
# Proxmox LXC Deployment Configuration
# Edit this file with your settings, then run: bash auto-deploy.sh

# Global Settings
STORAGE="VM_Data"
BRIDGE="vmbr0"
GATEWAY="10.1.10.254"

# Service Deployments (set ENABLED=true to deploy)
# Format: SERVICE_ENABLED, SERVICE_CTID, SERVICE_HOSTNAME, SERVICE_IP
# NOTE: Listening port = last octet of the IP address

# Trilium Notes (.11 = port 11)
TRILIUM_ENABLED=true
TRILIUM_CTID=101
TRILIUM_HOSTNAME="Trilium-Notes"
TRILIUM_IP="10.1.10.11/24"

# Homarr Dashboard (.12 = port 12)
HOMARR_ENABLED=true
HOMARR_CTID=102
HOMARR_HOSTNAME="Homarr"
HOMARR_IP="10.1.10.12/24"

# Observium (.13 = port 13)
OBSERVIUM_ENABLED=false
OBSERVIUM_CTID=103
OBSERVIUM_HOSTNAME="observium"
OBSERVIUM_IP="10.1.10.13/24"

# UniFi Controller (.14 = port 14)
UNIFI_ENABLED=false
UNIFI_CTID=104
UNIFI_HOSTNAME="unifi"
UNIFI_IP="10.1.10.14/24"

# Pi-hole (.53 = port 53 / DNS)
PIHOLE_ENABLED=false
PIHOLE_CTID=110
PIHOLE_HOSTNAME="pihole"
PIHOLE_IP="10.1.10.53/24"
EOF

    msg_ok "Example config created at: $CONFIG_FILE"
    msg_info "Edit this file with your settings, then run the script again"
    exit 0
fi

# Load config
msg_info "Loading configuration from: $CONFIG_FILE"
source "$CONFIG_FILE"

# Extract last octet from IP (used as the listening port)
get_port_from_ip() {
    local IP_WITH_CIDR=$1
    local IP_ONLY="${IP_WITH_CIDR%/*}"
    echo "${IP_ONLY##*.}"
}

msg_info "Configuration loaded:"
msg_info "  Storage: $STORAGE"
msg_info "  Bridge: $BRIDGE"
msg_info "  Gateway: $GATEWAY"

# Download deployment script
DEPLOY_SCRIPT="/tmp/proxmox-lxc-deploy-lib.sh"
msg_info "Downloading deployment library..."
wget -q https://github.com/CraftyHenz/Prox-Deployment/raw/main/proxmox-lxc-deploy.sh -O "$DEPLOY_SCRIPT"
chmod +x "$DEPLOY_SCRIPT"

# Source the functions from the deployment script
source "$DEPLOY_SCRIPT"

# Check for Debian template
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

# Deploy services
deploy_service() {
    local SERVICE_NAME=$1
    local ENABLED_VAR="${2}_ENABLED"
    local CTID_VAR="${2}_CTID"
    local HOSTNAME_VAR="${2}_HOSTNAME"
    local IP_VAR="${2}_IP"
    local DEPLOY_FUNC=$3

    if [ "${!ENABLED_VAR}" = "true" ]; then
        msg_info "=== Deploying $SERVICE_NAME ==="

        local CTID=${!CTID_VAR}
        local HOSTNAME=${!HOSTNAME_VAR}
        local IP=${!IP_VAR}
        local PORT=$(get_port_from_ip "$IP")

        # Check if container already exists
        if pct status $CTID &>/dev/null; then
            msg_warn "Container $CTID already exists. Skipping $SERVICE_NAME"
            return
        fi

        msg_info "  CTID: $CTID"
        msg_info "  Hostname: $HOSTNAME"
        msg_info "  IP: $IP"
        msg_info "  Port: $PORT"

        # Set network config for this container
        export NET_CONFIG="name=eth0,bridge=$BRIDGE,ip=$IP,gw=$GATEWAY"

        # Create container
        create_base_container $CTID "$HOSTNAME" ${4:-2} ${5:-2048} ${6:-16}
        start_and_wait $CTID

        # Run deployment function with port
        $DEPLOY_FUNC $PORT

        local IP_ONLY="${IP%/*}"
        msg_ok "$SERVICE_NAME deployed successfully!"
        msg_info "Access at: ${7}${IP_ONLY}:${PORT}"
    else
        msg_info "Skipping $SERVICE_NAME (not enabled in config)"
    fi
}

# Function wrappers that use the CTID from config
deploy_pihole_auto() {
    local PORT=${1:-53}
    local CTID=$PIHOLE_CTID
    msg_info "Installing Pi-hole on port $PORT..."
    exec_in_ct $CTID "apt-get update && apt-get upgrade -y"
    exec_in_ct $CTID "apt-get install -y curl"
    exec_in_ct $CTID "curl -sSL https://install.pi-hole.net | bash /dev/stdin --unattended"
    # Pi-hole DNS listens on port 53 by default which matches .53 last octet
    # Web admin is on port 80 within the container
}

deploy_trilium_auto() {
    local PORT=${1:-11}
    local CTID=$TRILIUM_CTID
    msg_info "Installing Trilium on port $PORT..."
    exec_in_ct $CTID "apt-get update && apt-get upgrade -y"
    exec_in_ct $CTID "apt-get install -y wget curl jq"
    exec_in_ct $CTID 'curl -sL https://api.github.com/repos/TriliumNext/Notes/releases/latest | jq -r ".assets[] | select(.name | test(\"TriliumNextNotes-.*-linux-x64.tar.xz\")) | .browser_download_url" > /tmp/trilium_url.txt'
    exec_in_ct $CTID "wget -i /tmp/trilium_url.txt -O /tmp/trilium.tar.xz"
    exec_in_ct $CTID "tar -xvf /tmp/trilium.tar.xz -C /tmp/"
    exec_in_ct $CTID 'mv /tmp/TriliumNextNotes-*-linux-x64 /opt/trilium'
    # Configure Trilium to listen on custom port
    exec_in_ct $CTID "cat > /etc/systemd/system/trilium.service << EOFS
[Unit]
Description=Trilium Notes
After=network.target

[Service]
Type=simple
Environment=TRILIUM_PORT=$PORT
ExecStart=/opt/trilium/trilium.sh
WorkingDirectory=/opt/trilium
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOFS"
    exec_in_ct $CTID "systemctl daemon-reload"
    exec_in_ct $CTID "systemctl enable --now trilium"
}

deploy_homarr_auto() {
    local PORT=${1:-12}
    local CTID=$HOMARR_CTID
    msg_info "Installing Docker and Homarr on port $PORT..."
    exec_in_ct $CTID "apt-get update && apt-get upgrade -y"
    exec_in_ct $CTID "apt-get install -y curl ca-certificates"
    exec_in_ct $CTID "install -m 0755 -d /etc/apt/keyrings"
    exec_in_ct $CTID "curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc"
    exec_in_ct $CTID "chmod a+r /etc/apt/keyrings/docker.asc"
    exec_in_ct $CTID 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "\$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'
    exec_in_ct $CTID "apt-get update"
    exec_in_ct $CTID "apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin"
    exec_in_ct $CTID "mkdir -p /opt/homarr/configs /opt/homarr/icons /opt/homarr/data"
    # Map custom port to Homarr's internal port 7575
    exec_in_ct $CTID "docker run -d --name homarr --restart=unless-stopped -p $PORT:7575 -v /opt/homarr/configs:/app/data/configs -v /opt/homarr/icons:/app/public/icons -v /opt/homarr/data:/data ghcr.io/ajnart/homarr:latest"
}

deploy_observium_auto() {
    local PORT=${1:-13}
    local CTID=$OBSERVIUM_CTID
    msg_info "Installing Observium on port $PORT..."
    msg_warn "Observium installation is complex and takes 10-15 minutes"
    # Configure Apache to listen on custom port
    # Add full observium deployment here
}

deploy_unifi_auto() {
    local PORT=${1:-14}
    local CTID=$UNIFI_CTID
    msg_info "Installing UniFi Controller on port $PORT..."
    # Configure UniFi to listen on custom port
    # Add full unifi deployment here
}

# Deploy services based on config
msg_info ""
msg_info "Starting automated deployment..."
msg_info ""

deploy_service "Trilium Notes" "TRILIUM" "deploy_trilium_auto" 2 2048 16 "http://"
deploy_service "Homarr" "HOMARR" "deploy_homarr_auto" 2 2048 12 "http://"
deploy_service "Observium" "OBSERVIUM" "deploy_observium_auto" 2 4096 20 "http://"
deploy_service "UniFi Controller" "UNIFI" "deploy_unifi_auto" 2 2048 16 "https://"
deploy_service "Pi-hole" "PIHOLE" "deploy_pihole_auto" 2 1024 8 "http://"

msg_ok ""
msg_ok "=== Deployment Complete ==="
msg_info ""
msg_info "Deployed Services:"

[ "$TRILIUM_ENABLED" = "true" ] && echo "  Trilium (CT $TRILIUM_CTID): http://${TRILIUM_IP%/*}:$(get_port_from_ip $TRILIUM_IP)"
[ "$HOMARR_ENABLED" = "true" ] && echo "  Homarr (CT $HOMARR_CTID): http://${HOMARR_IP%/*}:$(get_port_from_ip $HOMARR_IP)"
[ "$OBSERVIUM_ENABLED" = "true" ] && echo "  Observium (CT $OBSERVIUM_CTID): http://${OBSERVIUM_IP%/*}:$(get_port_from_ip $OBSERVIUM_IP)"
[ "$UNIFI_ENABLED" = "true" ] && echo "  UniFi (CT $UNIFI_CTID): https://${UNIFI_IP%/*}:$(get_port_from_ip $UNIFI_IP)"
[ "$PIHOLE_ENABLED" = "true" ] && echo "  Pi-hole (CT $PIHOLE_CTID): http://${PIHOLE_IP%/*}/admin (DNS on port $(get_port_from_ip $PIHOLE_IP))"

msg_info ""
msg_ok "All done!"