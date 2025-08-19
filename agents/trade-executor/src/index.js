import express from 'express';
import Redis from 'ioredis';
import client from 'prom-client';
import { createLogger } from '../../../common/logger.js';
import { traceMiddleware, requestLoggerMiddleware } from '../../../common/trace.js';
import { xaddJSON, startConsumer, startPendingMonitor } from '../../../common/streams.js';

const SERVICE_NAME = process.env.SERVICE_NAME || 'Claude Trade Executor';
const PORT = parseInt(process.env.PORT || '7005', 10);
const REDIS_URL = process.env.REDIS_URL || 'redis://localhost:6379/0';
const PROFIT_PER_TRADE = parseFloat(process.env.PROFIT_PER_TRADE || '10'); // used only if PAPER mode disabled
const EXCHANGE = process.env.EXCHANGE || 'paper'; // paper | binance | coinbase (future)
import { getPaperAdapter } from '../../../common/exchanges/paper.js';
import { getBinanceAdapter } from '../../../common/exchanges/binance.js';
import { getCoinbaseAdapter } from '../../../common/exchanges/coinbase.js';
const adapter =
  EXCHANGE === 'paper'
    ? getPaperAdapter()
    : EXCHANGE === 'binance'
      ? getBinanceAdapter()
      : EXCHANGE === 'coinbase'
        ? getCoinbaseAdapter()
        : null;

// Redis pub/sub
const pub = new Redis(REDIS_URL);
const sub = new Redis(REDIS_URL);
pub.on('error', (err) => console.error(`[${SERVICE_NAME}] Redis pub error:`, err.message));
sub.on('error', (err) => console.error(`[${SERVICE_NAME}] Redis sub error:`, err.message));

// Channels
const CHANNELS = {
  EXEC_ORDERS: 'exec.orders',
  EXEC_STATUS: 'exec.status',
  NOTIFY_EVENTS: 'notify.events',
};

const ORDER_TIMEOUT_SECONDS = parseInt(process.env.EXEC_ORDER_TIMEOUT_SECONDS || '60', 10);
const ORDER_KEY = (id) => `exec:orders:${id}`;

async function getOrderState(redis, orderId) {
  const data = await redis.hgetall(ORDER_KEY(orderId));
  if (!data || Object.keys(data).length === 0) return null;
  const out = { ...data };
  if (out.qty) out.qty = parseFloat(out.qty);
  if (out.price) out.price = parseFloat(out.price);
  if (out.fee) out.fee = parseFloat(out.fee);
  if (out.last_status)
    try {
      out.last_status = JSON.parse(out.last_status);
    } catch {}
  return out;
}

async function setOrderState(redis, orderId, fields) {
  if (!orderId) return;
  if (fields.orderId && String(fields.orderId) !== String(orderId)) fields.orderId = orderId;
  const flat = Object.fromEntries(
    Object.entries(fields).map(([k, v]) => [
      k,
      typeof v === 'object' ? JSON.stringify(v) : String(v),
    ])
  );
  await redis.hset(ORDER_KEY(orderId), flat);
}

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
    role: 'trade-executor',
    version: process.env.npm_package_version || '0.0.0',
    uptime: process.uptime(),
    deps: { redis: redisStatus },
  });
});

// REST endpoints
app.post('/trade/submit', (req, res) => {
  const { orderId = `${Date.now()}`, symbol = 'BTC-USD', side = 'buy', qty = 1 } = req.body || {};
  // Accept and return simple acknowledgment. Pub/sub handler may publish fill asynchronously.
  res.status(202).json({ orderId, symbol, side, qty, status: 'accepted' });
});
app.get('/trade/status/:id', (req, res) => res.json({ id: req.params.id, status: 'pending' }));

// Standardized alias endpoints
app.post('/execute', (req, res) => {
  // alias to /trade/submit
  const { orderId = `${Date.now()}`, symbol = 'BTC-USD', side = 'buy', qty = 1 } = req.body || {};
  res.status(202).json({ orderId, symbol, side, qty, status: 'accepted' });
});
app.post('/optimize', (req, res) => res.status(501).json({ error: 'not_implemented' }));

