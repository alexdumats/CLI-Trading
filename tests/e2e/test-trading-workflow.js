/**
 * End-to-End Trading Workflow Tests
 *
 * This test suite validates complete trading workflows including:
 * - Market analysis signal generation
 * - Risk evaluation and approval
 * - Trade execution and status tracking
 * - Notification and audit flows
 * - Parameter optimization triggers
 *
 * Usage: npm run test:e2e
 */

import axios from 'axios';
import Redis from 'ioredis';
import crypto from 'crypto';
import { jest } from '@jest/globals';

// Test configuration
const CONFIG = {
  agents: {
    orchestrator: 'http://localhost:7001',
    marketAnalyst: 'http://localhost:7003',
    riskManager: 'http://localhost:7004',
    tradeExecutor: 'http://localhost:7005',
    notificationManager: 'http://localhost:7006',
    parameterOptimizer: 'http://localhost:7007',
    mcpHubController: 'http://localhost:7008',
  },
  redis: {
    url: process.env.REDIS_URL || 'redis://localhost:6379/0',
  },
  timeouts: {
    api: 10000,
    workflow: 30000,
    longRunning: 60000,
  },
  test: {
    symbol: 'BTC-USD',
    testEquity: 1000,
    maxOrderSize: 100,
  },
};

// Test utilities
class TestUtils {
  constructor() {
    this.redis = new Redis(CONFIG.redis.url);
    this.adminToken = process.env.ADMIN_TOKEN || 'test-admin-token';
    this.testTraceId = null;
  }

  generateTraceId() {
    this.testTraceId = `test-${crypto.randomUUID()}`;
    return this.testTraceId;
  }

  async makeRequest(url, options = {}) {
    const defaultOptions = {
      timeout: CONFIG.timeouts.api,
      headers: {
        'Content-Type': 'application/json',
        'X-Admin-Token': this.adminToken,
        ...options.headers,
      },
    };

    try {
      const response = await axios({
        url,
        ...defaultOptions,
        ...options,
      });
      return response;
    } catch (error) {
      if (error.response) {
        return error.response;
      }
      throw error;
    }
  }

  async waitForStreamMessage(streamName, timeout = 10000) {
    const startTime = Date.now();

    while (Date.now() - startTime < timeout) {
      const messages = await this.redis.xrange(streamName, '-', '+', 'COUNT', 1);
      if (messages.length > 0) {
        const [id, fields] = messages[messages.length - 1];
        const data = {};
        for (let i = 0; i < fields.length; i += 2) {
          data[fields[i]] = fields[i + 1];
        }
        return { id, data: JSON.parse(data.data || '{}') };
      }
      await new Promise((resolve) => setTimeout(resolve, 100));
    }

    throw new Error(`Timeout waiting for message in stream ${streamName}`);
  }

  async clearTestStreams() {
    const streams = [
      'orchestrator.commands',
      'analysis.signals',
      'risk.requests',
      'risk.responses',
      'exec.orders',
      'exec.status',
      'notify.events',
    ];

    for (const stream of streams) {
      try {
        await this.redis.del(stream);
      } catch (error) {
        // Ignore deletion errors for non-existent streams
      }
    }
  }

  async cleanup() {
    await this.redis.disconnect();
  }
}

