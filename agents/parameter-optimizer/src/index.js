import express from 'express';
import morgan from 'morgan';
import Redis from 'ioredis';
import client from 'prom-client';
import { xaddJSON, startConsumer, startPendingMonitor } from '../../../common/streams.js';
import { createLogger } from '../../../common/logger.js';
import fs from 'node:fs';

// Allow ADMIN_TOKEN to be supplied via file for secrets handling
if (process.env.ADMIN_TOKEN_FILE && !process.env.ADMIN_TOKEN) {
  try {
    process.env.ADMIN_TOKEN = fs.readFileSync(process.env.ADMIN_TOKEN_FILE, 'utf8').trim();
  } catch {}
}

const SERVICE_NAME = process.env.SERVICE_NAME || 'Claude Parameter Optimizer';
const PORT = parseInt(process.env.PORT || '7007', 10);
const REDIS_URL = process.env.REDIS_URL || 'redis://localhost:6379/0';

const app = express();
const logger = createLogger(SERVICE_NAME);
app.use(express.json());
app.use(morgan('dev'));

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
// Gauge for active min confidence (updated on approve or by periodic refresh)
const activeMinConfidenceGauge = new client.Gauge({
  name: 'optimizer_active_min_confidence',
  help: 'Active minConfidence threshold deployed',
});
register.registerMetric(activeMinConfidenceGauge);

// Redis
const redis = new Redis(REDIS_URL);
redis.on('error', (err) => {
  console.error(`[${SERVICE_NAME}] Redis error:`, err.message);
});

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
    await redis.ping();
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
    await redis.ping();
    redisStatus = 'ok';
  } catch {
    redisStatus = 'error';
  }
  res.json({
    status: 'ok',
    service: SERVICE_NAME,
    role: 'parameter-optimizer',
    version: process.env.npm_package_version || '0.0.0',
    uptime: process.uptime(),
    deps: { redis: redisStatus },
  });
});

// Streams wiring
const pub = new Redis(REDIS_URL);
const sub = new Redis(REDIS_URL);
const STREAM_REQ = 'opt.requests';
const STREAM_RES = 'opt.results';
const GROUP = 'optimizer';

const optJobs = new Map(); // jobId -> { status, params, metrics }
const optCounter = new client.Counter({
  name: 'optimizer_jobs_total',
  help: 'Total optimizer jobs',
  labelNames: ['status'],
});
register.registerMetric(optCounter);

startPendingMonitor({
  redis: sub,
  stream: STREAM_REQ,
  group: GROUP,
  onCount: (c) => {
    /* no dedicated gauge here, reuse global if needed */
  },
});
startConsumer({
  redis: sub,
  stream: STREAM_REQ,
  group: GROUP,
  logger,
  idempotency: {
    redis: sub,
    keyFn: (e) => e.orderId || `${e.reason}:${e.traceId || ''}:${e.ts || ''}`,
    ttlSeconds: 86400,
  },
  dlqStream: `${STREAM_REQ}.dlq`,
  maxFailures: 5,
  handler: async ({ payload: req }) => {
    const jobId = `opt-${Date.now()}`;
    // simple stub: recommend reduced risk if loss
    const recommended = { minConfidence: 0.55, riskLimit: 0.5, symbol: req.symbol };
    const backtest = { winRate: 0.55, sharpe: 1.1, maxDD: 0.08 };
    optJobs.set(jobId, { status: 'pending_approval', params: recommended, metrics: backtest });
    await xaddJSON(pub, STREAM_RES, {
      jobId,
      recommended,
      backtest,
      approval: 'pending',
      traceId: req.traceId,
      ts: new Date().toISOString(),
    });
    optCounter.inc({ status: 'generated' });
    // notify
    await xaddJSON(pub, 'notify.events', {
      type: 'optimizer_result',
      severity: 'info',
      message: 'Optimizer generated params (pending approval)',
      context: { jobId, recommended, backtest },
      traceId: req.traceId,
      ts: new Date().toISOString(),
    });
  },
});

// Role endpoints

// Optimization endpoints
app.post('/optimize/run', (req, res) =>
  res.status(202).json({ status: 'accepted', jobId: `manual-${Date.now()}` })
);
app.post('/optimize', (req, res) =>
  res.status(202).json({ status: 'accepted', jobId: `manual-${Date.now()}` })
);
app.get('/optimize/params', async (req, res) => {
  try {
    const params = await redis.hgetall('optimizer:active_params');
    const mc = parseFloat(params?.minConfidence || 'NaN');
    if (!isNaN(mc)) activeMinConfidenceGauge.set(mc);
  } catch {}

  try {
    const params = await redis.hgetall('optimizer:active_params');
    const parsed = Object.fromEntries(
      Object.entries(params || {}).map(([k, v]) => [k, parseFloat(v)])
    );
    res.json({ params: parsed, raw: params });
  } catch (e) {
    res.status(500).json({ error: 'read_failed', detail: String(e?.message || e) });
  }
});

// Admin: approve and deploy parameters (store in Redis hash)
app.post('/admin/optimize/approve', async (req, res) => {
  const token = req.header('x-admin-token') || '';
  if (!process.env.ADMIN_TOKEN || token !== process.env.ADMIN_TOKEN)
    return res.status(401).json({ error: 'unauthorized' });
  const { jobId } = req.body || {};
  if (!jobId) return res.status(400).json({ error: 'missing_jobId' });
  const job = optJobs.get(jobId);
  if (!job) return res.status(404).json({ error: 'job_not_found' });
  // Deploy by persisting into Redis for consumers to pick up
  try {
    await pub.hset(
      'optimizer:active_params',
      Object.fromEntries(Object.entries(job.params).map(([k, v]) => [k, String(v)]))
    );
    optJobs.set(jobId, { ...job, status: 'approved' });
    optCounter.inc({ status: 'approved' });
    const mc = parseFloat(String(job.params?.minConfidence ?? 'NaN'));
    if (!isNaN(mc)) activeMinConfidenceGauge.set(mc);
    await xaddJSON(pub, 'notify.events', {
      type: 'optimizer_approved',
      severity: 'info',
      message: 'Optimizer params approved and deployed',
      context: { jobId, params: job.params },
      ts: new Date().toISOString(),
    });
    res.json({ ok: true, jobId, deployed: job.params });
  } catch (e) {
    res.status(500).json({ error: 'deploy_failed', detail: String(e?.message || e) });
  }
});

// 404
app.use((req, res) => {
  res.status(404).json({ error: 'not_found', path: req.path });
});

const server = app.listen(PORT, () => {
  console.log(`[${SERVICE_NAME}] listening on :${PORT}`);
});

const shutdown = async () => {
  console.log(`[${SERVICE_NAME}] shutting down...`);
  server.close(() => console.log(`[${SERVICE_NAME}] server closed`));
  try {
    await redis.quit();
  } catch (e) {}
  process.exit(0);
};
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
