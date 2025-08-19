/**
 * Performance and load testing for the trading system
 *
 * This script uses a simple approach to generate load and measure performance.
 * For more advanced load testing, consider using k6 or similar tools.
 *
 * Usage:
 *   node tests/performance/load-test.js
 *
 * Environment variables:
 *   - ORCH_URL: Orchestrator URL (default: http://localhost:7001)
 *   - TEST_DURATION_SEC: Test duration in seconds (default: 60)
 *   - REQUESTS_PER_SEC: Target requests per second (default: 5)
 *   - CONCURRENT_USERS: Number of concurrent users (default: 10)
 *   - TEST_SYMBOL: Symbol to use for trades (default: BTC-USD)
 */
import axios from 'axios';
import Redis from 'ioredis';
import { createLogger } from '../../common/logger.js';

// Configuration
const ORCH_URL = process.env.ORCH_URL || 'http://localhost:7001';
const REDIS_URL = process.env.REDIS_URL || 'redis://localhost:6379/0';
const TEST_DURATION_SEC = parseInt(process.env.TEST_DURATION_SEC || '60', 10);
const REQUESTS_PER_SEC = parseInt(process.env.REQUESTS_PER_SEC || '5', 10);
const CONCURRENT_USERS = parseInt(process.env.CONCURRENT_USERS || '10', 10);
const TEST_SYMBOL = process.env.TEST_SYMBOL || 'BTC-USD';

// Create logger
const logger = createLogger('load-test');

// Metrics
const metrics = {
  totalRequests: 0,
  successfulRequests: 0,
  failedRequests: 0,
  responseTimes: [],
  errors: {},
  startTime: 0,
  endTime: 0,

  // Stream metrics
  riskApproved: 0,
  riskRejected: 0,
  executionFilled: 0,
  executionFailed: 0,

  // Calculate statistics
  getStats() {
    const totalDurationMs = this.endTime - this.startTime;
    const totalDurationSec = totalDurationMs / 1000;

    // Sort response times for percentile calculations
    const sortedTimes = [...this.responseTimes].sort((a, b) => a - b);
    const p50Index = Math.floor(sortedTimes.length * 0.5);
    const p95Index = Math.floor(sortedTimes.length * 0.95);
    const p99Index = Math.floor(sortedTimes.length * 0.99);

    return {
      totalRequests: this.totalRequests,
      successRate: (this.successfulRequests / this.totalRequests) * 100,
      requestsPerSecond: this.totalRequests / totalDurationSec,
      avgResponseTime:
        this.responseTimes.reduce((sum, time) => sum + time, 0) / this.responseTimes.length,
      minResponseTime: Math.min(...this.responseTimes),
      maxResponseTime: Math.max(...this.responseTimes),
      p50ResponseTime: sortedTimes[p50Index] || 0,
      p95ResponseTime: sortedTimes[p95Index] || 0,
      p99ResponseTime: sortedTimes[p99Index] || 0,
      errorCount: this.failedRequests,
      errorRate: (this.failedRequests / this.totalRequests) * 100,
      topErrors: Object.entries(this.errors)
        .sort((a, b) => b[1] - a[1])
        .slice(0, 5)
        .map(([error, count]) => ({ error, count })),
      riskApproved: this.riskApproved,
      riskRejected: this.riskRejected,
      executionFilled: this.executionFilled,
      executionFailed: this.executionFailed,
      riskApprovalRate: (this.riskApproved / (this.riskApproved + this.riskRejected)) * 100,
      executionSuccessRate:
        (this.executionFilled / (this.executionFilled + this.executionFailed)) * 100,
    };
  },
};

/**
 * Send a trade request and measure response time
 * @param {number} userId - User ID for tracking
 * @returns {Promise<Object>} - Response data
 */
async function sendTradeRequest(userId) {
  const startTime = Date.now();
  metrics.totalRequests++;

  try {
    // Generate random values for the request
    const side = Math.random() > 0.5 ? 'buy' : 'sell';
    const confidence = 0.5 + Math.random() * 0.5; // 0.5 to 1.0
    const qty = 0.1 + Math.random() * 0.9; // 0.1 to 1.0

    // Send the request
    const response = await axios.post(`${ORCH_URL}/orchestrate/run`, {
      symbol: TEST_SYMBOL,
      mode: 'http',
      side,
      confidence,
      qty,
      userId: `load-test-user-${userId}`,
    });

    // Record metrics
    const responseTime = Date.now() - startTime;
    metrics.successfulRequests++;
    metrics.responseTimes.push(responseTime);

    return response.data;
  } catch (error) {
    metrics.failedRequests++;

    // Track error types
    const errorMessage = error.response?.data?.error || error.message;
    metrics.errors[errorMessage] = (metrics.errors[errorMessage] || 0) + 1;

    logger.error('request_failed', {
      userId,
      error: errorMessage,
      status: error.response?.status,
    });

    return null;
  }
}

/**
 * Monitor Redis streams for events
 */
