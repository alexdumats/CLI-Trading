# Runbook: RedisEvictions

Alert condition: redis_evicted_keys_total increases.

Triage

- Identify cause of memory pressure.

Diagnosis

- redis-cli INFO stats | grep evicted
- Check maxmemory setting and key TTLs.

Mitigation

- Increase memory / reduce memory use; set appropriate TTLs; change eviction policy.

Verification

- No new evictions; alert clears.