describe('E2E Trading Workflow Tests', () => {
  let testUtils;

  beforeAll(async () => {
    testUtils = new TestUtils();

    // Verify all agents are healthy
    for (const [agentName, url] of Object.entries(CONFIG.agents)) {
      const response = await testUtils.makeRequest(`${url}/health`);
      expect(response.status).toBe(200);
      expect(response.data.status).toBe('healthy');
    }
  }, CONFIG.timeouts.longRunning);

  afterAll(async () => {
    await testUtils.cleanup();
  });

  beforeEach(async () => {
    await testUtils.clearTestStreams();
  });

  describe('Complete Trading Workflow', () => {
    test(
      'should execute complete trade workflow from analysis to execution',
      async () => {
        const traceId = testUtils.generateTraceId();
        const requestId = crypto.randomUUID();

        // Step 1: Trigger orchestration run
        const orchestrateResponse = await testUtils.makeRequest(
          `${CONFIG.agents.orchestrator}/orchestrate/run`,
          {
            method: 'POST',
            data: {
              symbol: CONFIG.test.symbol,
              mode: 'pubsub',
              traceId,
            },
          }
        );

        expect(orchestrateResponse.status).toBe(200);
        expect(orchestrateResponse.data.traceId).toBe(traceId);

        // Step 2: Wait for analysis signal
        const analysisSignal = await testUtils.waitForStreamMessage(
          'analysis.signals',
          CONFIG.timeouts.workflow
        );

        expect(analysisSignal.data.symbol).toBe(CONFIG.test.symbol);
        expect(analysisSignal.data.side).toMatch(/^(buy|sell)$/);
        expect(analysisSignal.data.confidence).toBeGreaterThan(0);
        expect(analysisSignal.data.confidence).toBeLessThanOrEqual(1);

        // Step 3: Wait for risk request
        const riskRequest = await testUtils.waitForStreamMessage(
          'risk.requests',
          CONFIG.timeouts.workflow
        );

        expect(riskRequest.data.symbol).toBe(CONFIG.test.symbol);
        expect(riskRequest.data.side).toBe(analysisSignal.data.side);

        // Step 4: Wait for risk response
        const riskResponse = await testUtils.waitForStreamMessage(
          'risk.responses',
          CONFIG.timeouts.workflow
        );

        expect(riskResponse.data.requestId).toBe(riskRequest.data.requestId);
        expect(typeof riskResponse.data.ok).toBe('boolean');

        // Step 5: If risk approved, wait for execution order
        if (riskResponse.data.ok) {
          const execOrder = await testUtils.waitForStreamMessage(
            'exec.orders',
            CONFIG.timeouts.workflow
          );

          expect(execOrder.data.symbol).toBe(CONFIG.test.symbol);
          expect(execOrder.data.side).toBe(analysisSignal.data.side);
          expect(execOrder.data.qty).toBeGreaterThan(0);

          // Step 6: Wait for execution status
          const execStatus = await testUtils.waitForStreamMessage(
            'exec.status',
            CONFIG.timeouts.workflow
          );

          expect(execStatus.data.orderId).toBe(execOrder.data.orderId);
          expect(execStatus.data.status).toMatch(/^(filled|rejected|failed|pending)$/);

          // Step 7: Verify notification event
          const notification = await testUtils.waitForStreamMessage(
            'notify.events',
            CONFIG.timeouts.workflow
          );

          expect(notification.data.type).toBeDefined();
          expect(notification.data.severity).toMatch(/^(info|warning|critical)$/);
        }
      },
      CONFIG.timeouts.longRunning
    );

    test(
      'should handle risk rejection workflow',
      async () => {
        const traceId = testUtils.generateTraceId();

        // Force a risk rejection by using extreme parameters
        const response = await testUtils.makeRequest(`${CONFIG.agents.riskManager}/risk/evaluate`, {
          method: 'POST',
          data: {
            symbol: CONFIG.test.symbol,
            side: 'buy',
            qty: 999999, // Extremely large order to trigger rejection
            confidence: 0.1, // Low confidence
            traceId,
          },
        });

        expect(response.status).toBe(200);
        expect(response.data.ok).toBe(false);
        expect(response.data.reason).toBeDefined();

        // Verify rejection notification
        const notification = await testUtils.waitForStreamMessage(
          'notify.events',
          CONFIG.timeouts.workflow
        );

        expect(notification.data.type).toMatch(/risk_rejected|rejection/);
        expect(notification.data.severity).toMatch(/warning|critical/);
      },
      CONFIG.timeouts.workflow
    );
  });

  describe('PnL and Halt Management', () => {
    test('should track PnL and enforce daily targets', async () => {
      // Get current PnL status
      const pnlResponse = await testUtils.makeRequest(`${CONFIG.agents.orchestrator}/pnl/status`);

      expect(pnlResponse.status).toBe(200);
      expect(pnlResponse.data).toHaveProperty('dailyPnl');
      expect(pnlResponse.data).toHaveProperty('isHalted');
      expect(pnlResponse.data).toHaveProperty('targetReached');
    });

    test('should allow manual halt and unhalt operations', async () => {
      const traceId = testUtils.generateTraceId();

      // Test halt
      const haltResponse = await testUtils.makeRequest(
        `${CONFIG.agents.orchestrator}/admin/orchestrate/halt`,
        {
          method: 'POST',
          data: {
            reason: 'E2E test halt',
            traceId,
          },
        }
      );

      expect(haltResponse.status).toBe(200);

      // Verify halt status
      const statusAfterHalt = await testUtils.makeRequest(
        `${CONFIG.agents.orchestrator}/pnl/status`
      );

      expect(statusAfterHalt.data.isHalted).toBe(true);

      // Test unhalt
      const unhaltResponse = await testUtils.makeRequest(
        `${CONFIG.agents.orchestrator}/admin/orchestrate/unhalt`,
        {
          method: 'POST',
          headers: {
            'X-Admin-Token': testUtils.adminToken,
          },
        }
      );

      expect(unhaltResponse.status).toBe(200);

      // Verify unhalt status
      const statusAfterUnhalt = await testUtils.makeRequest(
        `${CONFIG.agents.orchestrator}/pnl/status`
      );

      expect(statusAfterUnhalt.data.isHalted).toBe(false);
    });
  });

  describe('Stream Management and DLQ', () => {
    test('should handle stream pending monitoring', async () => {
      const response = await testUtils.makeRequest(
        `${CONFIG.agents.orchestrator}/admin/streams/pending?stream=notify.events&group=notify`
      );

      expect(response.status).toBe(200);
      expect(response.data).toHaveProperty('pending');
    });

    test('should handle DLQ operations', async () => {
      // Get DLQ list
      const dlqListResponse = await testUtils.makeRequest(
        `${CONFIG.agents.orchestrator}/admin/streams/dlq?stream=notify.events.dlq`
      );

      expect(dlqListResponse.status).toBe(200);
      expect(Array.isArray(dlqListResponse.data.entries)).toBe(true);

      // If there are DLQ entries, test requeue (this is optional as DLQ may be empty)
      if (dlqListResponse.data.entries.length > 0) {
        const entryId = dlqListResponse.data.entries[0].id;

        const requeueResponse = await testUtils.makeRequest(
          `${CONFIG.agents.orchestrator}/admin/streams/dlq/requeue`,
          {
            method: 'POST',
            data: {
              dlqStream: 'notify.events.dlq',
              id: entryId,
            },
          }
        );

        expect(requeueResponse.status).toBe(200);
      }
    });
  });

  describe('Agent Health and Metrics', () => {
    test('should validate all agent health endpoints', async () => {
      for (const [agentName, url] of Object.entries(CONFIG.agents)) {
        const response = await testUtils.makeRequest(`${url}/health`);

        expect(response.status).toBe(200);
        expect(response.data.status).toBe('healthy');
        expect(response.data).toHaveProperty('timestamp');
        expect(response.data).toHaveProperty('uptime');
      }
    });

    test('should validate all agent metrics endpoints', async () => {
      for (const [agentName, url] of Object.entries(CONFIG.agents)) {
        const response = await testUtils.makeRequest(`${url}/metrics`);

        expect(response.status).toBe(200);
        expect(response.headers['content-type']).toMatch(/text\/plain/);
        expect(response.data).toContain('# HELP');
        expect(response.data).toContain('# TYPE');
      }
    });
  });

  describe('Notification System', () => {
    test('should handle notification posting and retrieval', async () => {
      const traceId = testUtils.generateTraceId();

      // Post a test notification
      const postResponse = await testUtils.makeRequest(
        `${CONFIG.agents.notificationManager}/notify`,
        {
          method: 'POST',
          data: {
            type: 'test_notification',
            severity: 'info',
            message: 'E2E test notification',
            traceId,
          },
        }
      );

      expect(postResponse.status).toBe(200);

      // Get recent notifications
      const recentResponse = await testUtils.makeRequest(
        `${CONFIG.agents.notificationManager}/notify/recent`
      );

      expect(recentResponse.status).toBe(200);
      expect(Array.isArray(recentResponse.data.events)).toBe(true);

      // Find our test notification
      const testNotification = recentResponse.data.events.find(
        (event) => event.traceId === traceId
      );

      expect(testNotification).toBeDefined();
      expect(testNotification.type).toBe('test_notification');
      expect(testNotification.severity).toBe('info');
    });

    test('should handle notification acknowledgment', async () => {
      const traceId = testUtils.generateTraceId();

      // Post a notification first
      await testUtils.makeRequest(`${CONFIG.agents.notificationManager}/notify`, {
        method: 'POST',
        data: {
          type: 'ack_test',
          severity: 'warning',
          message: 'Test notification for ack',
          traceId,
        },
      });

      // Acknowledge the notification
      const ackResponse = await testUtils.makeRequest(
        `${CONFIG.agents.notificationManager}/admin/notify/ack`,
        {
          method: 'POST',
          data: { traceId },
        }
      );

      expect(ackResponse.status).toBe(200);
    });
  });

  describe('Parameter Optimization', () => {
    test('should handle parameter optimization requests', async () => {
      // Get current parameters
      const paramsResponse = await testUtils.makeRequest(
        `${CONFIG.agents.parameterOptimizer}/optimize/params`
      );

      expect(paramsResponse.status).toBe(200);
      expect(paramsResponse.data).toHaveProperty('parameters');
    });

    test('should trigger optimization run', async () => {
      const traceId = testUtils.generateTraceId();

      const optimizeResponse = await testUtils.makeRequest(
        `${CONFIG.agents.parameterOptimizer}/optimize/run`,
        {
          method: 'POST',
          data: {
            reason: 'e2e_test',
            symbols: [CONFIG.test.symbol],
            traceId,
          },
        }
      );

      expect(optimizeResponse.status).toBe(200);
      expect(optimizeResponse.data).toHaveProperty('jobId');
    });
  });

  describe('MCP Hub Integration', () => {
    test('should validate MCP hub status', async () => {
      const statusResponse = await testUtils.makeRequest(
        `${CONFIG.agents.mcpHubController}/mcp/status`
      );

      expect(statusResponse.status).toBe(200);
      expect(statusResponse.data).toHaveProperty('status');
    });

    test('should handle MCP commands', async () => {
      const commandResponse = await testUtils.makeRequest(
        `${CONFIG.agents.mcpHubController}/mcp/command`,
        {
          method: 'POST',
          data: {
            command: 'health_check',
            parameters: {},
          },
        }
      );

      expect(commandResponse.status).toBe(200);
    });
  });

  describe('Performance and Load Testing', () => {
    test('should handle concurrent requests without degradation', async () => {
      const concurrentRequests = 10;
      const requests = [];

      for (let i = 0; i < concurrentRequests; i++) {
        requests.push(testUtils.makeRequest(`${CONFIG.agents.orchestrator}/health`));
      }

      const responses = await Promise.all(requests);

      responses.forEach((response) => {
        expect(response.status).toBe(200);
        expect(response.data.status).toBe('healthy');
      });

      // Ensure response times are reasonable (under 5 seconds)
      responses.forEach((response) => {
        expect(response.headers).toHaveProperty('x-response-time');
        const responseTime = parseFloat(response.headers['x-response-time']);
        expect(responseTime).toBeLessThan(5000); // 5 seconds
      });
    });

    test(
      'should maintain performance under sustained load',
      async () => {
        const iterations = 50;
        const responseTimes = [];

        for (let i = 0; i < iterations; i++) {
          const startTime = Date.now();
          const response = await testUtils.makeRequest(`${CONFIG.agents.orchestrator}/health`);
          const endTime = Date.now();

          expect(response.status).toBe(200);
          responseTimes.push(endTime - startTime);

          // Small delay between requests
          await new Promise((resolve) => setTimeout(resolve, 50));
        }

        // Calculate average response time
        const avgResponseTime = responseTimes.reduce((a, b) => a + b, 0) / responseTimes.length;

        // Average response time should be under 1 second
        expect(avgResponseTime).toBeLessThan(1000);

        // No single request should take more than 5 seconds
        const maxResponseTime = Math.max(...responseTimes);
        expect(maxResponseTime).toBeLessThan(5000);
      },
      CONFIG.timeouts.longRunning
    );
  });

  describe('Error Handling and Recovery', () => {
    test('should handle invalid requests gracefully', async () => {
      // Test invalid JSON
      const invalidJsonResponse = await testUtils.makeRequest(
        `${CONFIG.agents.orchestrator}/orchestrate/run`,
        {
          method: 'POST',
          data: 'invalid json',
          headers: {
            'Content-Type': 'application/json',
          },
        }
      );

      expect(invalidJsonResponse.status).toBe(400);

      // Test missing required fields
      const missingFieldsResponse = await testUtils.makeRequest(
        `${CONFIG.agents.orchestrator}/orchestrate/run`,
        {
          method: 'POST',
          data: {},
        }
      );

      expect(missingFieldsResponse.status).toBe(400);
    });

    test('should handle unauthorized requests', async () => {
      const unauthorizedResponse = await testUtils.makeRequest(
        `${CONFIG.agents.orchestrator}/admin/orchestrate/halt`,
        {
          method: 'POST',
          headers: {
            'X-Admin-Token': 'invalid-token',
          },
          data: {
            reason: 'test',
          },
        }
      );

      expect(unauthorizedResponse.status).toBe(401);
    });

    test('should handle non-existent endpoints', async () => {
      const notFoundResponse = await testUtils.makeRequest(
        `${CONFIG.agents.orchestrator}/non-existent-endpoint`
      );

      expect(notFoundResponse.status).toBe(404);
    });
  });
});

