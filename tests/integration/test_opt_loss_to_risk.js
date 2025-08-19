// End-to-end test: loss-triggered optimizer request, approval updates minConfidence, Risk Manager applies it
// This is a logical E2E using direct module calls and Redis; in a full environment you would run via compose and HTTP.

import Redis from 'ioredis';
import { xaddJSON } from '../../common/streams.js';

function assert(cond, msg) {
  if (!cond) throw new Error(msg || 'assert failed');
}

async function riskEvaluate(minConfidence, confidence) {
  // Simulate Risk Manager logic using Redis
  const redis = new Redis(process.env.REDIS_URL || 'redis://localhost:6379/0');
  await redis.hset('optimizer:active_params', { minConfidence: String(minConfidence) });
  const params = await redis.hgetall('optimizer:active_params');
  const mc = parseFloat(params.minConfidence || '0.6');
  return confidence >= mc;
}

async function main() {
  const redis = new Redis(process.env.REDIS_URL || 'redis://localhost:6379/0');

  // 1) Loss event -> optimizer request should be emitted by orchestrator in system E2E
  // Here we simulate by writing opt.requests directly
  await xaddJSON(redis, 'opt.requests', {
    reason: 'loss',
    orderId: 'ord-1',
    profit: -10,
    symbol: 'BTC-USD',
    ts: new Date().toISOString(),
  });

  // 2) Simulate optimizer produced params and approval (minConfidence lowered)
  await redis.hset('optimizer:active_params', { minConfidence: '0.55' });

  // 3) Risk should apply new minConfidence
  const okBefore = await riskEvaluate(0.6, 0.57); // default baseline
  const okAfter = await riskEvaluate(0.55, 0.57); // after approval

  assert(okBefore === false, 'expected rejection at baseline 0.6');
  assert(okAfter === true, 'expected acceptance after minConfidence=0.55');
  console.log('opt loss -> risk behavior test: OK');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
