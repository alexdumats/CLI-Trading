# Claude Multi-Agent Trading System (Scaffold)

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
1) Review docker-compose.yml and .env.example, set environment variables accordingly (copy `.env.example` -> `.env`).
2) Deploy with `docker compose up -d`.
3) Confirm services are healthy via `/health` and `/metrics`.
4) We will then implement business logic, inter-agent communication, and the 1% daily profit target coordination.

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

## Production checklist

Identity and access
- Protect Orchestrator with OAuth2/OIDC (oauth2-proxy) and rate limiting.
- Require mTLS for /admin/* routes in addition to OAuth and X-Admin-Token.
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

