# Incident Response Runbook

## CLI-Trading Multi-Agent System

### Overview

This runbook provides step-by-step procedures for responding to incidents in the CLI-Trading system. Follow these procedures to ensure rapid resolution and minimize business impact.

### Incident Classification

#### Severity Levels

**P0 - Critical (Business Impact: High)**

- Trading system halted
- Complete system outage
- Security breach
- Data corruption
- **Response Time: Immediate (< 5 minutes)**

**P1 - High (Business Impact: Medium)**

- Single agent failure affecting trading
- Database connectivity issues
- High error rates (>10%)
- **Response Time: < 15 minutes**

**P2 - Medium (Business Impact: Low)**

- Performance degradation
- Non-critical service failures
- Monitoring alerts
- **Response Time: < 1 hour**

**P3 - Low (Business Impact: None)**

- Warning alerts
- Documentation updates needed
- **Response Time: < 4 hours**

---

## P0 Critical Incidents

### Trading System Halted

**Symptoms:**

- `trading_system_halted` metric = 1
- No new orders being executed
- PnL stopped updating

**Immediate Actions:**

1. **Check halt reason** (< 2 minutes)

   ```bash
   curl -H "X-Admin-Token: $ADMIN_TOKEN" \
        http://localhost:7001/pnl/status | jq '.haltReason'
   ```

2. **Verify system health** (< 3 minutes)

   ```bash
   ./scripts/comprehensive-health-check.sh --json
   ```

3. **Check recent alerts**
   - Review Grafana alerts dashboard
   - Check Slack #trading-critical channel
   - Review orchestrator logs:
     ```bash
     docker logs cli-trading-orchestrator-1 --tail 100
     ```

**Diagnosis Steps:**

**If halt reason is "daily_target_reached":**

- ✅ This is normal operation
- Verify PnL against daily target
- No action required unless target is incorrect

**If halt reason is "daily_loss_limit":**

- 🔥 **Critical financial risk**
- Analyze trading activity leading to losses
- Review risk manager logs for rejected trades
- Check for market anomalies

**If halt reason is "manual" or "system_error":**

- Check orchestrator health endpoint
- Verify database connectivity
- Check Redis stream status

**Resolution Steps:**

1. **Fix underlying issue** (varies by root cause)
2. **Unhalt system** (only after issue resolution):
   ```bash
   curl -X POST -H "X-Admin-Token: $ADMIN_TOKEN" \
        http://localhost:7001/admin/orchestrate/unhalt
   ```
3. **Monitor system** for 15 minutes post-unhalt
4. **Document incident** in post-mortem template

---

### Complete System Outage

**Symptoms:**

- All health checks failing
- No response from any services
- Grafana/Prometheus unreachable

**Immediate Actions:**

1. **Check Docker services** (< 1 minute)

   ```bash
   docker ps --filter "name=cli-trading"
   ```

2. **Check system resources** (< 1 minute)

   ```bash
   free -h
   df -h
   top -n 1
   ```

3. **Check logs** (< 2 minutes)
   ```bash
   journalctl -u docker --since "5 minutes ago"
   ```

**Recovery Procedures:**

**If containers are down:**

```bash
# Restart all services
cd /opt/cli-trading
docker-compose down
docker-compose up -d

# Monitor startup
./scripts/comprehensive-health-check.sh --continuous
```

**If system resources exhausted:**

```bash
# Free memory
sync && echo 3 > /proc/sys/vm/drop_caches

# Check for runaway processes
ps aux --sort=-%mem | head -10

# Restart if necessary
systemctl reboot
```

**If database corruption:**

```bash
# Restore from latest backup
cd /opt/cli-trading
./scripts/backup-system.sh restore
```

---

### Security Breach

**Symptoms:**

- Unauthorized access alerts
- Suspicious API requests
- Failed authentication spikes
- Data exfiltration indicators

**Immediate Actions:**

1. **Isolate system** (< 1 minute)

   ```bash
   # Halt trading immediately
   curl -X POST -H "X-Admin-Token: $ADMIN_TOKEN" \
        http://localhost:7001/admin/orchestrate/halt \
        -d '{"reason":"security_incident"}'

   # Block external access
   ufw deny in
   ```

2. **Preserve evidence** (< 5 minutes)

   ```bash
   # Capture system state
   ./scripts/security-audit.sh --report

   # Copy logs
   cp -r /opt/cli-trading/logs /tmp/incident-$(date +%s)

   # Network connections
   netstat -tulpn > /tmp/netstat-$(date +%s).txt
   ```

3. **Notify security team**
   - Send alert to #security-immediate Slack channel
   - Email security@company.com
   - Page security on-call if available

