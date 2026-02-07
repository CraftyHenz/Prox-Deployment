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
    
    read -p "Use DHCP? (y/n, default: y): " USE_DHCP
    USE_DHCP=${USE_DHCP:-y}
    
    if [[ $USE_DHCP =~ ^[Nn]$ ]]; then
        read -p "Enter IP address (e.g., 192.168.1.100/24): " IP_ADDRESS
        read -p "Enter gateway: " GATEWAY
        NET_CONFIG="name=eth0,bridge=$BRIDGE,ip=$IP_ADDRESS,gw=$GATEWAY"
    else
        NET_CONFIG="name=eth0,bridge=$BRIDGE,ip=dhcp"
    fi
}

# Function to create base LXC container
create_base_container() {
    local CTID=$1
    local HOSTNAME=$2
    local CORES=$3
    local RAM=$4
    local DISK=$5
    local TEMPLATE=$6
    
    msg_info "Creating LXC container $CTID ($HOSTNAME)..."
    
    pct create $CTID $TEMPLATE \
        --hostname $HOSTNAME \
        --cores $CORES \
        --memory $RAM \
        --swap 512 \
        --net0 $NET_CONFIG \
        --storage $STORAGE \
        --rootfs $STORAGE:$DISK \
        --unprivileged 1 \
        --features nesting=1 \
        --onboot 1 \
        --start 0
    
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
    
    local CTID=$(get_next_ctid)
    local HOSTNAME="pihole"
    local TEMPLATE="/var/lib/vz/template/cache/debian-12-standard_12.7-1_amd64.tar.zst"
    
    create_base_container $CTID $HOSTNAME 2 1024 8 $TEMPLATE
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
    
    local CTID=$(get_next_ctid)
    local HOSTNAME="trilium"
    local TEMPLATE="/var/lib/vz/template/cache/debian-12-standard_12.7-1_amd64.tar.zst"
    
    create_base_container $CTID $HOSTNAME 2 2048 16 $TEMPLATE
    start_and_wait $CTID
    
    msg_info "Installing Trilium..."
    exec_in_ct $CTID "apt-get update && apt-get upgrade -y"
    exec_in_ct $CTID "apt-get install -y wget"
    exec_in_ct $CTID "wget https://github.com/zadam/trilium/releases/latest/download/trilium-linux-x64-server.tar.xz -O /tmp/trilium.tar.xz"
    exec_in_ct $CTID "tar -xvf /tmp/trilium.tar.xz -C /opt/"
    exec_in_ct $CTID "cat > /etc/systemd/system/trilium.service << 'EOF'
[Unit]
Description=Trilium Notes
After=network.target

[Service]
Type=simple
ExecStart=/opt/trilium-linux-x64-server/trilium.sh
WorkingDirectory=/opt/trilium-linux-x64-server
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
    
    local CTID=$(get_next_ctid)
    local HOSTNAME="homarr"
    local TEMPLATE="/var/lib/vz/template/cache/debian-12-standard_12.7-1_amd64.tar.zst"
    
    create_base_container $CTID $HOSTNAME 2 2048 12 $TEMPLATE
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
    exec_in_ct $CTID "docker run -d --name homarr --restart=unless-stopped -p 7575:7575 -v /opt/homarr/configs:/app/data/configs -v /opt/homarr/icons:/app/public/icons -v /opt/homarr/data:/data ghcr.io/ajnart/homarr:latest"
    
    msg_ok "Homarr deployed on CT $CTID"
    msg_info "Access Homarr at: http://$(pct exec $CTID -- hostname -I | awk '{print $1}'):7575"
}

# Observium deployment
deploy_observium() {
    msg_info "=== Deploying Observium ==="
    
    local CTID=$(get_next_ctid)
    local HOSTNAME="observium"
    local TEMPLATE="/var/lib/vz/template/cache/debian-12-standard_12.7-1_amd64.tar.zst"
    
    create_base_container $CTID $HOSTNAME 2 4096 20 $TEMPLATE
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
    
    local CTID=$(get_next_ctid)
    local HOSTNAME="unifi"
    local TEMPLATE="/var/lib/vz/template/cache/debian-12-standard_12.7-1_amd64.tar.zst"
    
    create_base_container $CTID $HOSTNAME 2 2048 16 $TEMPLATE
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
    TEMPLATE_PATH="/var/lib/vz/template/cache/debian-12-standard_12.7-1_amd64.tar.zst"
    if [ ! -f "$TEMPLATE_PATH" ]; then
        msg_info "Downloading Debian 12 template..."
        pveam update
        pveam download local debian-12-standard_12.7-1_amd64.tar.zst
        msg_ok "Template downloaded"
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