// Test suite for integration validation
describe('Integration Validation Tests', () => {
  let testUtils;

  beforeAll(async () => {
    testUtils = new TestUtils();
  });

  afterAll(async () => {
    await testUtils.cleanup();
  });

  test('should validate Redis connectivity', async () => {
    await expect(testUtils.redis.ping()).resolves.toBe('PONG');
  });

  test('should validate Redis streams functionality', async () => {
    const testStream = 'test-stream';
    const testData = { test: 'data', timestamp: new Date().toISOString() };

    // Add test message
    const messageId = await testUtils.redis.xadd(testStream, '*', 'data', JSON.stringify(testData));

    expect(messageId).toBeDefined();

    // Read test message
    const messages = await testUtils.redis.xrange(testStream, '-', '+');
    expect(messages.length).toBeGreaterThan(0);

    // Cleanup
    await testUtils.redis.del(testStream);
  });

  test('should validate container networking', async () => {
    // Test that agents can communicate with each other
    const orchestratorResponse = await testUtils.makeRequest(
      `${CONFIG.agents.orchestrator}/health`
    );

    expect(orchestratorResponse.status).toBe(200);

    // Test internal API calls (this would be exposed if orchestrator makes internal calls)
    // This is a placeholder for testing internal service-to-service communication
  });
});

export default {
  testUtils: TestUtils,
  config: CONFIG,
};
