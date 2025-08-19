// Streams E2E: Orchestrator -> Analyst -> Risk -> Exec pipeline
import axios from 'axios';
import Redis from 'ioredis';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitForExecFilled(requestId, timeoutMs = 20000) {
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
          if (!jsonStr) continue;
          const payload = JSON.parse(jsonStr);
          if (payload?.orderId === requestId && payload?.status === 'filled') {
            return payload;
          }
        }
      } catch {}
      await sleep(500);
    }
  } finally {
    try {
      await redis.quit();
    } catch {}
  }
  throw new Error('Timed out waiting for exec.status filled');
}

async function waitForRiskResponse(requestId, timeoutMs = 10000) {
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

async function main() {
  const ORCH = process.env.ORCH_URL || 'http://orchestrator:7001';

  const run = await axios.post(`${ORCH}/orchestrate/run`, { symbol: 'BTC-USD', mode: 'pubsub' });
  if (run.status >= 300) throw new Error(`Run failed ${run.status}`);
  const requestId = run.data?.requestId;
  if (!requestId) throw new Error('No requestId in run response');

  // Wait for risk response
  const risk = await waitForRiskResponse(requestId, 15000);
  if (risk && risk.ok === false) throw new Error(`Risk rejected: ${risk.reason}`);

  // Wait for filled execution status
  const filled = await waitForExecFilled(requestId, 20000);
  if (filled?.status !== 'filled') throw new Error('Expected filled status');

  console.log('streams e2e ok:', { requestId, risk: risk?.ok, exec: filled?.status });
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
