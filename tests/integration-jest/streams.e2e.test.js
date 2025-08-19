/**
 * Jest-based E2E/integration smoke for the full pipeline.
 * Requires docker-compose stack running and ORCH_URL/REDIS_URL envs set.
 * Skips when RUN_DOCKER_TESTS is not truthy.
 */
import axios from 'axios';

const ORCH_URL = process.env.ORCH_URL || 'http://localhost:7001';
const RUN_DOCKER = String(process.env.RUN_DOCKER_TESTS || '').toLowerCase() === 'true';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitForHealth(timeoutMs = 30000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const resp = await axios.get(`${ORCH_URL}/health`, {
        timeout: 2000,
        validateStatus: () => true,
      });
      if (resp.status === 200 && resp.data?.status === 'ok') return true;
    } catch {}
    await sleep(1000);
  }
  throw new Error('orchestrator_not_ready');
}

describe('Streams E2E (Jest wrapper)', () => {
  if (!RUN_DOCKER) {
    it('skipped without RUN_DOCKER_TESTS=true', () => {
      expect(true).toBe(true);
    });
    return;
  }

  jest.setTimeout(60000);

  it('accepts orchestrate/run and returns 202 (HTTP mode)', async () => {
    await waitForHealth(30000);
    const resp = await axios.post(
      `${ORCH_URL}/orchestrate/run`,
      { symbol: 'BTC-USD', mode: 'http' },
      { timeout: 5000, validateStatus: () => true }
    );
    expect(resp.status).toBe(202);
    expect(resp.data?.requestId).toBeDefined();
  });
});
