#!/usr/bin/env bash

# Proxmox LXC Container Deployment Script
# Supports: Pi-hole, Trilium, Homarr, Observium, UniFi Controller

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
msg_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

msg_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

msg_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

msg_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Function to check if script is run as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        msg_error "This script must be run as root"
        exit 1
    fi
}

# Function to get next available CT ID
get_next_ctid() {
    local next_id=100
    while pct status $next_id &>/dev/null; do
        ((next_id++))
    done
    echo $next_id
}

# Function to get CTID from user
get_ctid_from_user() {
    local service_name=$1
    local suggested_id=$(get_next_ctid)
    
    echo -e "${BLUE}[INFO]${NC} Next available Container ID: $suggested_id" >&2
    read -p "Enter Container ID for $service_name (press Enter for $suggested_id): " user_ctid
    
    if [ -z "$user_ctid" ]; then
        echo $suggested_id
    else
        # Validate the ID
        if ! [[ "$user_ctid" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}[ERROR]${NC} Invalid Container ID. Must be a number." >&2
            exit 1
        fi
        
        if pct status $user_ctid &>/dev/null; then
            echo -e "${RED}[ERROR]${NC} Container ID $user_ctid already exists!" >&2
            exit 1
        fi
        
        echo $user_ctid
    fi
}

# Function to get hostname from user
get_hostname_from_user() {
    local service_name=$1
    local default_hostname=$2
    
    read -p "Enter hostname for $service_name (press Enter for '$default_hostname'): " user_hostname
    
    if [ -z "$user_hostname" ]; then
        echo $default_hostname
    else
        # Validate hostname (alphanumeric and hyphens only, no spaces)
        if ! [[ "$user_hostname" =~ ^[a-zA-Z0-9-]+$ ]]; then
            echo -e "${RED}[ERROR]${NC} Invalid hostname. Use only letters, numbers, and hyphens." >&2
            exit 1
        fi
        
        echo $user_hostname
    fi
}

# Function to select storage
select_storage() {
    msg_info "Available storage:"
    pvesm status | awk 'NR>1 {print $1}'
    read -p "Enter storage name (default: local-lvm): " STORAGE
    STORAGE=${STORAGE:-local-lvm}
}

# Function to get network configuration
get_network_config() {
    read -p "Enter bridge (default: vmbr0): " BRIDGE
    BRIDGE=${BRIDGE:-vmbr0}
    
    read -p "Use DHCP for all containers? (y/n, default: y): " USE_DHCP
    USE_DHCP=${USE_DHCP:-y}
    
    if [[ $USE_DHCP =~ ^[Nn]$ ]]; then
        USE_STATIC_IP="true"
        read -p "Enter gateway (e.g., 10.1.10.254): " GATEWAY
    else
        USE_STATIC_IP="false"
    fi
}

# Function to get network config for specific container
get_container_network() {
    local HOSTNAME=$1
    
    if [[ $USE_STATIC_IP == "true" ]]; then
        read -p "Enter IP address for $HOSTNAME (e.g., 10.1.10.11/24): " IP_ADDRESS
        echo "name=eth0,bridge=$BRIDGE,ip=$IP_ADDRESS,gw=$GATEWAY"
    else
        echo "name=eth0,bridge=$BRIDGE,ip=dhcp"
    fi
}

# Function to create base LXC container
create_base_container() {
    local CTID=$1
    local HOSTNAME=$2
    local CORES=$3
    local RAM=$4
    local DISK=$5
    
    # Get network config for this specific container
    local CONTAINER_NET_CONFIG=$(get_container_network "$HOSTNAME")
    
    msg_info "Creating LXC container $CTID ($HOSTNAME)..."
    
    pct create $CTID local:vztmpl/$TEMPLATE_NAME \
        --hostname $HOSTNAME \
        --cores $CORES \
        --memory $RAM \
        --swap 512 \
        --net0 "$CONTAINER_NET_CONFIG" \
        --storage $STORAGE \
        --rootfs $STORAGE:$DISK \
        --unprivileged 1 \
        --features nesting=1 \
        --nameserver 10.1.10.254 \
        --onboot 1 \
        --start 0
    
    # Add AppArmor unconfined for Docker support
    echo "lxc.apparmor.profile: unconfined" >> /etc/pve/lxc/${CTID}.conf
    
    msg_ok "Container $CTID created"
}

# Function to start container and wait for network
start_and_wait() {
    local CTID=$1
    msg_info "Starting container $CTID..."
    pct start $CTID
    sleep 5
    msg_ok "Container $CTID started"
}

# Function to execute command in container
exec_in_ct() {
    local CTID=$1
    shift
    pct exec $CTID -- bash -c "$*"
}

# Pi-hole deployment
deploy_pihole() {
    msg_info "=== Deploying Pi-hole ==="
    
    local CTID=$(get_ctid_from_user "Pi-hole")
    local HOSTNAME=$(get_hostname_from_user "Pi-hole" "pihole")
    
    create_base_container $CTID $HOSTNAME 2 1024 8
    start_and_wait $CTID
    
    msg_info "Installing Pi-hole..."
    exec_in_ct $CTID "apt-get update && apt-get upgrade -y"
    exec_in_ct $CTID "apt-get install -y curl"
    exec_in_ct $CTID "curl -sSL https://install.pi-hole.net | bash /dev/stdin --unattended"
    
    local PIHOLE_PASS=$(exec_in_ct $CTID "pihole -a -p" | grep "New password" | awk '{print $NF}')
    
    msg_ok "Pi-hole deployed on CT $CTID"
    msg_info "Access Pi-hole admin at: http://$(pct exec $CTID -- hostname -I | awk '{print $1}')/admin"
    msg_info "Password: Run 'pihole -a -p' inside the container to set a password"
}

# Trilium deployment
deploy_trilium() {
    msg_info "=== Deploying Trilium Notes ==="
    
    local CTID=$(get_ctid_from_user "Trilium Notes")
    local HOSTNAME=$(get_hostname_from_user "Trilium Notes" "trilium")
    
    create_base_container $CTID $HOSTNAME 2 2048 16
    start_and_wait $CTID
    
    msg_info "Installing Trilium..."
    exec_in_ct $CTID "apt-get update && apt-get upgrade -y"
    exec_in_ct $CTID "apt-get install -y wget curl jq"
    
    # Get the latest release URL and download
    msg_info "Downloading latest TriliumNext server..."
    exec_in_ct $CTID 'curl -sL https://api.github.com/repos/TriliumNext/Notes/releases/latest | jq -r ".assets[] | select(.name | test(\"TriliumNextNotes-.*-linux-x64.tar.xz\")) | .browser_download_url" > /tmp/trilium_url.txt'
    exec_in_ct $CTID "wget -i /tmp/trilium_url.txt -O /tmp/trilium.tar.xz"
    exec_in_ct $CTID "tar -xvf /tmp/trilium.tar.xz -C /tmp/"
    exec_in_ct $CTID 'mv /tmp/TriliumNextNotes-*-linux-x64 /opt/trilium'
    
    exec_in_ct $CTID "cat > /etc/systemd/system/trilium.service << 'EOF'
[Unit]
Description=Trilium Notes
After=network.target

[Service]
Type=simple
ExecStart=/opt/trilium/trilium.sh
WorkingDirectory=/opt/trilium
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF"
    exec_in_ct $CTID "systemctl daemon-reload"
    exec_in_ct $CTID "systemctl enable --now trilium"
    
    msg_ok "Trilium deployed on CT $CTID"
    msg_info "Access Trilium at: http://$(pct exec $CTID -- hostname -I | awk '{print $1}'):8080"
}

# Homarr deployment
deploy_homarr() {
    msg_info "=== Deploying Homarr ==="
    
    local CTID=$(get_ctid_from_user "Homarr")
    local HOSTNAME=$(get_hostname_from_user "Homarr" "homarr")
    
    create_base_container $CTID $HOSTNAME 2 2048 12
    start_and_wait $CTID
    
    msg_info "Installing Docker and Homarr..."
    exec_in_ct $CTID "apt-get update && apt-get upgrade -y"
    exec_in_ct $CTID "apt-get install -y curl ca-certificates"
    exec_in_ct $CTID "install -m 0755 -d /etc/apt/keyrings"
    exec_in_ct $CTID "curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc"
    exec_in_ct $CTID "chmod a+r /etc/apt/keyrings/docker.asc"
    exec_in_ct $CTID 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'
    exec_in_ct $CTID "apt-get update"
    exec_in_ct $CTID "apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin"
    
    exec_in_ct $CTID "mkdir -p /opt/homarr/configs /opt/homarr/icons /opt/homarr/data"
    exec_in_ct $CTID "mkdir -p /opt/docker"
    
    # Create docker-compose file
    exec_in_ct $CTID "cat > /opt/docker/docker-compose.yml << 'EOFCOMPOSE'
version: '3.8'

services:
  homarr:
    image: ghcr.io/ajnart/homarr:latest
    container_name: homarr
    restart: unless-stopped
    ports:
      - \"7575:7575\"
    volumes:
      - /opt/homarr/configs:/app/data/configs
      - /opt/homarr/icons:/app/public/icons
      - /opt/homarr/data:/data
    environment:
      - TZ=Europe/London
EOFCOMPOSE"
    
    exec_in_ct $CTID "cd /opt/docker && docker compose up -d"
    
    msg_ok "Homarr deployed on CT $CTID"
    msg_info "Access Homarr at: http://$(pct exec $CTID -- hostname -I | awk '{print $1}'):7575"
}

# Observium deployment
deploy_observium() {
    msg_info "=== Deploying Observium ==="
    
    local CTID=$(get_ctid_from_user "Observium")
    local HOSTNAME=$(get_hostname_from_user "Observium" "observium")
    
    create_base_container $CTID $HOSTNAME 2 4096 20
    start_and_wait $CTID
    
    msg_info "Installing Observium dependencies..."
    exec_in_ct $CTID "apt-get update && apt-get upgrade -y"
    exec_in_ct $CTID "apt-get install -y libapache2-mod-php php php-cli php-mysql php-gd php-bcmath php-mbstring php-opcache php-apcu php-xml php-curl snmp fping mariadb-server mariadb-client python3-pymysql python3-dotenv rrdtool subversion whois mtr-tiny ipmitool graphviz imagemagick apache2 wget"
    
    msg_info "Setting up MariaDB..."
    exec_in_ct $CTID "systemctl start mariadb"
    local DB_PASS=$(openssl rand -base64 12)
    exec_in_ct $CTID "mysql -e \"CREATE DATABASE observium DEFAULT CHARACTER SET utf8 COLLATE utf8_general_ci;\""
    exec_in_ct $CTID "mysql -e \"CREATE USER 'observium'@'localhost' IDENTIFIED BY '$DB_PASS';\""
    exec_in_ct $CTID "mysql -e \"GRANT ALL PRIVILEGES ON observium.* TO 'observium'@'localhost';\""
    exec_in_ct $CTID "mysql -e \"FLUSH PRIVILEGES;\""
    
    msg_info "Installing Observium Community Edition..."
    exec_in_ct $CTID "mkdir -p /opt/observium && cd /opt/observium"
    exec_in_ct $CTID "wget http://www.observium.org/observium-community-latest.tar.gz -O /tmp/observium.tar.gz"
    exec_in_ct $CTID "tar zxvf /tmp/observium.tar.gz -C /opt/"
    exec_in_ct $CTID "cd /opt/observium && cp config.php.default config.php"
    exec_in_ct $CTID "sed -i \"s/\\\$config\['db_user'\] = 'USERNAME';/\\\$config['db_user'] = 'observium';/\" /opt/observium/config.php"
    exec_in_ct $CTID "sed -i \"s/\\\$config\['db_pass'\] = 'PASSWORD';/\\\$config['db_pass'] = '$DB_PASS';/\" /opt/observium/config.php"
    exec_in_ct $CTID "cd /opt/observium && ./discovery.php -u"
    exec_in_ct $CTID "chown -R www-data:www-data /opt/observium"
    
    exec_in_ct $CTID "cat > /etc/apache2/sites-available/observium.conf << 'EOF'
<VirtualHost *:80>
    DocumentRoot /opt/observium/html
    ServerName observium
    <Directory /opt/observium/html>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF"
    exec_in_ct $CTID "a2dissite 000-default"
    exec_in_ct $CTID "a2ensite observium"
    exec_in_ct $CTID "a2enmod rewrite"
    exec_in_ct $CTID "systemctl restart apache2"
    
    local ADMIN_PASS=$(openssl rand -base64 12)
    exec_in_ct $CTID "cd /opt/observium && ./adduser.php admin $ADMIN_PASS 10"
    
    msg_ok "Observium deployed on CT $CTID"
    msg_info "Access Observium at: http://$(pct exec $CTID -- hostname -I | awk '{print $1}')"
    msg_info "Username: admin"
    msg_info "Password: $ADMIN_PASS"
    msg_warn "SAVE THIS PASSWORD! Database password: $DB_PASS"
}

# UniFi Controller deployment
deploy_unifi() {
    msg_info "=== Deploying UniFi Controller ==="
    
    local CTID=$(get_ctid_from_user "UniFi Controller")
    local HOSTNAME=$(get_hostname_from_user "UniFi Controller" "unifi")
    
    create_base_container $CTID $HOSTNAME 2 2048 16
    start_and_wait $CTID
    
    msg_info "Installing UniFi Controller..."
    exec_in_ct $CTID "apt-get update && apt-get upgrade -y"
    exec_in_ct $CTID "apt-get install -y ca-certificates apt-transport-https gnupg wget"
    
    # Add MongoDB repo
    exec_in_ct $CTID "wget -qO - https://www.mongodb.org/static/pgp/server-4.4.asc | apt-key add -"
    exec_in_ct $CTID 'echo "deb http://repo.mongodb.org/apt/debian bullseye/mongodb-org/4.4 main" | tee /etc/apt/sources.list.d/mongodb-org-4.4.list'
    
    # Add UniFi repo
    exec_in_ct $CTID "wget -qO - https://dl.ui.com/unifi/unifi-repo.gpg | tee /etc/apt/trusted.gpg.d/unifi-repo.gpg"
    exec_in_ct $CTID 'echo "deb https://www.ui.com/downloads/unifi/debian stable ubiquiti" | tee /etc/apt/sources.list.d/100-ubnt-unifi.list'
    
    exec_in_ct $CTID "apt-get update"
    exec_in_ct $CTID "apt-get install -y openjdk-11-jre-headless mongodb-org unifi"
    
    msg_ok "UniFi Controller deployed on CT $CTID"
    msg_info "Access UniFi Controller at: https://$(pct exec $CTID -- hostname -I | awk '{print $1}'):8443"
    msg_warn "Initial setup required through web interface"
}

# Main menu
show_menu() {
    clear
    echo "======================================"
    echo "  Proxmox LXC Deployment Script"
    echo "======================================"
    echo "1) Deploy Pi-hole"
    echo "2) Deploy Trilium Notes"
    echo "3) Deploy Homarr"
    echo "4) Deploy Observium"
    echo "5) Deploy UniFi Controller"
    echo "6) Deploy All"
    echo "7) Exit"
    echo "======================================"
}

# Main script
main() {
    check_root
    
    # Download Debian template if not exists
    msg_info "Checking for Debian 12 template..."
    pveam update
    
    # Get the latest Debian 12 template name
    TEMPLATE_NAME=$(pveam available | grep -i "debian-12-standard" | sort -V | tail -n1 | awk '{print $2}')
    
    if [ -z "$TEMPLATE_NAME" ]; then
        msg_error "No Debian 12 template found in repository"
        exit 1
    fi
    
    TEMPLATE_PATH="/var/lib/vz/template/cache/$TEMPLATE_NAME"
    
    if [ ! -f "$TEMPLATE_PATH" ]; then
        msg_info "Downloading Debian 12 template: $TEMPLATE_NAME..."
        pveam download local "$TEMPLATE_NAME"
        msg_ok "Template downloaded: $TEMPLATE_NAME"
    else
        msg_ok "Template already exists: $TEMPLATE_NAME"
    fi
    
    select_storage
    get_network_config
    
    show_menu
    read -p "Select an option [1-7]: " choice
    
    case $choice in
        1) deploy_pihole ;;
        2) deploy_trilium ;;
        3) deploy_homarr ;;
        4) deploy_observium ;;
        5) deploy_unifi ;;
        6)
            deploy_pihole
            deploy_trilium
            deploy_homarr
            deploy_observium
            deploy_unifi
            ;;
        7) exit 0 ;;
        *) msg_error "Invalid option"; exit 1 ;;
    esac
    
    msg_ok "Deployment complete!"
}

main "$@"
