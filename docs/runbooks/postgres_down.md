# Runbook: PostgresDown

Alert condition: pg_up == 0.

Triage

- Check postgres container status and logs; check disk space.

Diagnosis

- docker compose ps postgres; docker compose logs postgres
- psql -h postgres -U $POSTGRES_USER -d $POSTGRES_DB -c 'select 1'

Mitigation

- Restart postgres; if data corruption suspected, follow backup/restore runbook.

Verification

- pg_up=1; application errors subside; alert clears.
