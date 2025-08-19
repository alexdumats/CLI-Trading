# Runbook: PostgresHighConnections

Alert condition: connections > 80% of max for 10m.

Triage

- Identify connection sources (application vs. psql/BI).

Diagnosis

- SELECT datname, count(\*) FROM pg_stat_activity GROUP BY 1 ORDER BY 2 DESC;
- Check idle in transaction sessions.

Mitigation

- Add connection pooling (PgBouncer), increase max_connections prudently, fix leaks.

Verification

- Connections drop below threshold; alert clears.
