/**
 * Enhanced E2E test for the full trading pipeline
 * Orchestrator -> Analyst -> Risk -> Exec pipeline
 *
 * This enhanced version adds:
 * - More detailed assertions
 * - Error scenario testing
 * - Cleanup after tests
 * - Better logging and diagnostics
 */
import axios from 'axios';
import Redis from 'ioredis';
import { createLogger } from '../../common/logger.js';

const logger = createLogger('streams-e2e-test');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Configuration
const ORCH_URL = process.env.ORCH_URL || 'http://orchestrator:7001';
const REDIS_URL = process.env.REDIS_URL || 'redis://redis:6379/0';
const ADMIN_TOKEN = process.env.ADMIN_TOKEN;
const TEST_SYMBOL = process.env.TEST_SYMBOL || 'BTC-USD';
const TIMEOUT_MS = parseInt(process.env.TEST_TIMEOUT_MS || '30000', 10);

// Redis clients
let redisClient;

/**
 * Wait for a specific message in a stream
 * @param {string} stream - Stream name
 * @param {Function} predicate - Function to check if message matches criteria
 * @param {number} timeoutMs - Timeout in milliseconds
 * @returns {Promise<Object>} - Matching message
 */
async function waitForStreamMessage(stream, predicate, timeoutMs = 10000) {
  const start = Date.now();

  try {
    while (Date.now() - start < timeoutMs) {
      try {
        const entries = await redisClient.xrevrange(stream, '+', '-', 'COUNT', 100);
        for (const [id, fields] of entries) {
          const idx = fields.findIndex((v, i) => i % 2 === 0 && v === 'data');
          const jsonStr = idx >= 0 ? fields[idx + 1] : null;
          if (!jsonStr) continue;

          const payload = JSON.parse(jsonStr);
          if (predicate(payload)) {
            return { id, payload };
          }
        }
      } catch (err) {
        logger.error('stream_read_error', { stream, error: String(err?.message || err) });
      }
      await sleep(300);
    }
  } catch (err) {
    logger.error('wait_error', { stream, error: String(err?.message || err) });
  }

  throw new Error(`Timed out waiting for message in ${stream}`);
}

/**
 * Wait for a risk response for a specific request
 * @param {string} requestId - Request ID to match
 * @param {number} timeoutMs - Timeout in milliseconds
 * @returns {Promise<Object>} - Risk response
 */
async function waitForRiskResponse(requestId, timeoutMs = 10000) {
  return waitForStreamMessage(
    'risk.responses',
    (payload) => payload?.requestId === requestId,
    timeoutMs
  ).then(({ payload }) => payload);
}

/**
 * Wait for an execution status update for a specific order
 * @param {string} orderId - Order ID to match
 * @param {string} status - Status to match (optional)
 * @param {number} timeoutMs - Timeout in milliseconds
 * @returns {Promise<Object>} - Execution status
 */
async function waitForExecStatus(orderId, status = null, timeoutMs = 20000) {
  return waitForStreamMessage(
    'exec.status',
    (payload) => {
      if (payload?.orderId !== orderId) return false;
      return status ? payload?.status === status : true;
    },
    timeoutMs
  ).then(({ payload }) => payload);
}

/**
 * Wait for a notification event of a specific type
 * @param {string} type - Event type to match
 * @param {number} timeoutMs - Timeout in milliseconds
 * @returns {Promise<Object>} - Notification event
 */
async function waitForNotification(type, timeoutMs = 10000) {
  return waitForStreamMessage('notify.events', (payload) => payload?.type === type, timeoutMs).then(
    ({ payload }) => payload
  );
}

/**
 * Reset the test environment
 */
async function resetTestEnvironment() {
  if (ADMIN_TOKEN) {
    try {
      logger.info('resetting_pnl');
      await axios.post(
        `${ORCH_URL}/admin/pnl/reset`,
        {},
        {
          headers: { 'X-Admin-Token': ADMIN_TOKEN },
        }
      );
    } catch (err) {
      logger.warn('pnl_reset_failed', { error: String(err?.message || err) });
    }
  }
}

/**
 * Run a trade through the full pipeline
 * @param {Object} options - Trade options
 * @returns {Promise<Object>} - Test results
 */
