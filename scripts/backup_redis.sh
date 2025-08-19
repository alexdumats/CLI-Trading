#!/usr/bin/env bash
set -euo pipefail

# Backup Redis RDB snapshot by triggering SAVE and copying dump.rdb to ./backups/redis
# Works if Redis persistence is enabled (appendonly or RDB). Adjust if using AOF-only.

TS="$(date -u +%Y%m%d-%H%M%S)"
OUT_DIR="backups/redis"
OUT_FILE="$OUT_DIR/redis-$TS.rdb"

mkdir -p "$OUT_DIR"

echo "[backup_redis] Triggering SAVE..."
docker compose exec -T redis sh -lc 'redis-cli SAVE'

echo "[backup_redis] Copying snapshot to $OUT_FILE ..."
docker compose cp redis:/data/dump.rdb "$OUT_FILE"

echo "[backup_redis] Done: $OUT_FILE"