**Investigation Steps:**

1. **Check access logs**

   ```bash
   grep -E "(401|403|429)" /var/log/nginx/access.log | tail -100
   journalctl -u ssh --since "1 hour ago"
   ```

2. **Review admin access**

   ```bash
   grep "X-Admin-Token" /opt/cli-trading/logs/*.log
   ```

3. **Check for data exfiltration**

   ```bash
   # Large outbound transfers
   iftop -t -s 60

   # Database access patterns
   docker exec cli-trading-postgres-1 \
     psql -U trader -c "SELECT * FROM pg_stat_activity;"
   ```

**Containment:**

- Change all secrets: `./scripts/manage-secrets.sh rotate --force`
- Reset OAuth2 credentials
- Regenerate TLS certificates
- Update firewall rules

---

## P1 High Priority Incidents

### Single Agent Failure

**Symptoms:**

- One agent health check failing
- Container restart loops
- Specific agent errors in logs

**Diagnosis:**

1. **Check container status**

   ```bash
   docker ps -a | grep cli-trading-[AGENT]
   docker logs cli-trading-[AGENT]-1 --tail 50
   ```

2. **Check resource usage**

   ```bash
   docker stats cli-trading-[AGENT]-1 --no-stream
   ```

3. **Check dependencies**

   ```bash
   # Redis connectivity
   docker exec cli-trading-[AGENT]-1 nc -z redis 6379

   # Postgres connectivity (if applicable)
   docker exec cli-trading-[AGENT]-1 nc -z postgres 5432
   ```

**Resolution:**

1. **Restart agent**

   ```bash
   docker-compose restart [AGENT]
   ```

2. **If restart fails, check logs and rebuild**

   ```bash
   docker-compose logs [AGENT]
   docker-compose build [AGENT]
   docker-compose up -d [AGENT]
   ```

3. **Verify recovery**
   ```bash
   curl http://localhost:[PORT]/health
   ```

---

### Database Connectivity Issues

**Symptoms:**

- Database health checks failing
- Connection timeout errors
- PostgreSQL/Redis unavailable

**PostgreSQL Issues:**

```bash
# Check PostgreSQL status
docker exec cli-trading-postgres-1 pg_isready -U trader

# Check connections
docker exec cli-trading-postgres-1 \
  psql -U trader -c "SELECT count(*) FROM pg_stat_activity;"

# Check locks
docker exec cli-trading-postgres-1 \
  psql -U trader -c "SELECT * FROM pg_locks WHERE NOT granted;"

# Restart if needed
docker-compose restart postgres
```

**Redis Issues:**

```bash
# Check Redis status
docker exec cli-trading-redis-1 redis-cli ping

# Check memory usage
docker exec cli-trading-redis-1 redis-cli info memory

# Check connected clients
docker exec cli-trading-redis-1 redis-cli info clients

# Clear cache if needed (CAUTION: Data loss)
docker exec cli-trading-redis-1 redis-cli flushall

# Restart if needed
docker-compose restart redis
```

---

## P2 Medium Priority Incidents

### Performance Degradation

**Symptoms:**

- High response times (>5 seconds)
- Increased error rates
- Resource exhaustion warnings

**Investigation:**

1. **Check system metrics**

   ```bash
   # CPU usage
   top -n 1 | head -20

   # Memory usage
   free -h

   # Disk I/O
   iostat -x 1 5

   # Network
   iftop -t -s 10
   ```

2. **Check application metrics**

   ```bash
   curl http://localhost:9090/api/v1/query?query=api:latency_p95_5m
   curl http://localhost:9090/api/v1/query?query=trading:error_rate_5m
   ```

3. **Check database performance**

   ```bash
   # PostgreSQL slow queries
   docker exec cli-trading-postgres-1 \
     psql -U trader -c "SELECT query, mean_time, calls FROM pg_stat_statements ORDER BY mean_time DESC LIMIT 10;"

   # Redis latency
   docker exec cli-trading-redis-1 redis-cli --latency -i 1
   ```

**Resolution:**

1. **Scale resources if needed**

   ```bash
   # Increase container limits in docker-compose.yml
   # Restart with new limits
   docker-compose up -d
   ```

2. **Optimize database**

   ```bash
   # PostgreSQL vacuum
   docker exec cli-trading-postgres-1 \
     psql -U trader -c "VACUUM ANALYZE;"
   ```

3. **Clear caches**
   ```bash
   # System cache
   sync && echo 3 > /proc/sys/vm/drop_caches
   ```

---

### Stream Processing Issues

**Symptoms:**

- High pending message counts
- DLQ accumulation
- Stream processing delays

**Investigation:**

