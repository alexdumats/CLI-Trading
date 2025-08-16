# Next Session Handover

This document captures the current state and the immediate backlog so we can resume smoothly in a new session.

## Checkpoint Instructions

Recommended to commit and tag this state:

```
git add -A
git commit -m "MVP hardened: Streams+DLQ+idempotency, OAuth+MTLS, secrets, dashboards/alerts, CLI, tests"
git tag -a ops-mvp-checkpoint -m "Ops MVP checkpoint before exporters/backups"
git push origin HEAD --tags
```

## Minimal Rehydration

Open these files first after restarting IDE or AI session:
- docker-compose.yml
- .env.example (not your real .env)
- README.md
- .agent.md
- docs/vscode_restart_checklist.md
- agents/orchestrator/src/index.js
- prometheus/prometheus.yml

Environment summary required:
- OS + Docker + Compose versions
- Node 20 runtime
- If running locally: run `npm ci`, then `docker compose build && docker compose up -d`, then `docker compose run --rm tests`.

Secrets present as Docker secrets (not committed):
- secrets/admin_token
- secrets/postgres_password
- secrets/slack_bot_token (optional)
- secrets/slack_signing_secret (optional)
- secrets/oauth2_client_id
- secrets/oauth2_client_secret
- secrets/oauth2_cookie_secret
- (For mTLS CA) secrets/mtls_ca/ca.pem (mounted via docker-compose.override.yml)

## Current Status (Implemented)

- 8 agents (Node 20/Express) with `/health` and `/metrics`
- Redis Streams with idempotency, DLQ, and pending metrics (Prometheus gauge)
- Orchestrator: HTTP or Streams pipelines; PnL tracker with 1% daily halt; audits persisted to Postgres
- Postgres migrations and DB helpers (audit_events, pnl_days)
- Admin endpoints: streams pending/DLQ/requeue, manual halt/unhalt, notification ack
- Notification Manager: Slack webhook (per severity), Block Kit formatting, streams consumer with idempotency + DLQ, ack state persisted in Redis
- Ingress security: Traefik with TLS (Let’s Encrypt), OAuth2 (oauth2-proxy forward-auth) for Orchestrator, mTLS enforced for `/admin/*` routes, rate limiting
- Container hardening: non-root UID 1001, read-only FS, cap_drop ALL, no-new-privileges, tmpfs for /tmp and /run
- Secrets handled via Docker secrets throughout; oauth2-proxy loads secrets via init script
- Observability: Prometheus + Grafana + Alertmanager (Slack); Ops dashboard provisioned
- CI: integration tests for 1% PnL halt, Streams pending & DLQ requeue; failing Slack URL injected to drive DLQ path in CI
- Ops CLI: `scripts/ops_cli.js` for streams, DLQ, notify, and orchestrator actions

## Immediate Backlog (To Do Next)

1) Exporters & Dashboards
- Add postgres_exporter (with readonly user) and redis_exporter
- Extend Prometheus scrape configs
- Add Grafana panels for DB/Redis health and performance
- Add alert rules for DB down, replication (future), connection saturation, Redis memory/ops

2) Nightly Backups & Runbooks
- Postgres: nightly `pg_dump` into a backups volume with retention; alert on stale backups
- Redis: nightly RDB snapshot copy (and/or AOF); retention and alerts
- Optional: offsite upload (S3) via awscli/rclone and secrets
- docs/backup_restore_runbook.md with restore steps and verification

3) Optional near-term
- Extend OAuth to Prometheus/Grafana (in addition to basic auth + IP allowlists)
- Log shipping (Loki/ELK/Datadog) for structured JSON logs with traceId/requestId correlation
- More integration tests: consumer restarts, duplicate deliveries, forced DLQ

## Quick Commands

- Bring up stack:
```
docker compose build
docker compose up -d
```

- Run tests:
```
docker compose run --rm tests
```

- Ops CLI (examples):
```
node scripts/ops_cli.js streams:pending --stream notify.events --group notify
node scripts/ops_cli.js streams:dlq:list --stream notify.events.dlq
node scripts/ops_cli.js streams:dlq:requeue --stream notify.events.dlq --id <id>
node scripts/ops_cli.js notify:ack --traceId <id>
node scripts/ops_cli.js orch:halt --reason maintenance
```

## Notes for AI Assistants

- Follow .agent.md and ai_guidelines.md
- Always propose a plan and show diffs; avoid bulk rewrites
- After edits, run format check, compose build/up, and validate `/health` endpoints
- Be explicit when changing anything security-sensitive, migrations, or message bus/Streams
