# Maintenance Procedures

## CLI-Trading Multi-Agent System

### Overview

This runbook covers routine maintenance procedures to ensure optimal performance, security, and reliability of the CLI-Trading system.

---

## Daily Maintenance

### Morning Health Check (15 minutes)

**Schedule:** Every day at 8:00 AM

**Procedure:**

1. **System Health Verification**

   ```bash
   cd /opt/cli-trading
   ./scripts/comprehensive-health-check.sh --verbose
   ```

2. **Trading Performance Review**

   ```bash
   # Check daily PnL
   curl -H "X-Admin-Token: $ADMIN_TOKEN" \
        http://localhost:7001/pnl/status | jq '.'

   # Review overnight trading activity
   curl http://localhost:7001/metrics | grep trading_orders_total
   ```

3. **Resource Utilization Check**

   ```bash
   # System resources
   free -h
   df -h /opt/cli-trading

   # Container resources
   docker stats --no-stream | grep cli-trading
   ```

4. **Security Log Review**

   ```bash
   # Failed authentication attempts
   grep "authentication failure" /var/log/auth.log | tail -10

   # Suspicious API requests
   grep -E "(401|403)" /opt/cli-trading/logs/*.log | tail -20
   ```

5. **Alert Review**
   - Check Grafana alerts dashboard
   - Review Slack #trading-alerts channel
   - Verify all alerts have been acknowledged

**Success Criteria:**

- All health checks pass
- System resources < 80% utilization
- No unacknowledged critical alerts
- Trading system operational

---

## Weekly Maintenance

### System Cleanup (30 minutes)

**Schedule:** Every Sunday at 2:00 AM

**Procedure:**

1. **Log Rotation and Cleanup**

   ```bash
   # Force log rotation
   logrotate -f /etc/logrotate.d/cli-trading

   # Clean old compressed logs (>30 days)
   find /opt/cli-trading/logs -name "*.gz" -mtime +30 -delete

   # Clean Docker logs
   docker system prune -f --filter "until=168h"
   ```

2. **Database Maintenance**

   ```bash
   # PostgreSQL maintenance
   docker exec cli-trading-postgres-1 \
     psql -U trader -d trading -c "VACUUM ANALYZE;"

   docker exec cli-trading-postgres-1 \
     psql -U trader -d trading -c "REINDEX DATABASE trading;"

   # Check database size
   docker exec cli-trading-postgres-1 \
     psql -U trader -d trading -c "SELECT pg_size_pretty(pg_database_size('trading'));"
   ```

3. **Redis Maintenance**

   ```bash
   # Check Redis memory usage
   docker exec cli-trading-redis-1 redis-cli info memory

   # Trigger background save
   docker exec cli-trading-redis-1 redis-cli bgsave

   # Clean expired keys
   docker exec cli-trading-redis-1 redis-cli eval "
     local keys = redis.call('keys', ARGV[1])
     for i=1,#keys,5000 do
       redis.call('del', unpack(keys, i, math.min(i+4999, #keys)))
     end
     return #keys
   " 0 "*expired*"
   ```

4. **Container Image Updates**

   ```bash
   # Pull latest base images
   docker pull node:20-alpine
   docker pull postgres:15-alpine
   docker pull redis:7-alpine
   docker pull grafana/grafana:latest
   docker pull prom/prometheus:latest

   # Check for security updates
   ./scripts/security-audit.sh --report
   ```

5. **Backup Verification**

   ```bash
   # Verify backup integrity
   latest_backup=$(ls -t /opt/cli-trading/backups/secrets-*.tar.gz | head -1)
   tar -tzf "$latest_backup" >/dev/null && echo "Backup integrity OK"

   # Test backup restoration (dry run)
   ./scripts/manage-secrets.sh validate
   ```

---

### Performance Analysis (45 minutes)

**Schedule:** Every Sunday at 3:00 AM

**Procedure:**

1. **Trading Performance Metrics**

   ```bash
   # Generate weekly trading report
   cat > /tmp/weekly_report.sql << 'EOF'
   SELECT
     DATE(created_at) as trade_date,
     COUNT(*) as total_trades,
     SUM(profit_usd) as daily_pnl,
     AVG(execution_time_ms) as avg_execution_time,
     COUNT(*) FILTER (WHERE status = 'filled') as successful_trades,
     COUNT(*) FILTER (WHERE status = 'rejected') as rejected_trades
   FROM trades
   WHERE created_at >= NOW() - INTERVAL '7 days'
   GROUP BY DATE(created_at)
   ORDER BY trade_date;
   EOF

   docker exec cli-trading-postgres-1 \
     psql -U trader -d trading -f /tmp/weekly_report.sql
   ```