async function monitorStreams() {
  const redis = new Redis(REDIS_URL);
  redis.on('error', (err) => logger.error('redis_error', { error: String(err?.message || err) }));

  // Start time for ID filtering
  const startTimeMs = Date.now();
  const startId = `${Math.floor(startTimeMs / 1000)}-0`;

  // Set up interval to check streams
  const interval = setInterval(async () => {
    try {
      // Check risk responses
      const riskResponses = await redis.xrange('risk.responses', startId, '+', 'COUNT', 1000);
      for (const [id, fields] of riskResponses) {
        const idx = fields.findIndex((v, i) => i % 2 === 0 && v === 'data');
        const jsonStr = idx >= 0 ? fields[idx + 1] : null;
        if (!jsonStr) continue;

        const payload = JSON.parse(jsonStr);
        if (payload.ok === true) {
          metrics.riskApproved++;
        } else {
          metrics.riskRejected++;
        }
      }

      // Check execution statuses
      const execStatuses = await redis.xrange('exec.status', startId, '+', 'COUNT', 1000);
      for (const [id, fields] of execStatuses) {
        const idx = fields.findIndex((v, i) => i % 2 === 0 && v === 'data');
        const jsonStr = idx >= 0 ? fields[idx + 1] : null;
        if (!jsonStr) continue;

        const payload = JSON.parse(jsonStr);
        if (payload.status === 'filled') {
          metrics.executionFilled++;
        } else if (['failed', 'rejected', 'canceled'].includes(payload.status)) {
          metrics.executionFailed++;
        }
      }

      // Update the start ID to avoid re-processing messages
      if (riskResponses.length > 0) {
        const lastId = riskResponses[riskResponses.length - 1][0];
        startId = lastId;
      } else if (execStatuses.length > 0) {
        const lastId = execStatuses[execStatuses.length - 1][0];
        startId = lastId;
      }
    } catch (err) {
      logger.error('stream_monitor_error', { error: String(err?.message || err) });
    }
  }, 1000);

  // Return cleanup function
  return () => {
    clearInterval(interval);
    redis.quit().catch(() => {});
  };
}

/**
 * Run a virtual user that sends requests at a specified rate
 * @param {number} userId - User ID
 * @param {number} requestsPerSec - Requests per second
 * @param {number} durationSec - Test duration in seconds
 */
async function runVirtualUser(userId, requestsPerSec, durationSec) {
  const intervalMs = 1000 / requestsPerSec;
  const endTime = Date.now() + durationSec * 1000;

  logger.info('virtual_user_started', { userId, requestsPerSec, durationSec });

  while (Date.now() < endTime) {
    const startTime = Date.now();

    // Send request
    await sendTradeRequest(userId);

    // Calculate time to wait for next request
    const elapsedMs = Date.now() - startTime;
    const waitMs = Math.max(0, intervalMs - elapsedMs);

    if (waitMs > 0) {
      await new Promise((resolve) => setTimeout(resolve, waitMs));
    }
  }

  logger.info('virtual_user_completed', { userId });
}

/**
 * Run the load test
 */
async function runLoadTest() {
  console.log(`
=================================================
  TRADING SYSTEM LOAD TEST
=================================================
Duration: ${TEST_DURATION_SEC} seconds
Target RPS: ${REQUESTS_PER_SEC}
Concurrent Users: ${CONCURRENT_USERS}
Target Symbol: ${TEST_SYMBOL}
=================================================
  `);

  // Start monitoring streams
  const stopMonitoring = await monitorStreams();

  // Record start time
  metrics.startTime = Date.now();

  // Calculate requests per second per user
  const rpsPerUser = REQUESTS_PER_SEC / CONCURRENT_USERS;

  // Start virtual users
  const userPromises = [];
  for (let i = 0; i < CONCURRENT_USERS; i++) {
    userPromises.push(runVirtualUser(i + 1, rpsPerUser, TEST_DURATION_SEC));
  }

  // Wait for all users to complete
  await Promise.all(userPromises);

  // Record end time
  metrics.endTime = Date.now();

  // Stop monitoring
  stopMonitoring();

  // Calculate and display results
  const stats = metrics.getStats();

  console.log(`
=================================================
  LOAD TEST RESULTS
=================================================
Total Requests: ${stats.totalRequests}
Success Rate: ${stats.successRate.toFixed(2)}%
Requests/sec: ${stats.requestsPerSecond.toFixed(2)}

Response Times (ms):
  Average: ${stats.avgResponseTime.toFixed(2)}
  Min: ${stats.minResponseTime}
  Max: ${stats.maxResponseTime}
  P50: ${stats.p50ResponseTime}
  P95: ${stats.p95ResponseTime}
  P99: ${stats.p99ResponseTime}

Errors:
  Count: ${stats.errorCount}
  Rate: ${stats.errorRate.toFixed(2)}%
  Top Errors: ${JSON.stringify(stats.topErrors, null, 2)}

Risk Manager:
  Approved: ${stats.riskApproved}
  Rejected: ${stats.riskRejected}
  Approval Rate: ${stats.riskApprovalRate.toFixed(2)}%

Execution:
  Filled: ${stats.executionFilled}
  Failed: ${stats.executionFailed}
  Success Rate: ${stats.executionSuccessRate.toFixed(2)}%
=================================================
  `);
}

// Run the load test
runLoadTest().catch((err) => {
  logger.error('load_test_failed', { error: String(err?.message || err) });
  console.error('Load test failed:', err);
  process.exit(1);
});
