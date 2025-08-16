import express from 'express';
import Redis from 'ioredis';
import client from 'prom-client';
import { createLogger } from '../../../common/logger.js';
import fs from 'node:fs';
import { traceMiddleware, requestLoggerMiddleware } from '../../../common/trace.js';

// Allow ADMIN_TOKEN to be supplied via file for secrets handling
if (process.env.ADMIN_TOKEN_FILE && !process.env.ADMIN_TOKEN) {
  try { process.env.ADMIN_TOKEN = fs.readFileSync(process.env.ADMIN_TOKEN_FILE, 'utf8').trim(); } catch {}
}

const SERVICE_NAME = process.env.SERVICE_NAME || 'Claude Notification Manager';
const PORT = parseInt(process.env.PORT || '7006', 10);
const REDIS_URL = process.env.REDIS_URL || 'redis://localhost:6379/0';

// Redis pub/sub
const pub = new Redis(REDIS_URL);
const sub = new Redis(REDIS_URL);
pub.on('error', (err) => console.error(`[${SERVICE_NAME}] Redis pub error:`, err.message));
sub.on('error', (err) => console.error(`[${SERVICE_NAME}] Redis sub error:`, err.message));

// Channels
const CHANNELS = {
  NOTIFY_EVENTS: 'notify.events'
};

// In-memory store of recent events
const recent = [];
const MAX_EVENTS = 100;

const app = express();
const logger = createLogger(SERVICE_NAME);
app.use(express.json());
app.use(traceMiddleware(SERVICE_NAME));
app.use(requestLoggerMiddleware(logger));

// Metrics
const register = new client.Registry();
client.collectDefaultMetrics({ register });
const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'path', 'status'],
  buckets: [0.05, 0.1, 0.3, 0.5, 1, 2, 5]
});
register.registerMetric(httpRequestDuration);
const streamPendingGauge = new client.Gauge({ name: 'stream_pending_count', help: 'Pending messages in Redis Streams', labelNames: ['stream','group'] });
register.registerMetric(streamPendingGauge);

// Timing middleware
app.use((req, res, next) => {
  const end = httpRequestDuration.startTimer({ method: req.method, path: req.path });
  res.on('finish', () => end({ status: String(res.statusCode) }));
  next();
});

// Health
app.get('/health', async (req, res) => {
  let redisStatus = 'unknown';
  try {
    await pub.ping(); await sub.ping();
    redisStatus = 'ok';
  } catch (e) {
    redisStatus = 'error';
  }
  res.json({ status: 'ok', service: SERVICE_NAME, redis: redisStatus, uptime: process.uptime(), ts: new Date().toISOString() });
});

// Metrics
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

// REST endpoints
app.post('/notify', (req, res) => res.status(202).json({ status: 'accepted', id: 'demo-notify-id' }));
app.get('/notify/status/:id', (req, res) => res.json({ id: req.params.id, delivered: false }));
app.get('/notify/recent', async (req, res) => {
  try {
    // Batch check ack state via pipeline
    const ids = recent.map(e => e.traceId || e.requestId).filter(Boolean);
    const keys = ids.map(ackKey);
    let acks = [];
    if (keys.length) {
      const pipe = sub.pipeline();
      keys.forEach(k => pipe.exists(k));
      const results = await pipe.exec();
      acks = results.map(r => (Array.isArray(r) ? r[1] : r));
    }
    let idx = 0;
    const withAck = recent.map(e => {
      const id = e.traceId || e.requestId;
      const acked = id ? Boolean(acks[idx++]) : false;
      return { ...e, acked };
    });
    res.json({ events: withAck });
  } catch (e) {
    res.status(500).json({ error: 'list_failed', detail: String(e?.message || e) });
  }
});

// Admin: acknowledge an event (persisted in Redis)
const ACK_TTL_SECONDS = parseInt(process.env.ACK_TTL_SECONDS || '604800', 10);
function ackKey(id) { return `notify:ack:${id}`; }
app.post('/admin/notify/ack', async (req, res) => {
  const token = req.header('x-admin-token') || '';
  if (!process.env.ADMIN_TOKEN || token !== process.env.ADMIN_TOKEN) return res.status(401).json({ error: 'unauthorized' });
  const { traceId, requestId } = req.body || {};
  const id = traceId || requestId;
  if (!id) return res.status(400).json({ error: 'missing_trace_or_request_id' });
  try {
    await pub.set(ackKey(id), '1', 'EX', ACK_TTL_SECONDS);
    res.json({ ok: true, acked: id, ttl: ACK_TTL_SECONDS });
  } catch (e) {
    res.status(500).json({ error: 'ack_failed', detail: String(e?.message || e) });
  }
});

