# Runbook: RedisDown

Alert condition: redis_exporter target is down.

Triage

- Confirm redis container status; check logs.
- Check host resources (disk full, OOM).

Diagnosis

- docker compose ps redis; docker compose logs redis
- redis-cli -h redis ping (from another container)

Mitigation

- Restart redis; investigate data volume health.
- If persistent failure, restore from snapshot/AOF per backup runbook.

Verification

- exporter target up; app consumers resume; alert clears.
