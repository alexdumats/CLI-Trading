# Runbook: PostgresLowCacheHit

Alert condition: cache hit ratio < 90% for 15m.

Triage

- Check working set vs. shared_buffers; look for large sequential scans.

Diagnosis

- pg_stat_statements: top queries by shared_blks_read vs. hit.
- EXPLAIN ANALYZE heavy queries; check indexes.

Mitigation

- Add indexes, tune shared_buffers and effective_cache_size, rewrite queries.

Verification

- Cache hit ratio improves; alert clears.
