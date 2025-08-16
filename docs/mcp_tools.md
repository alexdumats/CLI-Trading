# Slack MCP Tools for Orchestrator Admin

These HTTP tools can be used with slack-mcp-server to allow Slack interactions (buttons/commands) to manage the system.

Base URL (internal in compose):
- Orchestrator: http://orchestrator:7001
- Notification Manager: http://notification-manager:7006

All admin endpoints require the header `X-Admin-Token: <ADMIN_TOKEN>`

Tools
1) Halt orchestration
- Method: POST
- URL: /admin/orchestrate/halt
- Body: { "reason": "manual|<text>" }
- Response: { ok: true, halted: true }

2) Unhalt orchestration
- Method: POST
- URL: /admin/orchestrate/unhalt
- Body: {}
- Response: { ok: true, halted: false }

3) Acknowledge a notification event
- Method: POST
- URL: http://notification-manager:7006/admin/notify/ack
- Body: { "traceId": "..." } or { "requestId": "..." }
- Response: { ok: true, acked: "<id>" }

4) Streams: list pending (or use Orchestrator admin already provided)
- Method: GET
- URL: /admin/streams/pending?stream=<stream>&group=<group>

5) Streams DLQ list & requeue
- GET /admin/streams/dlq?stream=<dlq>
- POST /admin/streams/dlq/requeue { dlqStream, id }

Suggested Slack Blocks
- Manual halt confirmation: button triggers POST /admin/orchestrate/halt
- Manual unhalt: button triggers POST /admin/orchestrate/unhalt
- Acknowledge: button triggers POST /admin/notify/ack with traceId

Security
- Ensure slack-mcp-server calls include X-Admin-Token. Keep ADMIN_TOKEN secret.
- Keep Notification Manager internal or protect via Traefik if exposed.
