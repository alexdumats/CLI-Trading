# Backup and Restore Runbook

This runbook describes how to back up and restore Postgres and Redis for the trading system. Validate these procedures in a non-production environment before relying on them.

Prerequisites

- docker compose access to the environment
- Services healthy (or at least containers available)
- Sufficient disk space for backups

Backup locations

- Postgres backups: `backups/postgres/postgres-YYYYMMDD-HHMMSS.dump`
- Redis backups: `backups/redis/redis-YYYYMMDD-HHMMSS.rdb`

Postgres backup

- Command:

```
./scripts/backup_postgres.sh
```

- What it does:
  - Runs `pg_dump` inside the postgres container and copies the compressed dump to the host backups directory.

Postgres restore

- Warning: Restores are destructive. Perform in maintenance window.
- Steps:
  1. Stop application services that connect to Postgres (orchestrator, etc.) to prevent writes.
  2. Copy the dump back into the container and restore:

```
BACKUP=backups/postgres/postgres-YYYYMMDD-HHMMSS.dump
# Drop and recreate database (optional, if restoring over existing)
docker compose exec -T postgres sh -lc 'psql -U "$POSTGRES_USER" -d postgres -c "select pg_terminate_backend(pid) from pg_stat_activity where datname=\'$POSTGRES_DB\''"'
docker compose exec -T postgres sh -lc 'dropdb -U "$POSTGRES_USER" "$POSTGRES_DB" || true'
docker compose exec -T postgres sh -lc 'createdb -U "$POSTGRES_USER" "$POSTGRES_DB"'
# Copy and restore
docker compose cp "$BACKUP" postgres:/tmp/restore.dump
docker compose exec -T postgres sh -lc 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists /tmp/restore.dump'
docker compose exec -T postgres sh -lc 'rm -f /tmp/restore.dump'
```

3. Start application services and validate.

Redis backup

- Command:

```
./scripts/backup_redis.sh
```

- What it does:
  - Triggers a synchronous SAVE and copies `/data/dump.rdb` to the host backups directory.

Redis restore

- Warning: Restores replace current dataset. Perform in maintenance window.
- Steps:

```
BACKUP=backups/redis/redis-YYYYMMDD-HHMMSS.rdb
# Stop services that depend on Redis
# Stop redis (if needed): docker compose stop redis
# Copy backup to data path and restart
docker compose cp "$BACKUP" redis:/data/dump.rdb
docker compose restart redis
```

Verification

- Postgres: run a smoke query; Orchestrator /health shows db: ok; tests pass
- Redis: agents /health show redis: ok; consumers process streams; pending/DLQ behave as expected

Retention and offsite

- Implement retention (e.g., keep daily 7, weekly 4, monthly 3)
- Optionally sync backups offsite (S3, GCS) via rclone/cron; store credentials as Docker secrets

Automation

- Add cron entries to run backups nightly and prune old backups
- Alert if backups are stale or fail via a small monitoring script that checks timestamps

Security

- Backups may contain sensitive data. Restrict permissions and access; encrypt at rest if needed.
