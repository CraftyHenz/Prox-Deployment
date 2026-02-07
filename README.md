# Proxmox LXC Deployment Script

Automated deployment script for common homelab services on Proxmox LXC containers.

## Supported Services

- **Pi-hole** - Network-wide ad blocking
- **Trilium Notes** - Hierarchical note-taking application
- **Homarr** - Customizable dashboard/homepage
- **Observium** - Network monitoring platform
- **UniFi Controller** - Ubiquiti network management

## Prerequisites

1. Proxmox VE 7.x or 8.x
2. Root access to Proxmox host
3. Internet connectivity
4. Storage configured (local-lvm, ZFS, etc.)

## Installation

1. Upload the script to your Proxmox host:
```bash
wget https://your-server.com/proxmox-lxc-deploy.sh -O /root/proxmox-lxc-deploy.sh
# Or copy it manually via SCP/SFTP
```

2. Make it executable:
```bash
chmod +x /root/proxmox-lxc-deploy.sh
```

3. Run the script:
```bash
./proxmox-lxc-deploy.sh
```

## Usage

The script will:
1. Download the Debian 12 template (if not already present)
2. Prompt you to select storage location
3. Ask for network configuration (DHCP or static IP)
4. Present a menu to deploy individual services or all at once

### Menu Options

```
1) Deploy Pi-hole          - DNS-based ad blocker
2) Deploy Trilium Notes    - Note-taking application
3) Deploy Homarr           - Dashboard/homepage
4) Deploy Observium        - Network monitoring
5) Deploy UniFi Controller - UniFi network management
6) Deploy All              - Deploy all services
7) Exit
```

## Container Specifications

| Service | CPU Cores | RAM | Disk | Ports |
|---------|-----------|-----|------|-------|
| Pi-hole | 2 | 1GB | 8GB | 80, 53 |
| Trilium | 2 | 2GB | 16GB | 8080 |
| Homarr | 2 | 2GB | 12GB | 7575 |
| Observium | 2 | 4GB | 20GB | 80 |
| UniFi | 2 | 2GB | 16GB | 8443, 8080, 3478 |

## Post-Deployment

### Pi-hole
- Access: `http://<container-ip>/admin`
- Set password: Run `pct exec <CTID> -- pihole -a -p` on Proxmox host
- Configure DNS settings on your router or devices

### Trilium Notes
- Access: `http://<container-ip>:8080`
- Create admin account on first visit
- Data stored in `/opt/trilium-linux-x64-server/`

### Homarr
- Access: `http://<container-ip>:7575`
- Configure widgets and services through web UI
- Data stored in `/opt/homarr/`

### Observium
- Access: `http://<container-ip>`
- Login with credentials shown after installation
- Add devices via web interface or CLI

### UniFi Controller
- Access: `https://<container-ip>:8443`
- Accept self-signed certificate warning
- Complete setup wizard
- Adopt UniFi devices

## Container Management

### Start/Stop Containers
```bash
pct start <CTID>
pct stop <CTID>
pct restart <CTID>
```

### Access Container Console
```bash
pct enter <CTID>
```

### View Container Status
```bash
pct status <CTID>
```

### List All Containers
```bash
pct list
```

## Troubleshooting

### Container won't start
```bash
# Check container status
pct status <CTID>

# View container config
pct config <CTID>

# Check logs
journalctl -u pve-container@<CTID>
```

### Network issues
```bash
# Enter container
pct enter <CTID>

# Check network
ip addr
ping 8.8.8.8

# Restart networking
systemctl restart networking
```

### Service not responding
```bash
# Enter container
pct enter <CTID>

# Check service status (example for Homarr)
docker ps

# Check logs
journalctl -u trilium  # for Trilium
docker logs homarr     # for Homarr
```

## Backup

### Manual Backup
```bash
vzdump <CTID> --compress zstd --mode snapshot --storage <storage-name>
```

### Automated Backup
Configure via Proxmox GUI:
- Datacenter → Backup
- Add backup job with desired schedule

## Updates

### Update Container OS
```bash
pct enter <CTID>
apt update && apt upgrade -y
```

### Update Applications
Each application has its own update process:

- **Pi-hole**: `pihole -up`
- **Trilium**: Download new release, extract to `/opt/`, restart service
- **Homarr**: `docker pull ghcr.io/ajnart/homarr:latest && docker restart homarr`
- **Observium**: Follow official update guide
- **UniFi**: `apt update && apt upgrade unifi`

## Security Recommendations

1. **Change default passwords** immediately after deployment
2. **Configure firewall rules** to restrict access
3. **Enable automatic updates** for security patches
4. **Use HTTPS** with proper certificates (consider reverse proxy)
5. **Regular backups** - test restore procedures
6. **Monitor logs** for suspicious activity

## Customization

You can modify the script to:
- Change resource allocations (CPU, RAM, disk)
- Use different base templates (Ubuntu, Alpine, etc.)
- Add additional services
- Modify network configurations
- Change default ports

Edit the relevant deployment function in the script:
```bash
deploy_<service_name>() {
    # Modify CTID, HOSTNAME, cores, RAM, disk size
    create_base_container $CTID $HOSTNAME 2 2048 16 $TEMPLATE
}
```

## Known Issues

1. **Observium Community Edition** has limitations compared to Professional
2. **UniFi Controller** may require port forwarding for remote access
3. **MongoDB version** for UniFi may need adjustment for newer releases
4. First-time template downloads can take several minutes

## Contributing

Feel free to modify and extend this script for your needs. Common additions:
- Jellyfin media server
- Home Assistant
- Nextcloud
- Portainer
- Nginx Proxy Manager

## License

This script is provided as-is for personal use. Please review and test in a non-production environment first.

## Support

For Proxmox-specific issues: https://forum.proxmox.com/
For application-specific issues: Refer to each project's documentation

---

**Note**: Always review scripts before running them with root privileges. This script creates unprivileged containers with nesting enabled for Docker support where needed.
