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
  NOTIFY_EVENTS: 'notify.events',
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
  buckets: [0.05, 0.1, 0.3, 0.5, 1, 2, 5],
});
register.registerMetric(httpRequestDuration);
const streamPendingGauge = new client.Gauge({
  name: 'stream_pending_count',
  help: 'Pending messages in Redis Streams',
  labelNames: ['stream', 'group'],
});
register.registerMetric(streamPendingGauge);
// Risk metrics and active params gauges
const riskEvalCounter = new client.Counter({
  name: 'risk_evaluations_total',
  help: 'Total risk evaluations',
  labelNames: ['result', 'reason'],
});
register.registerMetric(riskEvalCounter);
const riskMinConfGauge = new client.Gauge({
  name: 'risk_active_min_confidence',
  help: 'Active minConfidence in Risk Manager',
});
register.registerMetric(riskMinConfGauge);
const riskLimitGauge = new client.Gauge({
  name: 'risk_active_risk_limit',
  help: 'Active riskLimit (max allowed 1-confidence)',
});
register.registerMetric(riskLimitGauge);
const riskWinStartGauge = new client.Gauge({
  name: 'risk_active_trading_window_start_hour',
  help: 'Trading window start hour (UTC)',
});
register.registerMetric(riskWinStartGauge);
const riskWinEndGauge = new client.Gauge({
  name: 'risk_active_trading_window_end_hour',
  help: 'Trading window end hour (UTC)',
});
register.registerMetric(riskWinEndGauge);

async function loadParams(redis) {
  const params = await redis.hgetall('optimizer:active_params');
  const minConfidence = (() => {
    const v = parseFloat(params?.minConfidence || 'NaN');
    return isNaN(v) ? 0.6 : v;
  })();
  const riskLimit = (() => {
    const v = parseFloat(params?.riskLimit || 'NaN');
    return isNaN(v) ? 0.5 : v;
  })();
  const startHour = (() => {
    const v = parseInt(params?.tradingStartHour || 'NaN', 10);
    return isNaN(v) ? null : v;
  })();
  const endHour = (() => {
    const v = parseInt(params?.tradingEndHour || 'NaN', 10);
    return isNaN(v) ? null : v;
  })();
  const blockSides = String(params?.blockSides || '')
    .toLowerCase()
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  if (!isNaN(minConfidence)) riskMinConfGauge.set(minConfidence);
  if (!isNaN(riskLimit)) riskLimitGauge.set(riskLimit);
  if (startHour !== null) riskWinStartGauge.set(startHour);
  if (endHour !== null) riskWinEndGauge.set(endHour);
  return { minConfidence, riskLimit, startHour, endHour, blockSides };
}

function inWindowUTC(startHour, endHour, date = new Date()) {
  if (startHour === null || endHour === null) return true; // no window set
  const h = date.getUTCHours();
  if (startHour <= endHour) return h >= startHour && h < endHour;
  // overnight window (e.g., 22 -> 6)
  return h >= startHour || h < endHour;
}

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
    await pub.ping();
    await sub.ping();
    redisStatus = 'ok';
  } catch (e) {
    redisStatus = 'error';
  }
  res.json({
    status: 'ok',
    service: SERVICE_NAME,
    redis: redisStatus,
    uptime: process.uptime(),
    ts: new Date().toISOString(),
  });
});

// Metrics
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

// Standardized status
app.get('/status', async (req, res) => {
  let redisStatus = 'unknown';
  try {
    await pub.ping();
    await sub.ping();
    redisStatus = 'ok';
  } catch {
    redisStatus = 'error';
  }
  res.json({
    status: 'ok',
    service: SERVICE_NAME,
    role: 'risk-manager',
    version: process.env.npm_package_version || '0.0.0',
    uptime: process.uptime(),
    deps: { redis: redisStatus },
  });
});

