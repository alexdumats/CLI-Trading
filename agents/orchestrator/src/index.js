import express from 'express';
import Redis from 'ioredis';
import client from 'prom-client';
import crypto from 'crypto';
import axios from 'axios';
import fs from 'node:fs';
import { createLogger } from '../../../common/logger.js';
import { traceMiddleware, requestLoggerMiddleware } from '../../../common/trace.js';
import { initDayIfNeeded, getStatus as getPnlStatus, incrementPnl, isHalted, setHalted, resetDay } from '../../../common/pnl.js';
import { createPgPool, insertAudit, upsertPnl } from '../../../common/db.js';
import { xaddJSON, startConsumer, startPendingMonitor } from '../../../common/streams.js';

// Allow ADMIN_TOKEN to be supplied via file for secrets handling
if (process.env.ADMIN_TOKEN_FILE && !process.env.ADMIN_TOKEN) {
  try { process.env.ADMIN_TOKEN = fs.readFileSync(process.env.ADMIN_TOKEN_FILE, 'utf8').trim(); } catch {}
}

const SERVICE_NAME = process.env.SERVICE_NAME || 'Claude Orchestrator';
const PORT = parseInt(process.env.PORT || '7001', 10);
const REDIS_URL = process.env.REDIS_URL || 'redis://localhost:6379/0';
const COMM_MODE = (process.env.COMM_MODE || 'pubsub').toLowerCase(); // 'pubsub' | 'http' | 'hybrid'
const START_EQUITY = parseFloat(process.env.START_EQUITY || '1000');
const DAILY_TARGET_PCT = parseFloat(process.env.DAILY_TARGET_PCT || '1');
const STREAM_IDEMP_TTL_SECONDS = parseInt(process.env.STREAM_IDEMP_TTL_SECONDS || '86400', 10);
const STREAM_MAX_FAILURES = parseInt(process.env.STREAM_MAX_FAILURES || '5', 10);

// HTTP targets (Docker service names on backend network)
const MARKET_ANALYST_URL = process.env.MARKET_ANALYST_URL || 'http://market-analyst:7003';
const RISK_MANAGER_URL = process.env.RISK_MANAGER_URL || 'http://risk-manager:7004';
const TRADE_EXECUTOR_URL = process.env.TRADE_EXECUTOR_URL || 'http://trade-executor:7005';
const NOTIFICATION_MANAGER_URL = process.env.NOTIFICATION_MANAGER_URL || 'http://notification-manager:7006';

const http = axios.create({ timeout: 5000, validateStatus: () => true });

// Redis (pub/sub pattern uses separate connections)
const pub = new Redis(REDIS_URL);
const sub = new Redis(REDIS_URL);
const kv = new Redis(REDIS_URL);
pub.on('error', (err) => console.error(`[${SERVICE_NAME}] Redis pub error:`, err.message));
sub.on('error', (err) => console.error(`[${SERVICE_NAME}] Redis sub error:`, err.message));

// replace console in this module with logger wrappers for consistency
const log = {
  info: (msg, extra) => logger.info(msg, extra),
  error: (msg, extra) => logger.error(msg, extra),
};

// Channels
const CHANNELS = {
  ORCH_CMDS: 'orchestrator.commands',
  ANALYSIS_SIGNALS: 'analysis.signals',
  RISK_REQUESTS: 'risk.requests',
  RISK_RESPONSES: 'risk.responses',
  EXEC_ORDERS: 'exec.orders',
  EXEC_STATUS: 'exec.status',
  NOTIFY_EVENTS: 'notify.events'
};

// In-memory tracking of requests
const pending = new Map(); // requestId -> {symbol, side, confidence}

