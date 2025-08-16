import express from 'express';
import morgan from 'morgan';
import Redis from 'ioredis';
import client from 'prom-client';

const SERVICE_NAME = process.env.SERVICE_NAME || 'Claude MCP Hub Controller';
const PORT = parseInt(process.env.PORT || '7008', 10);
const REDIS_URL = process.env.REDIS_URL || 'redis://localhost:6379/0';

const app = express();
app.use(express.json());
app.use(morgan('dev'));

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
  res.json({ status: 'ok', service: SERVICE_NAME, redis: redisStatus, uptime: process.uptime(), ts: new Date().toISOString() });
});

// Metrics
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

// Role endpoints

// MCP endpoints
app.get('/mcp/status', (req, res) => res.json({ status: 'ok', hubs: [] }));
app.post('/mcp/command', (req, res) => res.status(202).json({ status: 'accepted', command: req.body || {} }));


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
  try { await redis.quit(); } catch (e) {}
  process.exit(0);
};
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
