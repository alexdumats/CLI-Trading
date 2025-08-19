/**
 * Common test utilities
 */
import { jest } from '@jest/globals';
import { createLogger } from '../../common/logger.js';
import createRedisMock from './redis-mock.js';
import createPgPoolMock from './pg-mock.js';
import { createAxiosMock, createExpressMocks } from './http-mock.js';

/**
 * Create a mock environment with common dependencies
 * @param {Object} options - Configuration options
 * @returns {Object} - Mock environment
 */
export function createTestEnvironment(options = {}) {
  // Create mocks for common dependencies
  const redisMock = options.redis || createRedisMock();
  const pgPoolMock = options.pgPool || createPgPoolMock();
  const axiosMock = options.axios || createAxiosMock();
  const logger = options.logger || createLogger('test');

  // Mock environment variables
  const originalEnv = { ...process.env };
  const env = {
    SERVICE_NAME: 'test-service',
    PORT: '9999',
    REDIS_URL: 'redis://mock:6379/0',
    POSTGRES_HOST: 'mock',
    POSTGRES_PORT: '5432',
    POSTGRES_USER: 'test',
    POSTGRES_PASSWORD: 'test',
    POSTGRES_DB: 'test',
    ...options.env,
  };

  // Apply environment variables
  Object.entries(env).forEach(([key, value]) => {
    process.env[key] = value;
  });

  return {
    redisMock,
    pgPoolMock,
    axiosMock,
    logger,
    env,

    // Helper to create Express mocks
    createExpressMocks,

    // Helper to mock a specific module
    mockModule(modulePath, implementation) {
      jest.mock(modulePath, () => implementation, { virtual: true });
      return implementation;
    },

    // Helper to spy on a method
    spyOn(object, method) {
      return jest.spyOn(object, method);
    },

    // Helper to wait for a specific time
    async wait(ms) {
      return new Promise((resolve) => setTimeout(resolve, ms));
    },

    // Helper to restore the original environment
    cleanup() {
      // Restore original environment
      Object.keys(env).forEach((key) => {
        if (originalEnv[key]) {
          process.env[key] = originalEnv[key];
        } else {
          delete process.env[key];
        }
      });
    },
  };
}

/**
 * Create a mock exchange adapter for testing
 * @param {Object} options - Configuration options
 * @returns {Object} - Mock exchange adapter
 */
export function createMockExchangeAdapter(options = {}) {
  return {
    placeOrder: jest.fn().mockImplementation(async ({ orderId, symbol, side, qty }) => {
      return {
        filled: true,
        orderId,
        symbol,
        side,
        qty,
        price: options.price || 50000,
        notional: qty * (options.price || 50000),
        fee: options.fee || 0.1,
        raw: { status: 'FILLED' },
      };
    }),

    getOrder: jest.fn().mockImplementation(async ({ orderId }) => {
      return {
        orderId,
        status: options.orderStatus || 'FILLED',
        symbol: options.symbol || 'BTC-USD',
        side: options.side || 'buy',
        qty: options.qty || 1,
        price: options.price || 50000,
        notional: (options.qty || 1) * (options.price || 50000),
        fee: options.fee || 0.1,
      };
    }),

    cancelOrder: jest.fn().mockImplementation(async ({ orderId }) => {
      return { orderId, success: true };
    }),

    fetchBalance: jest.fn().mockImplementation(async () => {
      return {
        total: { USD: options.usdBalance || 100000, BTC: options.btcBalance || 2 },
        free: { USD: options.usdFree || 90000, BTC: options.btcFree || 1.5 },
        used: { USD: options.usdUsed || 10000, BTC: options.btcUsed || 0.5 },
      };
    }),

    fetchTrades: jest.fn().mockImplementation(async ({ since }) => {
      return [
        {
          id: '1',
          timestamp: Date.now() - 3600000,
          symbol: 'BTC-USD',
          side: 'buy',
          price: 49000,
          amount: 0.5,
          cost: 24500,
          fee: 0.05,
        },
        {
          id: '2',
          timestamp: Date.now() - 1800000,
          symbol: 'BTC-USD',
          side: 'sell',
          price: 51000,
          amount: 0.3,
          cost: 15300,
          fee: 0.03,
        },
      ];
    }),
  };
}

/**
 * Create a mock stream message
 * @param {Object} options - Configuration options
 * @returns {Array} - Mock stream message in Redis format
 */
export function createMockStreamMessage(options = {}) {
  const { id = Date.now().toString(), payload = {}, stream = 'test.stream' } = options;

  const data = JSON.stringify(payload);
  return [stream, [[id, ['data', data]]]];
}

export default {
  createTestEnvironment,
  createMockExchangeAdapter,
  createMockStreamMessage,
};