2. **System Performance Analysis**

   ```bash
   # API response time analysis
   curl -s http://localhost:9090/api/v1/query?query='histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[7d]))' | \
     jq '.data.result[] | {service: .metric.job, p95_latency: .value[1]}'

   # Error rate analysis
   curl -s http://localhost:9090/api/v1/query?query='rate(http_requests_total{code=~"5.."}[7d]) / rate(http_requests_total[7d])' | \
     jq '.data.result[] | {service: .metric.job, error_rate: .value[1]}'
   ```

3. **Resource Trend Analysis**

   ```bash
   # Memory usage trends
   curl -s http://localhost:9090/api/v1/query?query='avg_over_time(container_memory_usage_bytes[7d])' | \
     jq '.data.result[] | {container: .metric.name, avg_memory_bytes: .value[1]}'

   # CPU usage trends
   curl -s http://localhost:9090/api/v1/query?query='avg_over_time(rate(container_cpu_usage_seconds_total[5m])[7d])' | \
     jq '.data.result[] | {container: .metric.name, avg_cpu_usage: .value[1]}'
   ```

4. **Generate Performance Report**

   ```bash
   # Create weekly performance report
   cat > "/opt/cli-trading/reports/performance-$(date +%Y%m%d).md" << EOF
   # Weekly Performance Report - $(date +%Y-%m-%d)

   ## Trading Metrics
   - Total Trades: [from SQL query]
   - Total PnL: [from SQL query]
   - Success Rate: [calculated from SQL]
   - Average Execution Time: [from SQL query]

   ## System Performance
   - Average API Latency (P95): [from Prometheus]
   - Error Rate: [from Prometheus]
   - Average Memory Usage: [from Prometheus]
   - Average CPU Usage: [from Prometheus]

   ## Alerts Summary
   - Total Alerts: [count from Alertmanager]
   - Critical Alerts: [count]
   - Mean Time to Resolution: [calculated]

   ## Recommendations
   - [Performance optimization recommendations]
   - [Capacity planning recommendations]
   - [Monitoring improvements]
   EOF
   ```

---

## Monthly Maintenance

### Security Review (2 hours)

**Schedule:** First Saturday of each month at 1:00 AM

**Procedure:**

1. **Comprehensive Security Audit**

   ```bash
   ./scripts/security-audit.sh --report --compliance
   ```

2. **Secrets Rotation**

   ```bash
   # Rotate all non-critical secrets
   ./scripts/manage-secrets.sh backup
   ./scripts/manage-secrets.sh rotate --force

   # Restart system with new secrets
   docker-compose down
   docker-compose up -d

   # Verify system health after rotation
   sleep 60
   ./scripts/comprehensive-health-check.sh
   ```

3. **Access Control Review**

   ```bash
   # Review SSH access logs
   grep "Accepted" /var/log/auth.log | \
     awk '{print $1, $2, $3, $9, $11}' | \
     sort | uniq -c | sort -nr

   # Review admin API access
   grep "X-Admin-Token" /opt/cli-trading/logs/*.log | \
     grep -v "200" | tail -50

   # Review OAuth2 access (if configured)
   docker logs cli-trading-oauth2-proxy-1 | \
     grep -E "(denied|error)" | tail -20
   ```

4. **Certificate Management**

   ```bash
   # Check SSL certificate expiration
   echo | openssl s_client -servername $DOMAIN -connect $DOMAIN:443 2>/dev/null | \
     openssl x509 -noout -dates

   # Check Let's Encrypt renewal
   docker exec cli-trading-traefik-1 \
     cat /letsencrypt/acme.json | jq '.le.Certificates[0].Certificate' | \
     base64 -d | openssl x509 -noout -dates
   ```

5. **Compliance Check**

   ```bash
   # Data retention compliance
   find /opt/cli-trading/logs -type f -mtime +90 -ls

   # Backup retention compliance
   find /opt/cli-trading/backups -type f -mtime +365 -ls

   # Generate compliance report
   ./scripts/security-audit.sh --compliance --report
   ```

---

### Capacity Planning (1 hour)

**Schedule:** Last Saturday of each month at 1:00 AM

**Procedure:**

1. **Storage Analysis**

   ```bash
   # Database growth analysis
   docker exec cli-trading-postgres-1 \
     psql -U trader -d trading -c "
     SELECT
       schemaname,
       tablename,
       pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size,
       pg_total_relation_size(schemaname||'.'||tablename) as size_bytes
     FROM pg_tables
     WHERE schemaname = 'public'
     ORDER BY size_bytes DESC;"

   # Log growth analysis
   du -sh /opt/cli-trading/logs/*

   # Backup storage analysis
   du -sh /opt/cli-trading/backups/*

   # System disk usage
   df -h
   ```