// Admin: inspect DLQ (optional forwarder to Orchestrator admin endpoints)
app.get('/admin/dlq', async (req, res) => {
  const token = req.header('x-admin-token') || '';
  if (!process.env.ADMIN_TOKEN || token !== process.env.ADMIN_TOKEN) return res.status(401).json({ error: 'unauthorized' });
  const stream = `${CHANNELS.NOTIFY_EVENTS}.dlq`;
  try {
    const entries = await sub.xrange(stream, '-', '+', 'COUNT', 50);
    const result = entries.map(([id, fields]) => {
      const idx = fields.findIndex((v, i) => i % 2 === 0 && v === 'data');
      const jsonStr = idx >= 0 ? fields[idx + 1] : null;
      return { id, payload: jsonStr ? JSON.parse(jsonStr) : null };
    });
    return res.json({ stream, entries: result });
  } catch (e) {
    return res.status(500).json({ error: 'dlq_inspect_failed', detail: String(e?.message || e) });
  }
});

// Subscribe to NOTIFY_EVENTS as Streams
const SLACK_WEBHOOK_URL = process.env.SLACK_WEBHOOK_URL || '';
await (async () => {
  const stream = CHANNELS.NOTIFY_EVENTS;
  const group = 'notify';
  startPendingMonitor({ redis: sub, stream, group, onCount: (c)=> streamPendingGauge.set({stream, group}, c) });
  startConsumer({
    redis: sub,
    stream,
    group,
    logger,
    idempotency: { redis: sub, keyFn: (e)=> e.requestId || `${e.type}:${e.traceId || ''}:${e.ts || ''}`, ttlSeconds: parseInt(process.env.STREAM_IDEMP_TTL_SECONDS || '86400', 10) },
    dlqStream: `${stream}.dlq`,
    maxFailures: parseInt(process.env.STREAM_MAX_FAILURES || '5', 10),
    handler: async ({ payload: event }) => {
      recent.push({ ...event, receivedAt: new Date().toISOString() });
      if (recent.length > MAX_EVENTS) recent.shift();
      logger.info('notify_event', { type: event.type, severity: event.severity, requestId: event.requestId, traceId: event.traceId });

      // Build Slack payload (Block Kit)
      const sev = (event.severity || 'info').toLowerCase();
      const emoji = sev === 'critical' ? '🚨' : sev === 'warning' ? '⚠️' : 'ℹ️';
      const title = event.message || event.type || 'Notification';
      const grafanaUrl = process.env.GRAFANA_URL || null;
      const promUrl = process.env.PROM_URL || null;
      const fields = [
        { type: 'mrkdwn', text: `*Type:*\n${event.type || 'n/a'}` },
        { type: 'mrkdwn', text: `*Severity:*\n${sev.toUpperCase()}` },
        { type: 'mrkdwn', text: `*Trace ID:*\n${event.traceId || 'n/a'}` },
        { type: 'mrkdwn', text: `*Request ID:*\n${event.requestId || 'n/a'}` }
      ];
      if (event.context && typeof event.context === 'object') {
        fields.push({ type: 'mrkdwn', text: `*Context:*\n\`\`${JSON.stringify(event.context).slice(0, 500)}\`\`` });
      }
      const blocks = [
        { type: 'header', text: { type: 'plain_text', text: `${emoji} ${title}`, emoji: true } },
        { type: 'section', fields },
      ];
      if (grafanaUrl || promUrl) {
        const links = [grafanaUrl ? `<${grafanaUrl}|Grafana>` : null, promUrl ? `<${promUrl}|Prometheus>` : null].filter(Boolean).join(' | ');
        if (links) blocks.push({ type: 'context', elements: [{ type: 'mrkdwn', text: links }] });
      }
      const payload = { text: `${sev.toUpperCase()}: ${title}`, blocks };

      const hook = (sev === 'critical' && process.env.SLACK_WEBHOOK_URL_CRITICAL)
        || (sev === 'warning' && process.env.SLACK_WEBHOOK_URL_WARNING)
        || (sev === 'info' && process.env.SLACK_WEBHOOK_URL_INFO)
        || SLACK_WEBHOOK_URL;

      if (hook) {
        const resp = await fetch(hook, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
        if (!resp.ok) throw new Error(`slack_webhook_status_${resp.status}`);
      }
    }
  });
})();

// 404
app.use((req, res) => {
  res.status(404).json({ error: 'not_found', path: req.path });
});

const server = app.listen(PORT, () => {
  logger.info('listening', { port: PORT });
});

const shutdown = async () => {
  logger.info('shutting_down');
  server.close(() => logger.info('server_closed'));
  try { await sub.quit(); } catch {}
  try { await pub.quit(); } catch {}
  process.exit(0);
};
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
