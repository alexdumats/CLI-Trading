# Runbook: RedisHighMemory

Alert condition: Memory usage > 85% for 10m.

Triage

- Verify key count, top keys, eviction policy, memory fragmentation.

Diagnosis

- redis-cli INFO memory
- redis-cli CONFIG GET maxmemory
- redis-cli MEMORY STATS

Mitigation

- Increase maxmemory or move to larger instance.
- Adjust eviction policy; reduce key retention; partition streams.
- Consider managed Redis for scaling.

Verification

- Memory usage below threshold; alert clears.
