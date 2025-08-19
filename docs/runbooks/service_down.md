# Runbook: ServiceDown

When this alert fires, one or more Prometheus scrape targets report `up==0`.

Triage

- Check Grafana Services Down panel for affected instances.
- Inspect recent deploys or host/network changes.

Diagnosis

- docker compose ps; docker compose logs <service>
- curl http://<service>:<port>/health from within the backend network (docker exec into another container if needed)
- Traefik route health (if ingress-related)

Mitigation

- Restart the service: docker compose restart <service>
- If Redis/Postgres dependency is down, restore those first.
- Roll back to last-known-good image if a new deploy caused the issue.

Verification

- Confirm /health and /metrics return 200.
- Alert resolves; Grafana up==1 for target.
