// Streams E2E rejection: enforce blocked_side via optimizer params
import axios from 'axios';
import Redis from 'ioredis';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitForRiskResponse(requestId, timeoutMs = 15000) {
  const redisUrl = process.env.REDIS_URL || 'redis://redis:6379/0';
  const redis = new Redis(redisUrl);
  const start = Date.now();
  try {
    while (Date.now() - start < timeoutMs) {
      try {
        const entries = await redis.xrevrange('risk.responses', '+', '-', 'COUNT', 100);
        for (const [id, fields] of entries) {
          const idx = fields.findIndex((v, i) => i % 2 === 0 && v === 'data');
          const jsonStr = idx >= 0 ? fields[idx + 1] : null;
          const payload = jsonStr ? JSON.parse(jsonStr) : null;
          if (payload?.requestId === requestId) return payload;
        }
      } catch {}
      await sleep(300);
    }
  } finally {
    try {
      await redis.quit();
    } catch {}
  }
  throw new Error('Timed out waiting for risk.responses');
}

async function sawExecFilled(requestId, timeoutMs = 10000) {
  const redisUrl = process.env.REDIS_URL || 'redis://redis:6379/0';
  const redis = new Redis(redisUrl);
  const start = Date.now();
  try {
    while (Date.now() - start < timeoutMs) {
      try {
        const entries = await redis.xrevrange('exec.status', '+', '-', 'COUNT', 100);
        for (const [id, fields] of entries) {
          const idx = fields.findIndex((v, i) => i % 2 === 0 && v === 'data');
          const jsonStr = idx >= 0 ? fields[idx + 1] : null;
          const payload = jsonStr ? JSON.parse(jsonStr) : null;
          if (payload?.orderId === requestId && payload?.status === 'filled') return true;
        }
      } catch {}
      await sleep(300);
    }
  } finally {
    try {
      await redis.quit();
    } catch {}
  }
  return false;
}

function assert(cond, msg) {
  if (!cond) throw new Error(msg || 'assert failed');
}

async function setParams(params) {
  const redis = new Redis(process.env.REDIS_URL || 'redis://redis:6379/0');
  const toSet = Object.fromEntries(Object.entries(params).map(([k, v]) => [k, String(v)]));
  await redis.hset('optimizer:active_params', toSet);
  await redis.quit();
}

async function main() {
  const ORCH = process.env.ORCH_URL || 'http://orchestrator:7001';

  // Configure to block buy side, keep confidence low threshold and no window restrictions
  await setParams({ minConfidence: 0.1, blockSides: 'buy' });

  const run = await axios.post(`${ORCH}/orchestrate/run`, { symbol: 'BTC-USD', mode: 'pubsub' });
  if (run.status >= 300) throw new Error(`Run failed ${run.status}`);
  const requestId = run.data?.requestId;
  if (!requestId) throw new Error('No requestId in run response');

  const risk = await waitForRiskResponse(requestId, 15000);
  assert(risk.ok === false, 'Expected risk rejection');
  assert(risk.reason === 'blocked_side', `Expected reason blocked_side, got ${risk.reason}`);

  const filled = await sawExecFilled(requestId, 8000);
  assert(filled === false, 'Should not see filled exec when risk rejects');

  console.log('streams rejection e2e ok:', { requestId, reason: risk.reason });
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