const app = express();
const logger = createLogger(SERVICE_NAME);
const pgPool = createPgPool();
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
  let dbStatus = 'unknown';
  try {
    await pub.ping(); await sub.ping(); await kv.ping();
    await initDayIfNeeded(kv, { startEquity: START_EQUITY, dailyTargetPct: DAILY_TARGET_PCT });
    redisStatus = 'ok';
  } catch {
    redisStatus = 'error';
  }
  try {
    await pgPool.query('select 1');
    dbStatus = 'ok';
  } catch {
    dbStatus = 'error';
  }
  const pnl = await getPnlStatus(kv);
  res.json({ status: 'ok', service: SERVICE_NAME, redis: redisStatus, db: dbStatus, pnl, uptime: process.uptime(), ts: new Date().toISOString() });
});

// Metrics
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

// PnL endpoints
app.get('/pnl/status', async (req, res) => {
  await initDayIfNeeded(kv, { startEquity: START_EQUITY, dailyTargetPct: DAILY_TARGET_PCT });
  const pnl = await getPnlStatus(kv);
  res.json(pnl);
});

app.post('/admin/pnl/reset', async (req, res) => {
  const token = req.header('x-admin-token') || '';
  if (!process.env.ADMIN_TOKEN || token !== process.env.ADMIN_TOKEN) {
    return res.status(401).json({ error: 'unauthorized' });
  }
  const pnl = await resetDay(kv, { startEquity: START_EQUITY, dailyTargetPct: DAILY_TARGET_PCT });
  res.json({ ok: true, pnl });
});

// Admin Streams Ops
app.get('/admin/streams/pending', async (req, res) => {
  const token = req.header('x-admin-token') || '';
  if (!process.env.ADMIN_TOKEN || token !== process.env.ADMIN_TOKEN) return res.status(401).json({ error: 'unauthorized' });
  const { stream, group } = req.query;
  if (!stream || !group) return res.status(400).json({ error: 'missing_stream_or_group' });
  try {
    const summary = await sub.xpending(stream, group);
    return res.json({ stream, group, summary });
  } catch (e) {
    return res.status(500).json({ error: 'xpending_failed', detail: String(e?.message || e) });
  }
});

app.get('/admin/streams/dlq', async (req, res) => {
  const token = req.header('x-admin-token') || '';
  if (!process.env.ADMIN_TOKEN || token !== process.env.ADMIN_TOKEN) return res.status(401).json({ error: 'unauthorized' });
  const { stream, start = '-', end = '+', count = '50' } = req.query;
  if (!stream) return res.status(400).json({ error: 'missing_stream' });
  try {
    const entries = await sub.xrange(stream, start, end, 'COUNT', parseInt(count, 10));
    const result = entries.map(([id, fields]) => {
      const idx = fields.findIndex((v, i) => i % 2 === 0 && v === 'data');
      const jsonStr = idx >= 0 ? fields[idx + 1] : null;
      return { id, payload: jsonStr ? JSON.parse(jsonStr) : null };
    });
    return res.json({ stream, entries: result });
  } catch (e) {
    return res.status(500).json({ error: 'xrange_failed', detail: String(e?.message || e) });
  }
});

app.post('/admin/streams/dlq/requeue', async (req, res) => {
  const token = req.header('x-admin-token') || '';
  if (!process.env.ADMIN_TOKEN || token !== process.env.ADMIN_TOKEN) return res.status(401).json({ error: 'unauthorized' });
  const { dlqStream, id } = req.body || {};
  if (!dlqStream || !id) return res.status(400).json({ error: 'missing_dlq_or_id' });
  try {
    const entries = await sub.xrange(dlqStream, id, id);
    if (!entries || entries.length === 0) return res.status(404).json({ error: 'not_found' });
    const fields = entries[0][1];
    const idx = fields.findIndex((v, i) => i % 2 === 0 && v === 'data');
    const jsonStr = idx >= 0 ? fields[idx + 1] : null;
    if (!jsonStr) return res.status(400).json({ error: 'invalid_payload' });
    const payload = JSON.parse(jsonStr);
    const { originalStream, payload: originalPayload } = payload || {};
    if (!originalStream || !originalPayload) return res.status(400).json({ error: 'invalid_dlq_format' });
    await xaddJSON(sub, originalStream, originalPayload);
    await sub.xdel(dlqStream, id);
    return res.json({ ok: true });
  } catch (e) {
    return res.status(500).json({ error: 'requeue_failed', detail: String(e?.message || e) });
  }
});

