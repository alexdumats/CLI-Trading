#!/bin/bash
#
# Enhanced Monitoring Setup Script for CLI-Trading System
#
# This script configures comprehensive monitoring, alerting, and observability
# stack including Prometheus, Grafana, Alertmanager, and log aggregation.
#
# Usage: ./scripts/setup-monitoring.sh [--install-exporters] [--configure-alerts]
#
set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MONITORING_LOG="/opt/cli-trading/logs/monitoring-setup.log"
INSTALL_EXPORTERS=false
CONFIGURE_ALERTS=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --install-exporters)
            INSTALL_EXPORTERS=true
            shift
            ;;
        --configure-alerts)
            CONFIGURE_ALERTS=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--install-exporters] [--configure-alerts]"
            exit 1
            ;;
    esac
done

# Color output functions
red() { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
blue() { echo -e "\033[34m$1\033[0m"; }
bold() { echo -e "\033[1m$1\033[0m"; }

# Logging function
log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$message"
    echo "$message" >> "$MONITORING_LOG" 2>/dev/null || true
}

# Create monitoring directories
setup_directories() {
    log "Setting up monitoring directories..."
    
    mkdir -p /opt/cli-trading/{prometheus,grafana,alertmanager,loki}/data
    mkdir -p /opt/cli-trading/grafana/{dashboards,provisioning}
    mkdir -p /opt/cli-trading/prometheus/rules
    mkdir -p /opt/cli-trading/alertmanager/templates
    
    # Set proper permissions
    chown -R trader:trader /opt/cli-trading/
    
    green "✓ Monitoring directories created"
}

# Install additional exporters
install_exporters() {
    if [[ "$INSTALL_EXPORTERS" != "true" ]]; then
        return 0
    fi
    
    log "Installing additional Prometheus exporters..."
    
    # Install blackbox exporter for endpoint monitoring
    if ! systemctl is-active --quiet blackbox_exporter; then
        log "Installing blackbox exporter..."
        
        wget -q https://github.com/prometheus/blackbox_exporter/releases/download/v0.24.0/blackbox_exporter-0.24.0.linux-amd64.tar.gz
        tar xzf blackbox_exporter-0.24.0.linux-amd64.tar.gz
        cp blackbox_exporter-0.24.0.linux-amd64/blackbox_exporter /usr/local/bin/
        rm -rf blackbox_exporter-0.24.0.linux-amd64*
        
        # Create configuration
        cat > /etc/blackbox_exporter.yml << 'EOF'
modules:
  http_2xx:
    prober: http
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: []
      method: GET
      follow_redirects: true
      preferred_ip_protocol: "ip4"
  http_post_2xx:
    prober: http
    http:
      method: POST
      headers:
        Content-Type: application/json
      body: '{"test": true}'
  tcp_connect:
    prober: tcp
  icmp:
    prober: icmp
EOF
        
        # Create systemd service
        cat > /etc/systemd/system/blackbox_exporter.service << 'EOF'
[Unit]
Description=Blackbox Exporter
After=network.target

[Service]
User=nobody
Group=nobody
Type=simple
ExecStart=/usr/local/bin/blackbox_exporter --config.file=/etc/blackbox_exporter.yml
Restart=always

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl daemon-reload
        systemctl enable blackbox_exporter
        systemctl start blackbox_exporter
        
        green "✓ Blackbox exporter installed"
    fi
    
    # Install process exporter for detailed process monitoring
    if ! systemctl is-active --quiet process_exporter; then
        log "Installing process exporter..."
        
        wget -q https://github.com/ncabatoff/process-exporter/releases/download/v0.7.10/process-exporter-0.7.10.linux-amd64.tar.gz
        tar xzf process-exporter-0.7.10.linux-amd64.tar.gz
        cp process-exporter-0.7.10.linux-amd64/process-exporter /usr/local/bin/
        rm -rf process-exporter-0.7.10.linux-amd64*
        
        # Create configuration
        cat > /etc/process_exporter.yml << 'EOF'
process_names:
  - name: "{{.Comm}}"
    cmdline:
    - '.+'
  - name: "docker"
    cmdline:
    - 'docker'
  - name: "node"
    cmdline:
    - 'node'
EOF
        
        # Create systemd service
        cat > /etc/systemd/system/process_exporter.service << 'EOF'
[Unit]
Description=Process Exporter
After=network.target

[Service]
User=nobody
Group=nobody
Type=simple
ExecStart=/usr/local/bin/process-exporter --config.path=/etc/process_exporter.yml
Restart=always

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl daemon-reload
        systemctl enable process_exporter
        systemctl start process_exporter
        
        green "✓ Process exporter installed"
    fi
}