async function runTradePipeline(options = {}) {
  const {
    symbol = TEST_SYMBOL,
    mode = 'pubsub',
    side = 'buy',
    confidence = 0.8,
    expectSuccess = true,
  } = options;

  // 1. Submit trade request to orchestrator
  logger.info('submitting_trade', { symbol, mode, side, confidence });
  const runResponse = await axios.post(`${ORCH_URL}/orchestrate/run`, {
    symbol,
    mode,
    side,
    confidence,
  });

  if (runResponse.status >= 300) {
    throw new Error(`Run request failed with status ${runResponse.status}`);
  }

  const requestId = runResponse.data?.requestId;
  if (!requestId) {
    throw new Error('No requestId in run response');
  }

  logger.info('trade_submitted', { requestId });

  // 2. Wait for risk response
  let riskResponse;
  try {
    riskResponse = await waitForRiskResponse(requestId, 15000);
    logger.info('risk_response_received', {
      requestId,
      approved: riskResponse?.ok,
      reason: riskResponse?.reason,
    });
  } catch (err) {
    if (expectSuccess) {
      throw new Error(`Failed to get risk response: ${err.message}`);
    }
    logger.info('no_risk_response_as_expected');
    return { requestId, riskResponse: null, execStatus: null };
  }

  if (expectSuccess && riskResponse?.ok !== true) {
    throw new Error(`Risk rejected unexpectedly: ${riskResponse?.reason}`);
  }

  if (!expectSuccess && riskResponse?.ok === true) {
    throw new Error('Risk approved unexpectedly');
  }

  // If risk rejected as expected, we're done
  if (!expectSuccess && riskResponse?.ok === false) {
    return { requestId, riskResponse, execStatus: null };
  }

  // 3. Wait for execution status
  let execStatus;
  try {
    execStatus = await waitForExecStatus(requestId, 'filled', 20000);
    logger.info('exec_status_received', {
      requestId,
      status: execStatus?.status,
      price: execStatus?.price,
      profit: execStatus?.profit,
    });
  } catch (err) {
    throw new Error(`Failed to get execution status: ${err.message}`);
  }

  if (execStatus?.status !== 'filled') {
    throw new Error(`Expected filled status, got ${execStatus?.status}`);
  }

  return { requestId, riskResponse, execStatus };
}

/**
 * Main test function
 */
async function main() {
  // Setup
  redisClient = new Redis(REDIS_URL);
  redisClient.on('error', (err) =>
    logger.error('redis_error', { error: String(err?.message || err) })
  );

  try {
    // Reset test environment
    await resetTestEnvironment();

    // Test 1: Happy path - successful trade
    logger.info('running_test_1', { description: 'Happy path - successful trade' });
    const test1Result = await runTradePipeline({
      symbol: TEST_SYMBOL,
      mode: 'pubsub',
      side: 'buy',
      confidence: 0.8,
      expectSuccess: true,
    });

    // Test 2: Risk rejection - low confidence
    logger.info('running_test_2', { description: 'Risk rejection - low confidence' });
    const test2Result = await runTradePipeline({
      symbol: TEST_SYMBOL,
      mode: 'pubsub',
      side: 'buy',
      confidence: 0.3, // Below threshold
      expectSuccess: false,
    });

    // Test 3: Different symbol
    logger.info('running_test_3', { description: 'Different symbol' });
    const test3Result = await runTradePipeline({
      symbol: 'ETH-USD',
      mode: 'pubsub',
      side: 'buy',
      confidence: 0.8,
      expectSuccess: true,
    });

    // Test 4: Sell side
    logger.info('running_test_4', { description: 'Sell side' });
    const test4Result = await runTradePipeline({
      symbol: TEST_SYMBOL,
      mode: 'pubsub',
      side: 'sell',
      confidence: 0.8,
      expectSuccess: true,
    });

    // All tests passed
    logger.info('all_tests_passed', {
      test1: { requestId: test1Result.requestId },
      test2: { requestId: test2Result.requestId },
      test3: { requestId: test3Result.requestId },
      test4: { requestId: test4Result.requestId },
    });

    console.log('✅ Enhanced streams E2E tests: ALL PASSED');
  } catch (err) {
    logger.error('test_failed', { error: String(err?.message || err) });
    console.error('❌ Enhanced streams E2E tests failed:', err.message);
    process.exit(1);
  } finally {
    // Cleanup
    try {
      await redisClient.quit();
    } catch (err) {
      logger.error('redis_quit_error', { error: String(err?.message || err) });
    }
  }
}

// Run the tests
main().catch((err) => {
  console.error('Unhandled error:', err);
  process.exit(1);
});
