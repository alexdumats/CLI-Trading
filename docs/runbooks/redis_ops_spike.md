# Runbook: RedisOpsSpike

Alert condition: Redis ops/sec unusually high.

Triage

- Check for deploys, batch jobs, or traffic spikes.

Diagnosis

- redis-cli INFO commandstats
- Review app logs and stream producers.

Mitigation

- Scale Redis, shard traffic, or throttle producers.
- Optimize hot commands; add caching hierarchies.

Verification

- Ops/sec returns to baseline; alert clears.
