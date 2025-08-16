import express from 'express';
import Redis from 'ioredis';
import client from 'prom-client';
import { createLogger } from '../../../common/logger.js';
import { traceMiddleware, requestLoggerMiddleware } from '../../../common/trace.js';
import { xaddJSON, startConsumer, startPendingMonitor } from '../../../common/streams.js';

const SERVICE_NAME = process.env.SERVICE_NAME || 'Claude Risk Manager';
const PORT = parseInt(process.env.PORT || '7004', 10);
const REDIS_URL = process.env.REDIS_URL || 'redis://localhost:6379/0';

// Redis pub/sub
const pub = new Redis(REDIS_URL);
const sub = new Redis(REDIS_URL);
pub.on('error', (err) => console.error(`[${SERVICE_NAME}] Redis pub error:`, err.message));
sub.on('error', (err) => console.error(`[${SERVICE_NAME}] Redis sub error:`, err.message));

// Channels
const CHANNELS = {
  RISK_REQUESTS: 'risk.requests',
  RISK_RESPONSES: 'risk.responses',
  NOTIFY_EVENTS: 'notify.events'
};

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
app.post('/risk/evaluate', (req, res) => {
  const { confidence = 0 } = req.body || {};
  const ok = confidence >= 0.6;
  const riskScore = 1 - Math.max(0, Math.min(1, confidence));
  res.json({ ok, reason: ok ? undefined : 'low_confidence', riskScore });
});
app.get('/risk/limits', (req, res) => res.json({ limits: { maxPosition: 0, maxOrderSize: 0 }, note: 'stub' }));

// Subscribe to risk requests and publish responses (Streams)
await (async () => {
  startPendingMonitor({ redis: sub, stream: CHANNELS.RISK_REQUESTS, group: 'risk', onCount: (c)=> streamPendingGauge.set({stream: CHANNELS.RISK_REQUESTS, group: 'risk'}, c) });
  startConsumer({
    redis: sub,
    stream: CHANNELS.RISK_REQUESTS,
    group: 'risk',
    logger,
    idempotency: { redis: sub, keyFn: (p)=>p.requestId, ttlSeconds: 86400 },
    dlqStream: `${CHANNELS.RISK_REQUESTS}.dlq`,
    maxFailures: 5,
    handler: async ({ payload: req }) => {
      const ok = (req.confidence || 0) >= 0.6; // simple stub rule
      const resp = { requestId: req.requestId, ok, reason: ok ? undefined : 'low_confidence', traceId: req.traceId, ts: new Date().toISOString() };
      await xaddJSON(pub, CHANNELS.RISK_RESPONSES, resp);
      if (!ok) {
        await xaddJSON(pub, CHANNELS.NOTIFY_EVENTS, { type: 'risk_rejected', severity: 'warning', context: req, traceId: req.traceId, ts: new Date().toISOString() });
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
