# Runbook: HighStreamPending

Alert condition: sum(stream_pending_count) > threshold for sustained period.

Triage

- Check dashboard: Ops Streams panels; identify stream/group with highest pending.
- Review DLQ size via ops CLI.

Diagnosis

- node scripts/ops_cli.js streams:pending --stream <name> --group <group>
- node scripts/ops_cli.js streams:dlq:list --stream <stream>.dlq
- Inspect consumer logs for errors and idempotency hits.

Mitigation

- Requeue DLQ entries cautiously: node scripts/ops_cli.js streams:dlq:requeue --stream <stream>.dlq --id <id>
- Scale consumer replicas (docker compose up -d --scale <service>=N) if handler is slow.
- Fix handler errors; redeploy.

Verification

- Pending drops to normal; DLQ stable.
- Alert resolves.
