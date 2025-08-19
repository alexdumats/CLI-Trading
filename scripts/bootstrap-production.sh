#!/bin/bash
#
# Production Bootstrap Script for CLI-Trading Multi-Agent System
# 
# This script prepares a fresh Ubuntu 22.04 LTS server for production deployment
# of the modular cryptocurrency trading system.
#
# Usage: sudo ./scripts/bootstrap-production.sh
#
set -euo pipefail

# Color output functions
red() { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
blue() { echo -e "\033[34m$1\033[0m"; }

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Error handling
error_exit() {
    red "ERROR: $1"
    exit 1
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error_exit "This script must be run as root (use sudo)"
fi

log "Starting production bootstrap for CLI-Trading system..."

# Step 1: System Updates and Base Packages
log "Step 1: Updating system packages..."
apt-get update -y || error_exit "Failed to update package lists"
apt-get upgrade -y || error_exit "Failed to upgrade packages"

# Install essential packages
log "Installing essential packages..."
apt-get install -y \
    curl \
    wget \
    git \
    htop \
    vim \
    unzip \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release \
    jq \
    openssl \
    ufw \
    fail2ban \
    logrotate \
    cron \
    rsync \
    || error_exit "Failed to install essential packages"

green "✓ System packages updated and essential tools installed"

# Step 2: Create System User
log "Step 2: Creating system user for trading application..."
if ! id "trader" &>/dev/null; then
    useradd -m -s /bin/bash trader
    usermod -aG sudo trader
    green "✓ Created user 'trader'"
else
    yellow "User 'trader' already exists, skipping creation"
fi

# Step 3: Docker Installation
log "Step 3: Installing Docker and Docker Compose..."
if ! command -v docker &> /dev/null; then
    # Add Docker's official GPG key
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    
    # Add Docker repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    # Add trader user to docker group
    usermod -aG docker trader
    
    # Enable and start Docker
    systemctl enable docker
    systemctl start docker
    
    green "✓ Docker installed and configured"
else
    yellow "Docker already installed, skipping installation"
fi

# Install Docker Compose standalone (fallback)
if ! command -v docker-compose &> /dev/null; then
    log "Installing Docker Compose standalone..."
    DOCKER_COMPOSE_VERSION="2.21.0"
    curl -L "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    green "✓ Docker Compose installed"
fi

# Step 4: Node.js Installation (for local tooling)
log "Step 4: Installing Node.js..."
if ! command -v node &> /dev/null; then
    # Install Node.js 20.x
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
    green "✓ Node.js $(node --version) installed"
else
    yellow "Node.js already installed: $(node --version)"
fi

# Step 5: Security Hardening
log "Step 5: Configuring security hardening..."

# Configure UFW firewall
log "Configuring UFW firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 80/tcp
ufw allow 443/tcp
echo "y" | ufw enable
green "✓ UFW firewall configured"

# Configure fail2ban
log "Configuring fail2ban..."
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3

[sshd]
enabled = true
port = ssh
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
EOF

systemctl enable fail2ban
systemctl restart fail2ban
green "✓ Fail2ban configured"

# Step 6: Directory Structure
log "Step 6: Creating application directory structure..."
mkdir -p /opt/cli-trading
chown trader:trader /opt/cli-trading

# Create deployment directories
sudo -u trader mkdir -p /opt/cli-trading/{secrets,backups,logs,data}
sudo -u trader mkdir -p /opt/cli-trading/data/{redis,postgres,grafana,prometheus,loki}

green "✓ Directory structure created"

# Step 7: SSL Certificate Preparation
log "Step 7: Preparing SSL certificate directory..."
mkdir -p /opt/cli-trading/certs
chown trader:trader /opt/cli-trading/certs
chmod 750 /opt/cli-trading/certs

# Step 8: Monitoring Tools Installation
log "Step 8: Installing monitoring and utility tools..."

# Install prometheus node exporter
if ! systemctl is-active --quiet node_exporter; then
    wget -q https://github.com/prometheus/node_exporter/releases/download/v1.6.1/node_exporter-1.6.1.linux-amd64.tar.gz
    tar xzf node_exporter-1.6.1.linux-amd64.tar.gz
    cp node_exporter-1.6.1.linux-amd64/node_exporter /usr/local/bin/
    rm -rf node_exporter-1.6.1.linux-amd64*
    
    # Create systemd service
    cat > /etc/systemd/system/node_exporter.service << EOF
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=nobody
Group=nobody
Type=simple
ExecStart=/usr/local/bin/node_exporter
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable node_exporter
    systemctl start node_exporter
    green "✓ Node Exporter installed and started"
fi

# Step 9: Log Rotation Configuration
log "Step 9: Configuring log rotation..."
cat > /etc/logrotate.d/cli-trading << EOF
/opt/cli-trading/logs/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 0644 trader trader
    postrotate
        /usr/bin/docker kill --signal="USR1" \$(docker ps -q --filter "label=com.docker.compose.project=cli-trading") 2>/dev/null || true
    endscript
}
EOF

green "✓ Log rotation configured"

# Step 10: System Limits and Optimization
log "Step 10: Optimizing system limits..."

# Increase file descriptor limits
cat >> /etc/security/limits.conf << EOF
trader soft nofile 65536
trader hard nofile 65536
trader soft nproc 32768
trader hard nproc 32768
EOF

# Optimize kernel parameters
cat > /etc/sysctl.d/99-cli-trading.conf << EOF
# Network optimizations
net.core.somaxconn = 65536
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 10

# Memory optimizations
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5

# File system optimizations
fs.file-max = 2097152
EOF

sysctl -p /etc/sysctl.d/99-cli-trading.conf
green "✓ System limits and kernel parameters optimized"

# Step 11: Backup Script Installation
log "Step 11: Installing backup scripts..."
cat > /opt/cli-trading/scripts/backup-system.sh << 'EOF'
#!/bin/bash
# Automated backup script for CLI-Trading system

set -euo pipefail

BACKUP_DIR="/opt/cli-trading/backups"
DATE=$(date '+%Y%m%d_%H%M%S')

# Create backup directory
mkdir -p "$BACKUP_DIR/$DATE"

# Backup secrets (encrypted)
if [ -d "/opt/cli-trading/secrets" ]; then
    tar -czf "$BACKUP_DIR/$DATE/secrets_$DATE.tar.gz" -C /opt/cli-trading secrets/
    gpg --symmetric --cipher-algo AES256 --output "$BACKUP_DIR/$DATE/secrets_$DATE.tar.gz.gpg" "$BACKUP_DIR/$DATE/secrets_$DATE.tar.gz"
    rm "$BACKUP_DIR/$DATE/secrets_$DATE.tar.gz"
fi

# Backup configuration
tar -czf "$BACKUP_DIR/$DATE/config_$DATE.tar.gz" -C /opt/cli-trading .env docker-compose.yml config/

# Backup PostgreSQL
docker exec cli-trading-postgres-1 pg_dumpall -U trader > "$BACKUP_DIR/$DATE/postgres_$DATE.sql"
gzip "$BACKUP_DIR/$DATE/postgres_$DATE.sql"

# Backup Redis
docker exec cli-trading-redis-1 redis-cli BGSAVE
sleep 5
docker cp cli-trading-redis-1:/data/dump.rdb "$BACKUP_DIR/$DATE/redis_$DATE.rdb"

# Cleanup old backups (keep 7 days)
find "$BACKUP_DIR" -type d -mtime +7 -exec rm -rf {} \;

echo "Backup completed: $BACKUP_DIR/$DATE"
EOF

chmod +x /opt/cli-trading/scripts/backup-system.sh
chown trader:trader /opt/cli-trading/scripts/backup-system.sh

# Add to crontab for trader user
sudo -u trader crontab -l 2>/dev/null | { cat; echo "0 2 * * * /opt/cli-trading/scripts/backup-system.sh"; } | sudo -u trader crontab -

green "✓ Backup scripts installed and scheduled"

# Step 12: Health Check Script
log "Step 12: Installing health check script..."
cat > /opt/cli-trading/scripts/health-check.sh << 'EOF'
#!/bin/bash
# Comprehensive health check for CLI-Trading system

set -euo pipefail

# Color functions
red() { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }

check_service() {
    local service=$1
    local url=$2
    
    if curl -sf "$url" > /dev/null; then
        green "✓ $service: healthy"
        return 0
    else
        red "✗ $service: unhealthy"
        return 1
    fi
}

echo "=== CLI-Trading System Health Check ==="
echo "Timestamp: $(date)"
echo

# Check Docker services
echo "Docker Services:"
docker compose -f /opt/cli-trading/docker-compose.yml ps

echo
echo "Health Endpoints:"

# Check all agent health endpoints
check_service "Orchestrator" "http://localhost:7001/health"
check_service "Portfolio Manager" "http://localhost:7002/health"
check_service "Market Analyst" "http://localhost:7003/health"
check_service "Risk Manager" "http://localhost:7004/health"
check_service "Trade Executor" "http://localhost:7005/health"
check_service "Notification Manager" "http://localhost:7006/health"
check_service "Parameter Optimizer" "http://localhost:7007/health"
check_service "MCP Hub Controller" "http://localhost:7008/health"

echo
echo "Infrastructure:"
check_service "Prometheus" "http://localhost:9090/-/healthy"
check_service "Grafana" "http://localhost:3000/api/health"
check_service "Redis" "http://localhost:6379" || echo "Redis check via ping"

echo
echo "=== End Health Check ==="
EOF

chmod +x /opt/cli-trading/scripts/health-check.sh
chown trader:trader /opt/cli-trading/scripts/health-check.sh

green "✓ Health check script installed"

# Step 13: Environment Validation
log "Step 13: Validating installation..."

# Check Docker
if ! docker --version; then
    error_exit "Docker installation validation failed"
fi

# Check Docker Compose
if ! docker compose version; then
    error_exit "Docker Compose installation validation failed"
fi

# Check Node.js
if ! node --version; then
    error_exit "Node.js installation validation failed"
fi

# Check UFW status
if ! ufw status | grep -q "Status: active"; then
    error_exit "UFW firewall validation failed"
fi

green "✓ Installation validation completed successfully"

# Step 14: Final Setup Instructions
log "Step 14: Displaying final setup instructions..."

blue "================================================================"
blue "🎉 Production Bootstrap Completed Successfully!"
blue "================================================================"
echo
yellow "Next Steps:"
echo "1. Switch to trader user: sudo su - trader"
echo "2. Clone your repository to /opt/cli-trading/"
echo "3. Copy .env.example to .env and configure"
echo "4. Create secrets in /opt/cli-trading/secrets/"
echo "5. Run deployment script: ./scripts/deploy-production.sh"
echo
yellow "Important Files Created:"
echo "• Health check: /opt/cli-trading/scripts/health-check.sh"
echo "• Backup script: /opt/cli-trading/scripts/backup-system.sh (scheduled daily at 2 AM)"
echo "• Log rotation: /etc/logrotate.d/cli-trading"
echo
yellow "Security Configuration:"
echo "• UFW firewall: active (SSH, HTTP, HTTPS allowed)"
echo "• Fail2ban: active (SSH protection)"
echo "• System limits: optimized for high-performance trading"
echo
yellow "Monitoring:"
echo "• Node Exporter: running on port 9100"
echo "• System logs: /var/log/syslog, /var/log/auth.log"
echo
blue "================================================================"

log "Bootstrap script completed successfully!"