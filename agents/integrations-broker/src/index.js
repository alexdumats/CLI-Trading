import express from 'express';
import Redis from 'ioredis';
import client from 'prom-client';
import { createLogger } from '../../../common/logger.js';
import { traceMiddleware, requestLoggerMiddleware } from '../../../common/trace.js';
import { xaddJSON, startConsumer, startPendingMonitor } from '../../../common/streams.js';
import { createJiraIssue } from '../../../common/integrations/jira.js';
import { createOrUpdateNotionPage } from '../../../common/integrations/notion.js';
import { handleEvent } from './handler.js';

const SERVICE_NAME = process.env.SERVICE_NAME || 'Claude Integrations Broker';
const PORT = parseInt(process.env.PORT || '7010', 10);
const REDIS_URL = process.env.REDIS_URL || 'redis://localhost:6379/0';
const ENABLE_JIRA = (process.env.ENABLE_JIRA || 'false').toLowerCase() === 'true';
const ENABLE_NOTION = (process.env.ENABLE_NOTION || 'false').toLowerCase() === 'true';

// Redis
const pub = new Redis(REDIS_URL);
const sub = new Redis(REDIS_URL);
pub.on('error', (err) => console.error(`[${SERVICE_NAME}] Redis pub error:`, err.message));
sub.on('error', (err) => console.error(`[${SERVICE_NAME}] Redis sub error:`, err.message));

// Streams
const STREAM = 'notify.events';
const GROUP = 'integrations';

// App
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
const integrationCounter = new client.Counter({
  name: 'integration_events_total',
  help: 'Total events handled by integrations broker',
  labelNames: ['target', 'result'],
});
register.registerMetric(integrationCounter);

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
    enable: { jira: ENABLE_JIRA, notion: ENABLE_NOTION },
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
    role: 'integrations-broker',
    version: process.env.npm_package_version || '0.0.0',
    uptime: process.uptime(),
    deps: { redis: redisStatus },
  });
});

// 404
app.use((req, res) => {
  res.status(404).json({ error: 'not_found', path: req.path });
});

await (async () => {
  startPendingMonitor({
    redis: sub,
    stream: STREAM,
    group: GROUP,
    onCount: (c) => streamPendingGauge.set({ stream: STREAM, group: GROUP }, c),
  });
  startConsumer({
    redis: sub,
    stream: STREAM,
    group: GROUP,
    logger,
    idempotency: {
      redis: sub,
      keyFn: (e) => e.requestId || `${e.type}:${e.traceId || ''}:${e.ts || ''}`,
      ttlSeconds: parseInt(process.env.STREAM_IDEMP_TTL_SECONDS || '86400', 10),
    },
    dlqStream: `${STREAM}.dlq`,
    maxFailures: parseInt(process.env.STREAM_MAX_FAILURES || '5', 10),
    handler: async ({ payload: event }) => {
      await handleEvent({
        event,
        enableJira: ENABLE_JIRA,
        enableNotion: ENABLE_NOTION,
        jiraIssue: createJiraIssue,
        notionPage: createOrUpdateNotionPage,
        inc: (target, result) => integrationCounter.inc({ target, result }),
        logger,
      });
    },
  });
})();

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
