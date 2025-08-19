# Claude Multi-Agent Trading System (Scaffold)

Primary setup & architecture guide: [docs/system_spec_and_setup.md](docs/system_spec_and_setup.md)

Integrations: [docs/integrations.md](docs/integrations.md)

Exchange adapters: [docs/exchanges.md](docs/exchanges.md)

This repository contains a scaffold for an 8-agent, role-based automated trading system designed for deployment on a Hetzner Ubuntu server using Docker Compose. Each agent runs as an isolated service with well-defined APIs, health and metrics endpoints, and Redis-backed inter-agent messaging.

Agents:

- Claude Orchestrator
- Claude Portfolio Manager
- Claude Market Analyst
- Claude Risk Manager
- Claude Trade Executor
- Claude Notification Manager
- Claude Parameter Optimizer
- Claude MCP Hub Controller

Key features (scaffold):

- Node.js Express services with `/health` and `/metrics` (Prometheus) endpoints
- REST endpoints stubbed per agent (OpenAPI specs included under `openapi/`)
- Dockerfiles per agent for production build
- docker-compose with Redis, Prometheus, and Grafana
- .env.example for environment configuration

Next steps:

1. Start with the primary guide: [docs/system_spec_and_setup.md](docs/system_spec_and_setup.md)
2. Copy `.env.example` to `.env`, create Docker secrets under `./secrets/` (see the guide), and review `docker-compose.yml`.
3. Build and start: `docker compose build && docker compose up -d`.
4. Verify `/health` and `/metrics` for all agents; access Grafana and Prometheus as described in the guide.
5. Run integration tests: `docker compose run --rm tests`.

Monitoring:

- Prometheus is configured to scrape all agent metrics on their exposed ports.
- Grafana is pre-provisioned to connect to Prometheus; you can log in and import dashboards.

Security:

- In production, run behind a reverse proxy and restrict Grafana/Prometheus access to trusted IPs or VPN.

Secrets setup (Docker secrets):

- Create the following files (do not commit them):
  - secrets/admin_token: admin token used by Orchestrator/Notification Manager admin endpoints
  - secrets/postgres_password: Postgres password (used by DB and Orchestrator)
  - secrets/slack_bot_token: Slack bot token for slack-mcp-server (optional)
  - secrets/slack_signing_secret: Slack signing secret for slack-mcp-server (optional)
  - secrets/oauth2_client_id: OAuth client ID for oauth2-proxy (recommended)
  - secrets/oauth2_client_secret: OAuth client secret for oauth2-proxy (recommended)
  - secrets/oauth2_cookie_secret: OAuth cookie secret (32-byte base64) for oauth2-proxy (recommended)

Example:

```
mkdir -p secrets
openssl rand -base64 32 > secrets/oauth2_cookie_secret
printf 'your-admin-token' > secrets/admin_token
printf 'your-postgres-password' > secrets/postgres_password
printf 'xoxb-...' > secrets/slack_bot_token
printf 'your-signing-secret' > secrets/slack_signing_secret
printf 'github-client-id' > secrets/oauth2_client_id
printf 'github-client-secret' > secrets/oauth2_client_secret
```

- For mTLS on admin routes: follow docs/mtls_runbook.md to create a CA and operator client certs, then mount the CA to Traefik via docker-compose.override.yml.

## Admin cheatsheet

Auth

- All `/admin/*` endpoints require `X-Admin-Token`.
- In production, `/admin/*` is also protected by OAuth2 (oauth2-proxy) and mTLS via Traefik. See `docs/mtls_runbook.md`.

Base URLs (compose)

- Orchestrator: http://orchestrator:7001
- Notification Manager: http://notification-manager:7006

Quick curl