2. **Memory Analysis**

   ```bash
   # Container memory trends (30 days)
   curl -s "http://localhost:9090/api/v1/query?query=avg_over_time(container_memory_usage_bytes[30d])" | \
     jq '.data.result[] | {container: .metric.name, avg_memory_gb: (.value[1] | tonumber / 1024 / 1024 / 1024)}'

   # Peak memory usage
   curl -s "http://localhost:9090/api/v1/query?query=max_over_time(container_memory_usage_bytes[30d])" | \
     jq '.data.result[] | {container: .metric.name, peak_memory_gb: (.value[1] | tonumber / 1024 / 1024 / 1024)}'
   ```

3. **Network Analysis**

   ```bash
   # API request volume trends
   curl -s "http://localhost:9090/api/v1/query?query=rate(http_requests_total[30d])" | \
     jq '.data.result[] | {service: .metric.job, requests_per_second: .value[1]}'

   # Data transfer analysis
   curl -s "http://localhost:9090/api/v1/query?query=rate(node_network_transmit_bytes_total[30d])" | \
     jq '.data.result[] | {interface: .metric.device, bytes_per_second: .value[1]}'
   ```

4. **Generate Capacity Report**

   ```bash
   cat > "/opt/cli-trading/reports/capacity-$(date +%Y%m).md" << EOF
   # Monthly Capacity Report - $(date +%Y-%m)

   ## Storage
   - Database Size: [from analysis]
   - Log Storage: [from analysis]
   - Backup Storage: [from analysis]
   - Available Disk: [from df]
   - Projected Growth: [calculated]

   ## Memory
   - Average Usage: [from Prometheus]
   - Peak Usage: [from Prometheus]
   - Available Memory: [from system]
   - Projected Requirements: [calculated]

   ## Network
   - Average Request Rate: [from Prometheus]
   - Peak Request Rate: [calculated]
   - Data Transfer Rate: [from Prometheus]

   ## Recommendations
   - Storage scaling: [if needed]
   - Memory scaling: [if needed]
   - Network optimization: [if needed]
   - Cost optimization: [opportunities]
   EOF
   ```

---

## Quarterly Maintenance

### Infrastructure Review (4 hours)

**Schedule:** First Saturday of January, April, July, October

**Procedure:**

1. **Dependency Updates**

   ```bash
   # Update all npm dependencies
   cd /opt/cli-trading
   npm audit
   npm update

   # Update Docker base images
   docker pull node:20-alpine
   docker pull postgres:15-alpine
   docker pull redis:7-alpine
   docker pull grafana/grafana:latest
   docker pull prom/prometheus:latest
   docker pull prom/alertmanager:latest

   # Rebuild all images
   docker-compose build --no-cache
   ```

2. **Security Updates**

   ```bash
   # System package updates
   apt update
   apt list --upgradable
   apt upgrade -y

   # Reboot if kernel updated
   if [ -f /var/run/reboot-required ]; then
     echo "Reboot required"
     # Schedule reboot during maintenance window
   fi
   ```

3. **Configuration Review**

   ```bash
   # Review and update configurations
   ./scripts/security-audit.sh --fix --report

   # Update monitoring configurations
   ./scripts/setup-monitoring.sh --configure-alerts

   # Review Docker Compose configuration
   docker-compose config
   ```

4. **Disaster Recovery Testing**

   ```bash
   # Test backup restoration
   ./scripts/manage-secrets.sh backup
   ./scripts/backup-system.sh test-restore

   # Test failover procedures
   # (Follow disaster recovery runbook)

   # Verify monitoring alerting
   # (Trigger test alerts)
   ```

---

### Performance Optimization (3 hours)

**Schedule:** Second Saturday of March, June, September, December

**Procedure:**

1. **Database Optimization**

   ```bash
   # Analyze query performance
   docker exec cli-trading-postgres-1 \
     psql -U trader -d trading -c "
     SELECT query, calls, total_time, mean_time, rows
     FROM pg_stat_statements
     ORDER BY mean_time DESC
     LIMIT 20;"

   # Update table statistics
   docker exec cli-trading-postgres-1 \
     psql -U trader -d trading -c "ANALYZE;"

   # Check for missing indexes
   docker exec cli-trading-postgres-1 \
     psql -U trader -d trading -c "
     SELECT schemaname, tablename, seq_scan, seq_tup_read
     FROM pg_stat_user_tables
     WHERE seq_scan > 1000;"
   ```

2. **Application Performance Tuning**

   ```bash
   # Profile Node.js applications
   # (Add profiling to agents if needed)

   # Optimize Docker images
   docker images | grep cli-trading

   # Review container resource limits
   docker stats --no-stream | grep cli-trading
   ```

3. **Infrastructure Optimization**

   ```bash
   # System performance tuning
   sysctl vm.swappiness=10
   echo 'vm.swappiness=10' >> /etc/sysctl.conf

   # Disk optimization
   hdparm -Tt /dev/sda

   # Network optimization
   ss -tuln | grep :70
   ```