```bash
# Check stream status
curl -H "X-Admin-Token: $ADMIN_TOKEN" \
     "http://localhost:7001/admin/streams/pending?stream=notify.events&group=notify"

# Check DLQ
curl -H "X-Admin-Token: $ADMIN_TOKEN" \
     "http://localhost:7001/admin/streams/dlq?stream=notify.events.dlq"

# Check Redis streams directly
docker exec cli-trading-redis-1 redis-cli xinfo stream orchestrator.commands
```

**Resolution:**

1. **Process DLQ messages**

   ```bash
   # List DLQ entries
   curl -H "X-Admin-Token: $ADMIN_TOKEN" \
        "http://localhost:7001/admin/streams/dlq?stream=notify.events.dlq"

   # Requeue specific message
   curl -X POST -H "X-Admin-Token: $ADMIN_TOKEN" \
        "http://localhost:7001/admin/streams/dlq/requeue" \
        -d '{"dlqStream":"notify.events.dlq","id":"[MESSAGE_ID]"}'
   ```

2. **Scale consumers if needed**
   ```bash
   # Add more consumer instances
   docker-compose up -d --scale notification-manager=2
   ```

---

## Communication Procedures

### Incident Communication Template

**Initial Alert (within 5 minutes):**

```
🚨 INCIDENT ALERT 🚨
Severity: [P0/P1/P2/P3]
Service: CLI-Trading
Issue: [Brief description]
Impact: [Business impact]
Status: INVESTIGATING
ETA: [Next update time]
Contact: [Incident commander]
```

**Status Updates (every 15-30 minutes):**

```
📊 INCIDENT UPDATE 📊
Incident: [ID/Title]
Status: [INVESTIGATING/MITIGATING/RESOLVED]
Progress: [What has been done]
Next Steps: [What will be done next]
ETA: [Expected resolution or next update]
```

**Resolution Notice:**

```
✅ INCIDENT RESOLVED ✅
Incident: [ID/Title]
Duration: [Start time - End time]
Root Cause: [Brief explanation]
Resolution: [What was done]
Post-mortem: [When it will be completed]
```

### Escalation Matrix

| Severity | Primary Contact   | Secondary Contact   | Management          |
| -------- | ----------------- | ------------------- | ------------------- |
| P0       | On-call Engineer  | Engineering Manager | CTO                 |
| P1       | On-call Engineer  | Team Lead           | Engineering Manager |
| P2       | Assigned Engineer | Team Lead           | -                   |
| P3       | Assigned Engineer | -                   | -                   |

### Contact Information

**Slack Channels:**

- `#trading-critical` - P0/P1 incidents
- `#trading-alerts` - P2/P3 incidents
- `#ops-team` - Infrastructure issues
- `#security-immediate` - Security incidents

**Email Groups:**

- `trading-oncall@company.com`
- `security@company.com`
- `engineering-mgmt@company.com`

**External Services:**

- PagerDuty: [Integration key]
- AWS Support: [Case portal]
- Exchange Support: [Contact details]

---

## Post-Incident Procedures

### Post-Mortem Template

1. **Incident Summary**
   - Date/Time
   - Duration
   - Services affected
   - Business impact

2. **Timeline**
   - Detection time
   - Response time
   - Mitigation time
   - Resolution time

3. **Root Cause Analysis**
   - Primary cause
   - Contributing factors
   - Why detection was delayed (if applicable)

4. **Action Items**
   - Immediate fixes
   - Long-term improvements
   - Monitoring enhancements
   - Documentation updates

5. **Lessons Learned**
   - What went well
   - What could be improved
   - Process changes needed

### Recovery Validation Checklist

After any incident resolution:

- [ ] All health checks passing
- [ ] Trading system operational
- [ ] All agents responding
- [ ] Database connectivity verified
- [ ] Stream processing normal
- [ ] Monitoring alerts cleared
- [ ] Performance metrics normal
- [ ] Security posture verified
- [ ] Backup systems operational
- [ ] Documentation updated

---

## Useful Commands Reference

### Quick Health Check

```bash
./scripts/comprehensive-health-check.sh
```

### View All Logs

```bash
docker-compose logs -f --tail=100
```

### Emergency Stop

```bash
curl -X POST -H "X-Admin-Token: $ADMIN_TOKEN" \
     http://localhost:7001/admin/orchestrate/halt \
     -d '{"reason":"emergency_stop"}'
```

### System Status

```bash
docker-compose ps
docker stats --no-stream
```

### Database Access

```bash
# PostgreSQL
docker exec -it cli-trading-postgres-1 \
  psql -U trader -d trading

# Redis
docker exec -it cli-trading-redis-1 redis-cli
```
