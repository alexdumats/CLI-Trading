# Runbook: HighHttpLatencyP95

Alert condition: p95 > 1s for 10m.

Triage

- Identify which service has elevated latency (Grafana gauge and Explore).
- Check error rates and recent changes.

Diagnosis

- docker compose logs <service> | jq . (if logs routed)
- Verify dependency latency (Redis/Postgres exporters) and CPU/memory pressure.

Mitigation

- Roll back offending change or scale out (if applicable).
- Optimize slow endpoints; add caching; increase resource limits temporarily.

Verification

- p95 drops below threshold; alert resolves.