// Orchestration endpoints
// Admin: manual halt/unhalt
app.post('/admin/orchestrate/halt', async (req, res) => {
  const token = req.header('x-admin-token') || '';
  if (!process.env.ADMIN_TOKEN || token !== process.env.ADMIN_TOKEN) return res.status(401).json({ error: 'unauthorized' });
  await setHalted(kv, true);
  const reason = (req.body && req.body.reason) || 'manual';
  await xaddJSON(pub, CHANNELS.ORCH_CMDS, { type: 'halt', reason, ts: new Date().toISOString(), traceId: req.ids?.traceId });
  await xaddJSON(pub, CHANNELS.NOTIFY_EVENTS, { type: 'manual_halt', severity: 'warning', message: 'Orchestrator manually halted', context: { reason }, traceId: req.ids?.traceId, ts: new Date().toISOString() });
  res.json({ ok: true, halted: true });
});

app.post('/admin/orchestrate/unhalt', async (req, res) => {
  const token = req.header('x-admin-token') || '';
  if (!process.env.ADMIN_TOKEN || token !== process.env.ADMIN_TOKEN) return res.status(401).json({ error: 'unauthorized' });
  await setHalted(kv, false);
  await xaddJSON(pub, CHANNELS.NOTIFY_EVENTS, { type: 'manual_unhalt', severity: 'info', message: 'Orchestrator manually unhalted', traceId: req.ids?.traceId, ts: new Date().toISOString() });
  res.json({ ok: true, halted: false });
});

