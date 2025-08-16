# Messaging Contracts (Redis Pub/Sub)

All inter-agent messaging uses Redis pub/sub on the `backend` Docker network. Channels and payloads are JSON. All messages must include a `ts` ISO timestamp and stable identifiers where indicated.

Channels:
- orchestrator.commands
  - analyze request: { type: 'analyze', requestId: string, symbol: string, ts }
  - halt request: { type: 'halt', ts }
- analysis.signals
  - signal: { requestId: string, symbol: string, side: 'buy'|'sell', confidence: number, ts }
- risk.requests
  - { requestId: string, symbol: string, side: 'buy'|'sell', confidence: number, ts }
- risk.responses
  - { requestId: string, ok: boolean, reason?: string, ts }
- exec.orders
  - { orderId: string, symbol: string, side: 'buy'|'sell', qty: number, ts }
- exec.status
  - { orderId: string, status: 'filled'|'rejected'|'failed'|'pending', symbol: string, side: string, qty: number, ts }
- notify.events
  - { type: string, severity: 'info'|'warning'|'critical', message?: string, context?: any, ts }

ID semantics:
- requestId: created by Orchestrator when requesting analysis; propagated through risk.
- orderId: created by Orchestrator when submitting orders; may equal requestId for 1:1 mapping in this scaffold.

Reliability:
- Pub/sub is fire-and-forget. For production consider Redis streams or a durable queue (e.g., NATS, Kafka, RabbitMQ) with ack/retry.

Security:
- Channels are internal-only on the Docker network. If exposing Redis outside, require auth and TLS.
