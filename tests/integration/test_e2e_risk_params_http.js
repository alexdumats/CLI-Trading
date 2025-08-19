import axios from 'axios';
import Redis from 'ioredis';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitForHealth(url, timeoutMs = 20000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const res = await axios.get(`${url}/health`);
      if (res.status === 200 && res.data?.status === 'ok') return true;
    } catch {}
    await sleep(500);
  }
  throw new Error(`Service not healthy: ${url}`);
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
  const RISK = process.env.RISK_URL || 'http://risk-manager:7004';
  const OPT = process.env.OPT_URL || 'http://parameter-optimizer:7007';

  await waitForHealth(RISK);
  await waitForHealth(OPT);

  // Case 1: outside trading window should reject
  const now = new Date();
  const curH = now.getUTCHours();
  const start = (curH + 2) % 24;
  const end = (curH + 3) % 24;
  await setParams({
    minConfidence: 0.5,
    tradingStartHour: start,
    tradingEndHour: end,
    blockSides: '',
  });
  let res = await axios.post(`${RISK}/risk/evaluate`, { confidence: 0.9, side: 'buy' });
  assert(
    res.data?.ok === false && res.data?.reason === 'outside_window',
    'expected outside_window rejection'
  );

  // Case 2: blocked side should reject
  await setParams({ minConfidence: 0.5, blockSides: 'sell' });
  res = await axios.post(`${RISK}/risk/evaluate`, { confidence: 0.9, side: 'sell' });
  assert(
    res.data?.ok === false && res.data?.reason === 'blocked_side',
    'expected blocked_side rejection'
  );

  // Case 3: low confidence should reject
  await setParams({ minConfidence: 0.6, blockSides: '' });
  res = await axios.post(`${RISK}/risk/evaluate`, { confidence: 0.55, side: 'buy' });
  assert(
    res.data?.ok === false && res.data?.reason === 'low_confidence',
    'expected low_confidence rejection'
  );

  // Case 4: accept within window, unblocked, above threshold
  await setParams({ minConfidence: 0.6, tradingStartHour: '', tradingEndHour: '', blockSides: '' });
  res = await axios.post(`${RISK}/risk/evaluate`, { confidence: 0.7, side: 'buy' });
  assert(res.data?.ok === true, 'expected acceptance');

  // Optimizer params endpoint should reflect deployed params
  const opt = await axios.get(`${OPT}/optimize/params`);
  assert(typeof opt.data?.params === 'object', 'optimizer params object');

  console.log('E2E risk params over HTTP: OK');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