// Orchestration endpoints
app.post('/orchestrate/run', async (req, res) => {
  await initDayIfNeeded(kv, { startEquity: START_EQUITY, dailyTargetPct: DAILY_TARGET_PCT });
  if (await isHalted(kv)) {
    const pnl = await getPnlStatus(kv);
    return res.status(409).json({ error: 'halted', reason: 'daily_target_reached', pnl });
  }
  const symbol = (req.body && req.body.symbol) || 'BTC-USD';
  const mode = ((req.body && req.body.mode) || COMM_MODE).toLowerCase();
  const requestId = req.ids?.requestId || `${Date.now()}-${crypto.randomBytes(3).toString('hex')}`;
  const traceId = req.ids?.traceId || crypto.randomUUID();

  // audit accepted run request
  try { await insertAudit(pgPool, { type: 'orchestrate_run', severity: 'info', payload: { symbol, mode }, requestId, traceId }); } catch {}
  if (mode === 'http' || mode === 'hybrid') {
    // HTTP pipeline: analyst -> risk -> exec
    try {
      const analyzeResp = await http.post(`${MARKET_ANALYST_URL}/analysis/analyze`, { symbol, requestId }, { headers: { 'X-Request-Id': requestId, 'X-Trace-Id': traceId } });
      if (analyzeResp.status >= 300) throw new Error(`analyze status ${analyzeResp.status}`);
      const signal = analyzeResp.data || {};

      const riskResp = await http.post(`${RISK_MANAGER_URL}/risk/evaluate`, {
        requestId, symbol, side: signal.side || 'buy', confidence: signal.confidence ?? 0
      }, { headers: { 'X-Request-Id': requestId, 'X-Trace-Id': traceId } });
      if (riskResp.status >= 300) throw new Error(`risk status ${riskResp.status}`);
      const risk = riskResp.data || {};

      if (risk.ok) {
        // Check halt again just before submission
        if (await isHalted(kv)) {
          const pnl = await getPnlStatus(kv);
          return res.status(409).json({ error: 'halted', reason: 'daily_target_reached', pnl });
        }
        const order = { orderId: requestId, symbol, side: signal.side || 'buy', qty: 1 };
        try { await insertAudit(pgPool, { type: 'order_submitted', severity: 'info', payload: order, requestId, traceId }); } catch {}
        const execResp = await http.post(`${TRADE_EXECUTOR_URL}/trade/submit`, order, { headers: { 'X-Request-Id': requestId, 'X-Trace-Id': traceId } });
        if (execResp.status >= 300) throw new Error(`exec status ${execResp.status}`);
        const trade = execResp.data || {};
        return res.status(202).json({ status: 'accepted', mode: 'http', requestId, signal, risk, trade });
      } else {
        // notify on rejection
        await http.post(`${NOTIFICATION_MANAGER_URL}/notify`, {
          type: 'risk_rejected', severity: 'info', message: 'Trade rejected by risk', context: { requestId, symbol, reason: risk.reason }
        }, { headers: { 'X-Request-Id': requestId, 'X-Trace-Id': traceId } }).catch(() => {});
        try { await insertAudit(pgPool, { type: 'risk_rejected', severity: 'warning', payload: { reason: risk.reason, symbol }, requestId, traceId }); } catch {}
        return res.status(202).json({ status: 'rejected', mode: 'http', requestId, reason: risk.reason || 'risk' });
      }
    } catch (e) {
      try { await insertAudit(pgPool, { type: 'http_pipeline_error', severity: 'error', payload: { error: String(e.message || e) }, requestId, traceId }); } catch {}
      log.error('http_pipeline_error', { error: String(e.message || e), requestId, traceId });
      return res.status(502).json({ error: 'pipeline_failed', detail: String(e.message || e) });
    }
  } else {
    // Pub/Sub pipeline
    const cmd = { type: 'analyze', requestId, symbol, traceId, ts: new Date().toISOString() };
    await xaddJSON(pub, CHANNELS.ORCH_CMDS, cmd);
    return res.status(202).json({ status: 'accepted', mode: 'pubsub', action: 'run', requestId, symbol });
  }
});

app.post('/orchestrate/stop', async (req, res) => {
  const cmd = { type: 'halt', ts: new Date().toISOString() };
  await pub.publish(CHANNELS.ORCH_CMDS, JSON.stringify(cmd));
  res.status(202).json({ status: 'accepted', action: 'stop' });
});