```bash
# Halt orchestration
curl -s -X POST "$ORCH_URL/admin/orchestrate/halt" \
  -H "X-Admin-Token: $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"reason":"maintenance"}'

# Unhalt
curl -s -X POST "$ORCH_URL/admin/orchestrate/unhalt" \
  -H "X-Admin-Token: $ADMIN_TOKEN"

# Streams: pending count
curl -s "$ORCH_URL/admin/streams/pending?stream=notify.events&group=notify" \
  -H "X-Admin-Token: $ADMIN_TOKEN"

# Streams: DLQ list and requeue
curl -s "$ORCH_URL/admin/streams/dlq?stream=notify.events.dlq" \
  -H "X-Admin-Token: $ADMIN_TOKEN"

curl -s -X POST "$ORCH_URL/admin/streams/dlq/requeue" \
  -H "X-Admin-Token: $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"dlqStream":"notify.events.dlq","id":"<id>"}'

# Notification: acknowledge an event

# Optimizer: view deployed params
curl -s "$OPT_URL/optimize/params" | jq .
curl -s -X POST "$NOTIF_URL/admin/notify/ack" \
  -H "X-Admin-Token: $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"traceId":"<id>"}'
```

Ops CLI

```bash
# Set env locally if different
# ORCH_URL=http://localhost:7001 NOTIF_URL=http://localhost:7006 ADMIN_TOKEN=...

node scripts/ops_cli.js orch:halt --reason maintenance
node scripts/ops_cli.js orch:unhalt
node scripts/ops_cli.js streams:pending --stream notify.events --group notify
node scripts/ops_cli.js streams:dlq:list --stream notify.events.dlq
node scripts/ops_cli.js streams:dlq:requeue --stream notify.events.dlq --id <id>
node scripts/ops_cli.js notify:ack --traceId <id>
```

## Local development

Makefile shortcuts

- make up | make down | make downv | make build | make rebuild
- make logs SERVICE=<name> | make recreate SERVICE=<name>
- make tests | make psql | make redis CMD="PING"

Local health check

- Run `make health` to ping /health across all agents (requires docker-compose.override.yml to expose ports to localhost).
- Alternatively, curl specific endpoints, e.g. `curl -s http://localhost:7001/health | jq .`

For local testing, use docker-compose.override.yml to expose service ports to localhost. Do not use this override in production.

Quick start

- cp .env.example .env
- mkdir -p secrets; printf 'changeme' > secrets/admin_token; printf 'postgrespass' > secrets/postgres_password
- docker compose build && docker compose up -d
- Open Grafana at http://localhost:3000 (admin/admin by default, see .env.example)
- Health checks: http://localhost:7001/health (orchestrator), http://localhost:7004/health (risk)
- Run tests: docker compose run --rm tests

Exposed ports (override)

- Orchestrator 7001, Market Analyst 7002, Portfolio Manager 7003, Risk Manager 7004, Trade Executor 7005, Notification Manager 7006, Parameter Optimizer 7007, MCP Hub Controller 7008, Integrations Broker 7010, Redis 6379, Postgres 5432, Prometheus 9090, Grafana 3000, Alertmanager 9093, Loki 3100, oauth2-proxy 4180

Note: Keep admin endpoints protected even locally. Admin routes require X-Admin-Token and can be additionally protected with oauth2-proxy if desired.

## Troubleshooting

Quick commands

- Redis keys: docker compose exec redis redis-cli KEYS '\*'
- Redis flush (dev only): docker compose exec redis redis-cli FLUSHALL
- Postgres shell: docker compose exec -e PGPASSWORD=$(cat secrets/postgres_password) postgres psql -U ${POSTGRES_USER:-trader} -d ${POSTGRES_DB:-trading}
- Health check: run `make health` (requires docker-compose.override.yml to expose ports), or curl: curl -s http://localhost:7001/health | jq .
- Tail logs: docker compose logs -f orchestrator
- Re-create a service: docker compose up -d --force-recreate orchestrator

Common checks

- docker compose config — validates YAML and env interpolation
- docker compose ps — service status and health
- docker compose logs -f <service> — live logs
- curl http://localhost:<port>/health — check liveness
- docker compose run --rm tests — run integration tests

Frequent issues and fixes

- compose config FAILED: undefined volume (e.g., loki-data, pg-data)
  - Define it under the top-level volumes: section in docker-compose.yml.
- compose config FAILED: mapping key already defined / duplicate service
  - Ensure there is only one service block per name; check merges with overrides.
- Unauthorized on admin endpoints
  - X-Admin-Token header must match ADMIN_TOKEN or ADMIN_TOKEN_FILE secret (secrets/admin_token).
- Missing secrets
  - Create files under ./secrets (e.g., admin_token, postgres_password) as described above.
- Services unhealthy
  - Verify Redis/Postgres are up; check dependent service logs; re-create: docker compose up -d --force-recreate <service>.