# Configure Prometheus with enhanced rules
configure_prometheus() {
    log "Configuring Prometheus with enhanced monitoring..."
    
    # Update Prometheus configuration to include new exporters
    cat > "$PROJECT_DIR/prometheus/prometheus_enhanced.yml" << 'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: 'cli-trading'
    environment: 'production'

rule_files:
  - "alert_rules.yml"
  - "alert_rules_enhanced.yml"
  - "recording_rules.yml"

alerting:
  alertmanagers:
    - static_configs:
        - targets:
          - alertmanager:9093

scrape_configs:
  # Trading agents
  - job_name: 'orchestrator'
    static_configs:
      - targets: ['orchestrator:7001']
    scrape_interval: 10s
    metrics_path: /metrics
    
  - job_name: 'portfolio-manager'
    static_configs:
      - targets: ['portfolio-manager:7002']
    scrape_interval: 15s
    
  - job_name: 'market-analyst'
    static_configs:
      - targets: ['market-analyst:7003']
    scrape_interval: 15s
    
  - job_name: 'risk-manager'
    static_configs:
      - targets: ['risk-manager:7004']
    scrape_interval: 10s
    
  - job_name: 'trade-executor'
    static_configs:
      - targets: ['trade-executor:7005']
    scrape_interval: 10s
    
  - job_name: 'notification-manager'
    static_configs:
      - targets: ['notification-manager:7006']
    scrape_interval: 15s
    
  - job_name: 'parameter-optimizer'
    static_configs:
      - targets: ['parameter-optimizer:7007']
    scrape_interval: 30s
    
  - job_name: 'mcp-hub-controller'
    static_configs:
      - targets: ['mcp-hub-controller:7008']
    scrape_interval: 15s

  # Infrastructure
  - job_name: 'redis'
    static_configs:
      - targets: ['redis-exporter:9121']
    scrape_interval: 15s
    
  - job_name: 'postgres'
    static_configs:
      - targets: ['postgres-exporter:9187']
    scrape_interval: 15s
    
  - job_name: 'node'
    static_configs:
      - targets: ['localhost:9100']
    scrape_interval: 15s
    
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
    scrape_interval: 30s
    
  - job_name: 'alertmanager'
    static_configs:
      - targets: ['alertmanager:9093']
    scrape_interval: 30s
    
  - job_name: 'grafana'
    static_configs:
      - targets: ['grafana:3000']
    scrape_interval: 30s

  # Blackbox exporter for endpoint monitoring
  - job_name: 'blackbox-http'
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
        - http://orchestrator:7001/health
        - http://portfolio-manager:7002/health
        - http://market-analyst:7003/health
        - http://risk-manager:7004/health
        - http://trade-executor:7005/health
        - http://notification-manager:7006/health
        - http://parameter-optimizer:7007/health
        - http://mcp-hub-controller:7008/health
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox_exporter:9115

  # Process monitoring
  - job_name: 'process'
    static_configs:
      - targets: ['localhost:9256']
    scrape_interval: 30s

  # Docker monitoring
  - job_name: 'docker'
    static_configs:
      - targets: ['localhost:9323']
    scrape_interval: 15s
EOF
    
    # Create recording rules for performance
    cat > "$PROJECT_DIR/prometheus/recording_rules.yml" << 'EOF'
groups:
  - name: trading_performance
    interval: 30s
    rules:
      # Trading volume rates
      - record: trading:order_rate_5m
        expr: rate(trading_orders_total[5m])
      
      - record: trading:volume_rate_5m
        expr: rate(trading_volume_usd_total[5m])
      
      # Error rates
      - record: trading:error_rate_5m
        expr: rate(trading_errors_total[5m]) / rate(trading_requests_total[5m])
      
      # API latency percentiles
      - record: api:latency_p95_5m
        expr: histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))
      
      - record: api:latency_p99_5m
        expr: histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))
      
      # Resource utilization
      - record: container:memory_usage_pct
        expr: container_memory_usage_bytes / container_spec_memory_limit_bytes * 100
      
      - record: container:cpu_usage_pct
        expr: rate(container_cpu_usage_seconds_total[5m]) * 100

  - name: system_health
    interval: 60s
    rules:
      # System availability
      - record: system:availability_24h
        expr: avg_over_time(up[24h])
      
      # Memory pressure
      - record: system:memory_pressure
        expr: (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes
      
      # Disk usage
      - record: system:disk_usage_pct
        expr: (node_filesystem_size_bytes - node_filesystem_free_bytes) / node_filesystem_size_bytes * 100
EOF
    
    green "✓ Prometheus configuration enhanced"
}