---

## Emergency Maintenance

### Planned Maintenance Window

**Procedure:**

1. **Pre-Maintenance Checklist**
   - [ ] Maintenance window scheduled and communicated
   - [ ] All stakeholders notified
   - [ ] Backup completed
   - [ ] Rollback plan prepared
   - [ ] Emergency contacts available

2. **Maintenance Steps**

   ```bash
   # 1. Halt trading system
   curl -X POST -H "X-Admin-Token: $ADMIN_TOKEN" \
        http://localhost:7001/admin/orchestrate/halt \
        -d '{"reason":"scheduled_maintenance"}'

   # 2. Create backup
   ./scripts/backup-system.sh

   # 3. Perform maintenance tasks
   # [Specific maintenance procedures]

   # 4. Restart system
   docker-compose down
   docker-compose up -d

   # 5. Verify system health
   ./scripts/comprehensive-health-check.sh

   # 6. Unhalt trading system
   curl -X POST -H "X-Admin-Token: $ADMIN_TOKEN" \
        http://localhost:7001/admin/orchestrate/unhalt
   ```

3. **Post-Maintenance Verification**
   - [ ] All services healthy
   - [ ] Trading system operational
   - [ ] Monitoring active
   - [ ] Performance metrics normal
   - [ ] Stakeholders notified of completion

---

### Emergency Rollback

**When to Execute:**

- Critical issues discovered during maintenance
- System instability after changes
- Performance degradation

**Procedure:**

```bash
# 1. Immediate halt
curl -X POST -H "X-Admin-Token: $ADMIN_TOKEN" \
     http://localhost:7001/admin/orchestrate/halt \
     -d '{"reason":"emergency_rollback"}'

# 2. Stop all services
docker-compose down

# 3. Restore from backup
./scripts/backup-system.sh restore

# 4. Restore previous Docker images
docker-compose pull
docker-compose up -d

# 5. Verify restoration
./scripts/comprehensive-health-check.sh

# 6. Resume operations if stable
curl -X POST -H "X-Admin-Token: $ADMIN_TOKEN" \
     http://localhost:7001/admin/orchestrate/unhalt
```

---

## Maintenance Schedules

### Automated Maintenance (Cron Jobs)

```bash
# Add to trader user crontab
crontab -e

# Daily health check
0 8 * * * /opt/cli-trading/scripts/comprehensive-health-check.sh --json > /opt/cli-trading/logs/daily-health.log

# Daily backup
0 2 * * * /opt/cli-trading/scripts/backup-system.sh

# Weekly cleanup
0 2 * * 0 /opt/cli-trading/scripts/monitoring-maintenance.sh

# Monthly security audit
0 1 1 * * /opt/cli-trading/scripts/security-audit.sh --report

# Log rotation
0 0 * * * /usr/sbin/logrotate /etc/logrotate.d/cli-trading
```

### Manual Maintenance Calendar

| Frequency | Task                     | Duration | Best Time          |
| --------- | ------------------------ | -------- | ------------------ |
| Daily     | Health Check             | 15 min   | 8:00 AM            |
| Weekly    | System Cleanup           | 30 min   | Sunday 2:00 AM     |
| Weekly    | Performance Analysis     | 45 min   | Sunday 3:00 AM     |
| Monthly   | Security Review          | 2 hours  | 1st Sat 1:00 AM    |
| Monthly   | Capacity Planning        | 1 hour   | Last Sat 1:00 AM   |
| Quarterly | Infrastructure Review    | 4 hours  | 1st Sat of quarter |
| Quarterly | Performance Optimization | 3 hours  | 2nd Sat of quarter |

---

## Maintenance Documentation

### Change Log Template

```markdown
## Maintenance Change Log

### [Date] - [Type] Maintenance

**Performed by:** [Name]
**Duration:** [Start] - [End]
**Planned Downtime:** [Yes/No]

**Changes Made:**

- [List of changes]

**Issues Encountered:**

- [Any issues and resolutions]

**Validation:**

- [ ] Health checks passed
- [ ] Performance metrics normal
- [ ] No alerts triggered

**Next Steps:**

- [Any follow-up actions needed]
```

### Maintenance Checklist

**Pre-Maintenance:**

- [ ] Maintenance window scheduled
- [ ] Stakeholders notified
- [ ] Backup completed
- [ ] Emergency contacts confirmed
- [ ] Rollback plan ready

**During Maintenance:**

- [ ] Change log updated
- [ ] Each step documented
- [ ] Issues tracked
- [ ] Timeline recorded

**Post-Maintenance:**

- [ ] System validation completed
- [ ] Performance verified
- [ ] Monitoring confirmed
- [ ] Stakeholders notified
- [ ] Documentation updated