// Subscriptions: handle signals -> risk -> exec (Streams)
await (async () => {
  const DLQ = {
    ANALYSIS_SIGNALS: `${CHANNELS.ANALYSIS_SIGNALS}.dlq`,
    RISK_RESPONSES: `${CHANNELS.RISK_RESPONSES}.dlq`,
    EXEC_STATUS: `${CHANNELS.EXEC_STATUS}.dlq`,
  };
  // Pending monitors
  startPendingMonitor({ redis: sub, stream: CHANNELS.ANALYSIS_SIGNALS, group: 'orchestrator', onCount: (c)=> streamPendingGauge.set({stream: CHANNELS.ANALYSIS_SIGNALS, group: 'orchestrator'}, c) });
  startPendingMonitor({ redis: sub, stream: CHANNELS.RISK_RESPONSES, group: 'orchestrator', onCount: (c)=> streamPendingGauge.set({stream: CHANNELS.RISK_RESPONSES, group: 'orchestrator'}, c) });
  startPendingMonitor({ redis: sub, stream: CHANNELS.EXEC_STATUS, group: 'orchestrator', onCount: (c)=> streamPendingGauge.set({stream: CHANNELS.EXEC_STATUS, group: 'orchestrator'}, c) });
  const stopSig = startConsumer({ redis: sub, stream: CHANNELS.ANALYSIS_SIGNALS, group: 'orchestrator', logger, idempotency: { redis: kv, keyFn: (p)=>p.requestId, ttlSeconds: STREAM_IDEMP_TTL_SECONDS }, dlqStream: DLQ.ANALYSIS_SIGNALS, maxFailures: STREAM_MAX_FAILURES, handler: async ({ id, payload: msg }) => {
      // ANALYSIS_SIGNALS
      try {
        const requestId = msg.id || msg.requestId || `${Date.now()}-${Math.random()}`;
        pending.set(requestId, { symbol: msg.symbol, side: msg.side, confidence: msg.confidence });
        const riskReq = { requestId, symbol: msg.symbol, side: msg.side, confidence: msg.confidence, traceId: msg.traceId, ts: new Date().toISOString() };
        await xaddJSON(pub, CHANNELS.RISK_REQUESTS, riskReq);
      } catch (e) { logger.error('analysis_signal_handler_error', { error: String(e?.message || e) }); }
    } });

  const stopRisk = startConsumer({ redis: sub, stream: CHANNELS.RISK_RESPONSES, group: 'orchestrator', logger, idempotency: { redis: kv, keyFn: (p)=>p.requestId, ttlSeconds: STREAM_IDEMP_TTL_SECONDS }, dlqStream: DLQ.RISK_RESPONSES, maxFailures: STREAM_MAX_FAILURES, handler: async ({ id, payload: msg }) => {
      try {
        const { requestId, ok } = msg;
        const p = pending.get(requestId);
        if (p) {
          pending.delete(requestId);
          if (ok) {
            const order = { orderId: requestId, symbol: p.symbol, side: p.side || 'buy', qty: 1, traceId: msg.traceId, ts: new Date().toISOString() };
            await xaddJSON(pub, CHANNELS.EXEC_ORDERS, order);
          } else {
            await xaddJSON(pub, CHANNELS.NOTIFY_EVENTS, {
              type: 'risk_rejected', severity: 'info', message: 'Trade rejected by risk', context: msg, traceId: msg.traceId, ts: new Date().toISOString()
            });
          }
        }
      } catch (e) { logger.error('risk_response_handler_error', { error: String(e?.message || e) }); }
    } });

  const stopExec = startConsumer({ redis: sub, stream: CHANNELS.EXEC_STATUS, group: 'orchestrator', logger, idempotency: { redis: kv, keyFn: (p)=>p.orderId, ttlSeconds: STREAM_IDEMP_TTL_SECONDS }, dlqStream: DLQ.EXEC_STATUS, maxFailures: STREAM_MAX_FAILURES, handler: async ({ id, payload: msg }) => {
      try {
        if (msg.status === 'filled') {
          const profit = parseFloat(msg.profit || '0');
          try { await insertAudit(pgPool, { type: 'order_filled', severity: 'info', payload: msg, requestId: msg.orderId, traceId: msg.traceId }); } catch {}
          const status = await incrementPnl(kv, profit);
          try { await upsertPnl(pgPool, status); } catch {}
          if (!status.halted && status.percent >= status.dailyTargetPct) {
            await setHalted(kv, true);
            try { await insertAudit(pgPool, { type: 'daily_target_reached', severity: 'info', payload: status, requestId: msg.orderId, traceId: msg.traceId }); } catch {}
            await xaddJSON(pub, CHANNELS.ORCH_CMDS, { type: 'halt', reason: 'daily_target_reached', ts: new Date().toISOString(), traceId: msg.traceId });
            await xaddJSON(pub, CHANNELS.NOTIFY_EVENTS, { type: 'daily_target_reached', severity: 'info', context: status, traceId: msg.traceId, ts: new Date().toISOString() });
          }
        }
      } catch (e) { logger.error('exec_status_handler_error', { error: String(e?.message || e) }); }
    } });
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
  try { await kv.quit(); } catch {}
  try { await pgPool.end(); } catch {}
  process.exit(0);
};
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