- Tests flaking due to stale state
  - For dev only: docker compose down -v (removes volumes), or selectively prune; for Redis-only reset: docker compose exec redis redis-cli FLUSHALL.
- Prettier not found locally
  - npm ci (installs prettier); then npm run format:check.

If problems persist, capture outputs of config/ps/logs and open an issue with that context.

## Production checklist

For local testing, use docker-compose.override.yml to expose service ports to localhost. Do not use this override in production.

Quick start

- cp .env.example .env
- mkdir -p secrets; printf 'changeme' > secrets/admin_token; printf 'postgrespass' > secrets/postgres_password
- docker compose build && docker compose up -d
- Open Grafana at http://localhost:3000 (admin/admin by default, see .env.example)
- Health checks: http://localhost:7001/health (orchestrator), http://localhost:7004/health (risk)
- Run tests: docker compose run --rm tests

Exposed ports (override)

- Orchestrator 7001, Market Analyst 7002, Portfolio Manager 7003, Risk Manager 7004, Trade Executor 7005, Notification Manager 7006, Parameter Optimizer 7007, MCP Hub Controller 7008, Integrations Broker 7010, Redis 6379, Postgres 5432, Prometheus 9090, Grafana 3000, Alertmanager 9093, Loki 3100, oauth2-proxy 4180

Note: Keep admin endpoints protected even locally. Admin routes require X-Admin-Token and can be additionally protected with oauth2-proxy if desired.

## Production checklist

Identity and access

- Protect Orchestrator with OAuth2/OIDC (oauth2-proxy) and rate limiting.
- Require mTLS for /admin/\* routes in addition to OAuth and X-Admin-Token.
- Restrict Prometheus/Grafana/Traefik to trusted IPs or add OAuth there too.
- Rotate all tokens and credentials regularly; least-privilege.

Secrets management

- Use Docker secrets for admin token, Postgres password, Slack tokens, OAuth client/secret/cookie.
- Avoid real secrets in .env; restrict file permissions; never commit secrets.

Network exposure

- Only Traefik is public; keep agent ports internal.
- Enforce TLS, HSTS; apply Traefik rate limiting and auth middlewares.

Persistence and backups

- Postgres: nightly pg_dump + restore drills; retention policy; monitor failures.
- Redis: RDB/AOF snapshots; verify persistence strategy; consider managed Redis.

HA and reliability

- Consider managed HA Postgres/Redis for production.
- Use Redis Streams with consumer groups, idempotency TTL, and DLQ monitoring.
- Alerts on stream lag, DLQ growth, and consumer health.

Monitoring and alerting

- Prometheus + Alertmanager Slack configured; add postgres_exporter and redis_exporter.
- Grafana dashboards for Streams pending/DLQ, service health, and business KPIs (PnL, fills, approvals).
- Define SLOs (e.g., error rate, latency) and alert on breaches.

Logging

- Ship JSON logs to Loki/ELK/Datadog; retain; index by requestId/traceId; avoid PII.

Security hardening

- Containers run non-root, read-only FS, cap_drop ALL, no-new-privileges; minimal tmpfs.
- UFW default deny; SSH key-only; fail2ban; timely patching.
- Optional: seccomp/apparmor profiles, image signature verification.

CI/CD and supply chain

- CI runs build/tests/integration; add image scanning (Trivy) and dependency checks.
- Produce SBOM; consider image signing; blue/green or canary deploys with rollback.

Data, audit, compliance

- Persist audits (audit_events) and key state; define retention windows.
- Time sync (NTP); consider regulatory requirements if trading live.

Trading safeguards

- Use sandbox exchange first; feature-flag “live mode”.
- Enforce risk limits (max order size/position, loss caps, trading windows); circuit breakers.
- Reconciliation jobs; PnL accuracy (fees/slippage); manual halt/unhalt runbooks.

Runbooks and ops

- DLQ inspection and requeue (admin endpoints or scripts/ops_cli.js).
- Halt/unhalt procedures; cert/token rotation; backup/restore drills.

Scalability

- Set resource limits/requests; horizontal scale consumers by group.
- Monitor Redis throughput; partition streams if needed.

Testing

- Expand unit/contract tests; load tests; chaos (restarts, network blips); simulate Slack/DB/Redis failures.
