#!/usr/bin/env bash
set -euo pipefail

# Backup Postgres using pg_dump from inside the container and copy to ./backups/postgres
# Requires docker compose and a healthy 'postgres' service.

TS="$(date -u +%Y%m%d-%H%M%S)"
OUT_DIR="backups/postgres"
OUT_FILE="$OUT_DIR/postgres-$TS.dump"

mkdir -p "$OUT_DIR"

# Create dump inside container under /tmp, then copy to host
echo "[backup_postgres] Creating pg_dump inside container..."
docker compose exec -T postgres sh -lc 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -F c -f /tmp/backup.dump'

echo "[backup_postgres] Copying dump to $OUT_FILE ..."
docker compose cp postgres:/tmp/backup.dump "$OUT_FILE"

echo "[backup_postgres] Cleaning up container tmp file..."
docker compose exec -T postgres sh -lc 'rm -f /tmp/backup.dump || true'

echo "[backup_postgres] Done: $OUT_FILE"