// Subscribe to exec orders and publish statuses (Streams)
await (async () => {
  // Reconciliation loop: checks for orders without terminal status and emits notify on stale
  const RECONCILE_INTERVAL_MS = parseInt(process.env.EXEC_RECONCILE_INTERVAL_MS || '30000', 10);
  const STALE_AFTER_SEC = parseInt(process.env.EXEC_ORDER_STALE_AFTER_SECONDS || '120', 10);
  setInterval(async () => {
    try {
      // Scan keys: exec:orders:*
      const stream = sub;
      let cursor = '0';
      const now = Date.now();
      do {
        const [next, keys] = await stream.scan(cursor, 'MATCH', 'exec:orders:*', 'COUNT', 100);
        cursor = next;
        for (const key of keys) {
          const orderId = key.split(':').pop();
          const st = await getOrderState(sub, orderId);
          if (!st) continue;
          const recvTs = Date.parse(st.received_ts || '') || 0;
          const ageSec = Math.floor((now - recvTs) / 1000);
          const terminal =
            st.last_status &&
            ['filled', 'failed', 'rejected', 'canceled'].includes(st.last_status.status);
          if (!terminal && recvTs > 0 && ageSec >= STALE_AFTER_SEC) {
            // Emit notify event once and mark as notified
            if (!st.stale_notified) {
              await xaddJSON(pub, CHANNELS.NOTIFY_EVENTS, {
                type: 'exec_order_stale',
                severity: 'warning',
                message: `Order ${orderId} has not reached terminal state after ${ageSec}s`,
                context: { orderId, ageSec },
                ts: new Date().toISOString(),
              });
              await setOrderState(sub, orderId, { stale_notified: '1' });
            }
          }
        }
      } while (cursor !== '0');
    } catch (e) {
      logger.error('reconcile_error', { error: String(e?.message || e) });
    }
  }, RECONCILE_INTERVAL_MS);

  startPendingMonitor({
    redis: sub,
    stream: CHANNELS.EXEC_ORDERS,
    group: 'exec',
    onCount: (c) => streamPendingGauge.set({ stream: CHANNELS.EXEC_ORDERS, group: 'exec' }, c),
  });
  startConsumer({
    redis: sub,
    stream: CHANNELS.EXEC_ORDERS,
    group: 'exec',
    logger,
    idempotency: { redis: sub, keyFn: (p) => p.orderId, ttlSeconds: 86400 },
    dlqStream: `${CHANNELS.EXEC_ORDERS}.dlq`,
    maxFailures: 5,
    handler: async ({ payload: order }) => {
      // Idempotency: if we already have a terminal status, skip
      const state = await getOrderState(sub, order.orderId);
      if (
        state &&
        state.last_status &&
        ['filled', 'failed', 'rejected', 'canceled'].includes(state.last_status.status)
      ) {
        logger.info('order_duplicate_skip', { orderId: order.orderId });
        return;
      }
      await setOrderState(sub, order.orderId, {
        orderId: order.orderId,
        symbol: order.symbol,
        side: order.side,
        qty: order.qty,
        received_ts: new Date().toISOString(),
      });

      setTimeout(async () => {
        let status;
        if (EXCHANGE === 'paper' && adapter) {
          const fill = await adapter.placeOrder({
            orderId: order.orderId,
            symbol: order.symbol,
            side: order.side,
            qty: order.qty,
          });
          const profit = typeof PROFIT_PER_TRADE === 'number' ? PROFIT_PER_TRADE : 0;
          status = {
            orderId: order.orderId,
            status: 'filled',
            symbol: order.symbol,
            side: order.side,
            qty: order.qty,
            profit: profit - (fill.fee || 0),
            fee: fill.fee,
            price: fill.price,
            traceId: order.traceId,
            ts: new Date().toISOString(),
          };
        } else {
          status = {
            orderId: order.orderId,
            status: 'filled',
            symbol: order.symbol,
            side: order.side,
            qty: order.qty,
            profit: PROFIT_PER_TRADE,
            traceId: order.traceId,
            ts: new Date().toISOString(),
          };
        }
        await setOrderState(sub, order.orderId, {
          last_status: status,
          price: status.price || '',
          fee: status.fee || '',
        });
        await xaddJSON(pub, CHANNELS.EXEC_STATUS, status);
      }, 10);
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