# Configure enhanced Grafana dashboards
configure_grafana() {
    log "Setting up enhanced Grafana dashboards..."
    
    # Create datasource configuration
    mkdir -p "$PROJECT_DIR/grafana/provisioning/datasources"
    cat > "$PROJECT_DIR/grafana/provisioning/datasources/prometheus.yml" << 'EOF'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true
    
  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
    editable: true
EOF

    # Create dashboard provisioning
    mkdir -p "$PROJECT_DIR/grafana/provisioning/dashboards"
    cat > "$PROJECT_DIR/grafana/provisioning/dashboards/default.yml" << 'EOF'
apiVersion: 1

providers:
  - name: 'default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /etc/grafana/dashboards
EOF

    # Create additional specialized dashboards
    create_system_health_dashboard
    create_business_metrics_dashboard
    create_security_dashboard
    
    green "✓ Grafana dashboards configured"
}

# Create system health dashboard
create_system_health_dashboard() {
    cat > "$PROJECT_DIR/grafana/dashboards/system-health.json" << 'EOF'
{
  "dashboard": {
    "id": null,
    "title": "System Health Dashboard",
    "tags": ["system", "health", "infrastructure"],
    "timezone": "browser",
    "refresh": "30s",
    "panels": [
      {
        "id": 1,
        "title": "System Uptime",
        "type": "stat",
        "targets": [
          {
            "expr": "system:availability_24h * 100",
            "legendFormat": "Uptime %"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "unit": "percent",
            "thresholds": {
              "steps": [
                {"color": "red", "value": 0},
                {"color": "yellow", "value": 95},
                {"color": "green", "value": 99}
              ]
            }
          }
        },
        "gridPos": {"h": 4, "w": 6, "x": 0, "y": 0}
      },
      {
        "id": 2,
        "title": "Memory Pressure",
        "type": "gauge",
        "targets": [
          {
            "expr": "system:memory_pressure * 100",
            "legendFormat": "Memory %"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "unit": "percent",
            "min": 0,
            "max": 100,
            "thresholds": {
              "steps": [
                {"color": "green", "value": 0},
                {"color": "yellow", "value": 70},
                {"color": "red", "value": 90}
              ]
            }
          }
        },
        "gridPos": {"h": 8, "w": 6, "x": 6, "y": 0}
      }
    ]
  }
}
EOF
}

# Create business metrics dashboard
create_business_metrics_dashboard() {
    cat > "$PROJECT_DIR/grafana/dashboards/business-metrics.json" << 'EOF'
{
  "dashboard": {
    "id": null,
    "title": "Business Metrics Dashboard",
    "tags": ["business", "trading", "kpi"],
    "timezone": "browser",
    "refresh": "1m",
    "panels": [
      {
        "id": 1,
        "title": "Trading Performance KPIs",
        "type": "table",
        "targets": [
          {
            "expr": "trading:order_rate_5m",
            "legendFormat": "Orders/sec",
            "format": "table"
          },
          {
            "expr": "trading:volume_rate_5m",
            "legendFormat": "Volume $/sec",
            "format": "table"
          },
          {
            "expr": "trading:error_rate_5m * 100",
            "legendFormat": "Error Rate %",
            "format": "table"
          }
        ],
        "gridPos": {"h": 8, "w": 24, "x": 0, "y": 0}
      }
    ]
  }
}
EOF
}

# Create security dashboard
create_security_dashboard() {
    cat > "$PROJECT_DIR/grafana/dashboards/security.json" << 'EOF'
{
  "dashboard": {
    "id": null,
    "title": "Security Dashboard",
    "tags": ["security", "auth", "compliance"],
    "timezone": "browser",
    "refresh": "5m",
    "panels": [
      {
        "id": 1,
        "title": "Authentication Events",
        "type": "timeseries",
        "targets": [
          {
            "expr": "rate(auth_attempts_total[5m])",
            "legendFormat": "Auth Attempts/sec"
          },
          {
            "expr": "rate(auth_failed_attempts_total[5m])",
            "legendFormat": "Failed Attempts/sec"
          }
        ],
        "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0}
      },
      {
        "id": 2,
        "title": "API Security Events",
        "type": "timeseries",
        "targets": [
          {
            "expr": "rate(http_requests_total{code=\"401\"}[5m])",
            "legendFormat": "Unauthorized Requests/sec"
          },
          {
            "expr": "rate(http_requests_total{code=\"403\"}[5m])",
            "legendFormat": "Forbidden Requests/sec"
          }
        ],
        "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0}
      }
    ]
  }
}
EOF
}

