#!/usr/bin/env bash

# Proxmox LXC Container Management Helper Script
# Quick commands for managing deployed containers

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

msg_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
msg_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
msg_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Function to list all containers with services
list_containers() {
    echo "======================================"
    echo "  Active LXC Containers"
    echo "======================================"
    pct list | grep -E "pihole|trilium|homarr|observium|unifi" || msg_warn "No service containers found"
}

# Function to get container IP
get_container_ip() {
    local CTID=$1
    pct exec $CTID -- hostname -I | awk '{print $1}'
}

# Function to show service URLs
show_urls() {
    msg_info "Service Access URLs:"
    echo "======================================"
    
    for CTID in $(pct list | grep -E "pihole|trilium|homarr|observium|unifi" | awk '{print $1}'); do
        local HOSTNAME=$(pct exec $CTID -- hostname)
        local IP=$(get_container_ip $CTID)
        
        case $HOSTNAME in
            pihole)
                echo "Pi-hole (CT $CTID): http://$IP/admin"
                ;;
            trilium)
                echo "Trilium (CT $CTID): http://$IP:8080"
                ;;
            homarr)
                echo "Homarr (CT $CTID): http://$IP:7575"
                ;;
            observium)
                echo "Observium (CT $CTID): http://$IP"
                ;;
            unifi)
                echo "UniFi Controller (CT $CTID): https://$IP:8443"
                ;;
        esac
    done
    echo "======================================"
}

# Function to update all containers
update_all() {
    msg_info "Updating all service containers..."
    
    for CTID in $(pct list | grep -E "pihole|trilium|homarr|observium|unifi" | awk '{print $1}'); do
        local HOSTNAME=$(pct exec $CTID -- hostname)
        msg_info "Updating $HOSTNAME (CT $CTID)..."
        
        pct exec $CTID -- bash -c "apt-get update && apt-get upgrade -y"
        
        # Service-specific updates
        case $HOSTNAME in
            pihole)
                pct exec $CTID -- pihole -up
                ;;
            homarr)
                pct exec $CTID -- bash -c "docker pull ghcr.io/ajnart/homarr:latest && docker restart homarr"
                ;;
        esac
        
        msg_ok "$HOSTNAME updated"
    done
}

# Function to backup containers
backup_containers() {
    local STORAGE=${1:-local}
    msg_info "Backing up service containers to $STORAGE..."
    
    for CTID in $(pct list | grep -E "pihole|trilium|homarr|observium|unifi" | awk '{print $1}'); do
        local HOSTNAME=$(pct exec $CTID -- hostname)
        msg_info "Backing up $HOSTNAME (CT $CTID)..."
        vzdump $CTID --compress zstd --mode snapshot --storage $STORAGE
        msg_ok "$HOSTNAME backup complete"
    done
}

# Function to stop all service containers
stop_all() {
    msg_info "Stopping all service containers..."
    for CTID in $(pct list | grep -E "pihole|trilium|homarr|observium|unifi" | awk '{print $1}'); do
        pct stop $CTID
    done
    msg_ok "All containers stopped"
}

# Function to start all service containers
start_all() {
    msg_info "Starting all service containers..."
    for CTID in $(pct list | grep -E "pihole|trilium|homarr|observium|unifi" | awk '{print $1}'); do
        pct start $CTID
    done
    msg_ok "All containers started"
}

# Function to show container resource usage
show_resources() {
    echo "======================================"
    echo "  Container Resource Usage"
    echo "======================================"
    printf "%-6s %-15s %-8s %-8s %-8s %-8s\n" "CTID" "Name" "Status" "CPU%" "MEM" "DISK"
    echo "--------------------------------------"
    
    for CTID in $(pct list | grep -E "pihole|trilium|homarr|observium|unifi" | awk '{print $1}'); do
        local NAME=$(pct exec $CTID -- hostname 2>/dev/null || echo "N/A")
        local STATUS=$(pct status $CTID | awk '{print $2}')
        
        if [ "$STATUS" == "running" ]; then
            local CPU=$(pct exec $CTID -- top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
            local MEM=$(pct exec $CTID -- free -h | awk 'NR==2{print $3}')
            local DISK=$(pct exec $CTID -- df -h / | awk 'NR==2{print $3}')
            printf "%-6s %-15s %-8s %-8s %-8s %-8s\n" "$CTID" "$NAME" "$STATUS" "$CPU" "$MEM" "$DISK"
        else
            printf "%-6s %-15s %-8s %-8s %-8s %-8s\n" "$CTID" "$NAME" "$STATUS" "N/A" "N/A" "N/A"
        fi
    done
    echo "======================================"
}

# Function to enter container console
enter_container() {
    local CTID=$1
    if [ -z "$CTID" ]; then
        list_containers
        read -p "Enter Container ID: " CTID
    fi
    pct enter $CTID
}

# Main menu
show_menu() {
    clear
    echo "======================================"
    echo "  LXC Container Management"
    echo "======================================"
    echo "1) List containers"
    echo "2) Show service URLs"
    echo "3) Show resource usage"
    echo "4) Update all containers"
    echo "5) Backup all containers"
    echo "6) Start all containers"
    echo "7) Stop all containers"
    echo "8) Enter container console"
    echo "9) Exit"
    echo "======================================"
}

# Main script
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

if [ $# -eq 0 ]; then
    show_menu
    read -p "Select an option [1-9]: " choice
    
    case $choice in
        1) list_containers ;;
        2) show_urls ;;
        3) show_resources ;;
        4) update_all ;;
        5) 
            read -p "Enter storage location (default: local): " STORAGE
            backup_containers ${STORAGE:-local}
            ;;
        6) start_all ;;
        7) stop_all ;;
        8) enter_container ;;
        9) exit 0 ;;
        *) echo "Invalid option"; exit 1 ;;
    esac
else
    # Allow command-line usage
    case $1 in
        list) list_containers ;;
        urls) show_urls ;;
        resources) show_resources ;;
        update) update_all ;;
        backup) backup_containers ${2:-local} ;;
        start) start_all ;;
        stop) stop_all ;;
        enter) enter_container $2 ;;
        *) echo "Usage: $0 {list|urls|resources|update|backup|start|stop|enter [CTID]}"; exit 1 ;;
    esac
fi