// REST endpoints
app.post('/risk/evaluate', async (req, res) => {
  const params = await loadParams(sub);
  const { confidence = 0, side = '' } = req.body || {};
  const minConfidence = isNaN(parseFloat(String(params?.minConfidence)))
    ? 0.6
    : parseFloat(String(params.minConfidence));
  const riskLimit = isNaN(parseFloat(String(params?.riskLimit)))
    ? null
    : parseFloat(String(params.riskLimit));
  const riskLimitThreshold = riskLimit == null ? null : 1 - Math.max(0, Math.min(1, riskLimit));
  const startHour = params?.startHour ?? null;
  const endHour = params?.endHour ?? null;
  const blockSides = Array.isArray(params?.blockSides) ? params.blockSides : [];

  let ok = true;
  let reason = 'none';
  if (!inWindowUTC(startHour, endHour)) {
    ok = false;
    reason = 'outside_window';
  } else if (blockSides.includes(String(side).toLowerCase())) {
    ok = false;
    reason = 'blocked_side';
  } else {
    const threshold =
      riskLimitThreshold == null ? minConfidence : Math.max(minConfidence, riskLimitThreshold);
    if (confidence < threshold) {
      if (
        riskLimitThreshold != null &&
        riskLimitThreshold >= minConfidence &&
        confidence < riskLimitThreshold
      ) {
        reason = 'risk_limit';
      } else {
        reason = 'low_confidence';
      }
      ok = false;
    }
  }

  const riskScore = 1 - Math.max(0, Math.min(1, confidence));
  try {
    riskEvalCounter.inc({ result: ok ? 'ok' : 'reject', reason });
  } catch {}
  res.json({
    ok,
    reason: ok ? undefined : reason,
    riskScore,
    minConfidence,
    riskLimit,
    startHour,
    endHour,
  });
});
app.get('/risk/limits', (req, res) =>
  res.json({ limits: { maxPosition: 0, maxOrderSize: 0 }, note: 'stub' })
);

// Standardized stubs
app.post('/execute', (req, res) => res.status(501).json({ error: 'not_implemented' }));
app.post('/optimize', (req, res) => res.status(501).json({ error: 'not_implemented' }));

// Subscribe to risk requests and publish responses (Streams)
await (async () => {
  startPendingMonitor({
    redis: sub,
    stream: CHANNELS.RISK_REQUESTS,
    group: 'risk',
    onCount: (c) => streamPendingGauge.set({ stream: CHANNELS.RISK_REQUESTS, group: 'risk' }, c),
  });
  startConsumer({
    redis: sub,
    stream: CHANNELS.RISK_REQUESTS,
    group: 'risk',
    logger,
    idempotency: { redis: sub, keyFn: (p) => p.requestId, ttlSeconds: 86400 },
    dlqStream: `${CHANNELS.RISK_REQUESTS}.dlq`,
    maxFailures: 5,
    handler: async ({ payload: req }) => {
      const p = await loadParams(sub);
      const minConfidence = isNaN(parseFloat(String(p?.minConfidence)))
        ? 0.6
        : parseFloat(String(p.minConfidence));
      const riskLimit = isNaN(parseFloat(String(p?.riskLimit)))
        ? null
        : parseFloat(String(p.riskLimit));
      const riskLimitThreshold = riskLimit == null ? null : 1 - Math.max(0, Math.min(1, riskLimit));
      const startHour = p?.startHour ?? null;
      const endHour = p?.endHour ?? null;
      const blockSides = Array.isArray(p?.blockSides) ? p.blockSides : [];

      let ok = true;
      let reason = 'none';
      if (!inWindowUTC(startHour, endHour)) {
        ok = false;
        reason = 'outside_window';
      } else if (blockSides.includes(String(req.side || '').toLowerCase())) {
        ok = false;
        reason = 'blocked_side';
      } else {
        const threshold =
          riskLimitThreshold == null ? minConfidence : Math.max(minConfidence, riskLimitThreshold);
        if ((req.confidence || 0) < threshold) {
          if (
            riskLimitThreshold != null &&
            riskLimitThreshold >= minConfidence &&
            (req.confidence || 0) < riskLimitThreshold
          ) {
            reason = 'risk_limit';
          } else {
            reason = 'low_confidence';
          }
          ok = false;
        }
      }

      const resp = {
        requestId: req.requestId,
        ok,
        reason: ok ? undefined : reason,
        minConfidence,
        riskLimit,
        traceId: req.traceId,
        ts: new Date().toISOString(),
      };
      try {
        riskEvalCounter.inc({ result: ok ? 'ok' : 'reject', reason });
      } catch {}
      await xaddJSON(pub, CHANNELS.RISK_RESPONSES, resp);
      if (!ok) {
        await xaddJSON(pub, CHANNELS.NOTIFY_EVENTS, {
          type: 'risk_rejected',
          severity: 'warning',
          context: req,
          traceId: req.traceId,
          ts: new Date().toISOString(),
        });
      }
    },
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
  try {
    await sub.quit();
  } catch {}
  try {
    await pub.quit();
  } catch {}
  process.exit(0);
};
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