# Configure log aggregation
configure_logging() {
    log "Configuring log aggregation..."
    
    # Enhanced Loki configuration
    cat > "$PROJECT_DIR/loki/loki-config-enhanced.yml" << 'EOF'
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096

common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: inmemory

query_range:
  results_cache:
    cache:
      embedded_cache:
        enabled: true
        max_size_mb: 100

schema_config:
  configs:
    - from: 2020-10-24
      store: boltdb-shipper
      object_store: filesystem
      schema: v11
      index:
        prefix: index_
        period: 24h

ruler:
  alertmanager_url: http://alertmanager:9093

analytics:
  reporting_enabled: false
EOF

    # Enhanced Promtail configuration
    cat > "$PROJECT_DIR/promtail/promtail-config-enhanced.yml" << 'EOF'
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
  - job_name: containers
    static_configs:
      - targets:
          - localhost
        labels:
          job: containerlogs
          __path__: /var/lib/docker/containers/*/*log
    pipeline_stages:
      - json:
          expressions:
            output: log
            stream: stream
            attrs:
      - json:
          expressions:
            tag:
          source: attrs
      - regex:
          expression: (?P<container_name>(?:[^|]*))\|
          source: tag
      - timestamp:
          format: RFC3339Nano
          source: time
      - labels:
          stream:
          container_name:
      - output:
          source: output

  - job_name: system
    static_configs:
      - targets:
          - localhost
        labels:
          job: syslog
          __path__: /var/log/syslog
    pipeline_stages:
      - match:
          selector: '{job="syslog"}'
          stages:
            - regex:
                expression: '^(?P<timestamp>\S+\s+\d+\s+\d+:\d+:\d+)\s+(?P<hostname>\S+)\s+(?P<service>\S+):\s+(?P<message>.*)$'
            - labels:
                hostname:
                service:
            - timestamp:
                format: Jan 2 15:04:05
                source: timestamp

  - job_name: trading-apps
    static_configs:
      - targets:
          - localhost
        labels:
          job: trading
          __path__: /opt/cli-trading/logs/*.log
    pipeline_stages:
      - match:
          selector: '{job="trading"}'
          stages:
            - json:
                expressions:
                  level:
                  message:
                  timestamp:
                  service:
                  traceId:
            - labels:
                level:
                service:
                traceId:
            - timestamp:
                format: RFC3339
                source: timestamp
EOF
    
    green "✓ Log aggregation configured"
}

# Configure alert notifications
configure_alerting() {
    if [[ "$CONFIGURE_ALERTS" != "true" ]]; then
        return 0
    fi
    
    log "Configuring enhanced alerting..."
    
    # Create alert notification templates
    mkdir -p "$PROJECT_DIR/alertmanager/templates"
    
    cat > "$PROJECT_DIR/alertmanager/templates/slack.tmpl" << 'EOF'
{{ define "slack.title" }}
{{ if eq .Status "firing" }}🚨{{ else }}✅{{ end }} {{ .GroupLabels.alertname }} - {{ .Status | title }}
{{ end }}

{{ define "slack.text" }}
{{ range .Alerts }}
*Alert:* {{ .Annotations.summary }}
*Description:* {{ .Annotations.description }}
{{ if .Labels.severity }}*Severity:* {{ .Labels.severity }}{{ end }}
{{ if .Labels.service }}*Service:* {{ .Labels.service }}{{ end }}
{{ if .Labels.instance }}*Instance:* {{ .Labels.instance }}{{ end }}
*Started:* {{ .StartsAt.Format "2006-01-02 15:04:05" }}
{{ if .EndsAt }}*Ended:* {{ .EndsAt.Format "2006-01-02 15:04:05" }}{{ end }}
{{ end }}
{{ end }}
EOF

    cat > "$PROJECT_DIR/alertmanager/templates/email.tmpl" << 'EOF'
{{ define "email.subject" }}
{{ if eq .Status "firing" }}[ALERT] {{ else }}[RESOLVED] {{ end }}{{ .GroupLabels.alertname }}
{{ end }}

{{ define "email.html" }}
<html>
<head><title>Alert Notification</title></head>
<body>
<h2>{{ if eq .Status "firing" }}Alert Firing{{ else }}Alert Resolved{{ end }}</h2>
<table border="1" cellpadding="5">
<tr><th>Alert</th><th>Status</th><th>Severity</th><th>Description</th><th>Started</th></tr>
{{ range .Alerts }}
<tr>
<td>{{ .Labels.alertname }}</td>
<td>{{ .Status }}</td>
<td>{{ .Labels.severity }}</td>
<td>{{ .Annotations.description }}</td>
<td>{{ .StartsAt.Format "2006-01-02 15:04:05" }}</td>
</tr>
{{ end }}
</table>
</body>
</html>
{{ end }}
EOF
    
    green "✓ Alert templates configured"
}

# Set up monitoring maintenance tasks
setup_maintenance() {
    log "Setting up monitoring maintenance tasks..."
    
    # Create monitoring maintenance script
    cat > /opt/cli-trading/scripts/monitoring-maintenance.sh << 'EOF'
#!/bin/bash
# Monitoring maintenance script

# Clean up old Prometheus data (keep 30 days)
find /opt/cli-trading/prometheus/data -name "*.tmp" -mtime +1 -delete

# Clean up old Grafana logs
find /var/log/grafana -name "*.log" -mtime +7 -exec gzip {} \;

# Backup monitoring configuration
tar -czf "/opt/cli-trading/backups/monitoring-config-$(date +%Y%m%d).tar.gz" \
    /opt/cli-trading/prometheus/prometheus.yml \
    /opt/cli-trading/grafana/provisioning/ \
    /opt/cli-trading/alertmanager/alertmanager.yml

# Clean up old backups (keep 14 days)
find /opt/cli-trading/backups -name "monitoring-config-*.tar.gz" -mtime +14 -delete

echo "Monitoring maintenance completed at $(date)"
EOF

    chmod +x /opt/cli-trading/scripts/monitoring-maintenance.sh
    
    # Add to crontab
    (crontab -l 2>/dev/null; echo "0 3 * * * /opt/cli-trading/scripts/monitoring-maintenance.sh") | crontab -
    
    green "✓ Monitoring maintenance scheduled"
}

# Validate monitoring setup
validate_monitoring() {
    log "Validating monitoring setup..."
    
    local validation_errors=0
    
    # Check Prometheus
    if ! curl -sf http://localhost:9090/-/healthy >/dev/null; then
        red "✗ Prometheus health check failed"
        ((validation_errors++))
    else
        green "✓ Prometheus is healthy"
    fi
    
    # Check Grafana
    if ! curl -sf http://localhost:3000/api/health >/dev/null; then
        red "✗ Grafana health check failed"
        ((validation_errors++))
    else
        green "✓ Grafana is healthy"
    fi
    
    # Check Alertmanager
    if ! curl -sf http://localhost:9093/-/healthy >/dev/null; then
        red "✗ Alertmanager health check failed"
        ((validation_errors++))
    else
        green "✓ Alertmanager is healthy"
    fi
    
    # Check Loki
    if ! curl -sf http://localhost:3100/ready >/dev/null; then
        yellow "⚠ Loki health check failed (non-critical)"
    else
        green "✓ Loki is healthy"
    fi
    
    if [[ $validation_errors -gt 0 ]]; then
        red "Monitoring validation failed with $validation_errors errors"
        return 1
    else
        green "✓ All monitoring components validated successfully"
        return 0
    fi
}

# Main execution
main() {
    # Create log directory
    mkdir -p "$(dirname "$MONITORING_LOG")"
    
    bold "🎯 Setting up Enhanced Monitoring for CLI-Trading"
    log "Enhanced monitoring setup started"
    
    # Run setup steps
    setup_directories
    install_exporters
    configure_prometheus
    configure_grafana
    configure_logging
    configure_alerting
    setup_maintenance
    
    # Restart monitoring services to apply changes
    log "Restarting monitoring services..."
    docker compose -f "$PROJECT_DIR/docker-compose.yml" restart prometheus grafana alertmanager loki promtail
    
    # Wait for services to start
    sleep 30
    
    # Validate setup
    if validate_monitoring; then
        green "✅ Enhanced monitoring setup completed successfully!"
        echo
        echo "Monitoring URLs:"
        echo "• Prometheus: http://localhost:9090"
        echo "• Grafana: http://localhost:3000"
        echo "• Alertmanager: http://localhost:9093"
        echo "• Loki: http://localhost:3100"
        echo
        echo "Default Grafana credentials: admin/admin (change on first login)"
        echo "Monitoring logs: $MONITORING_LOG"
    else
        red "❌ Monitoring setup completed with errors. Check logs for details."
        exit 1
    fi
}

# Run main function
main