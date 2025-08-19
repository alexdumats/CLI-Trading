# Runbook: PostgresExporterDown

Alert condition: postgres_exporter target is down.

Triage

- Check container health and logs.

Diagnosis

- docker compose ps postgres-exporter; docker compose logs postgres-exporter
- Validate DATA_SOURCE_NAME and secret mounted; check connectivity to Postgres.

Mitigation

- Restart exporter; fix credentials; ensure postgres is healthy first.

Verification

- Target up; metrics flowing; alert clears.
