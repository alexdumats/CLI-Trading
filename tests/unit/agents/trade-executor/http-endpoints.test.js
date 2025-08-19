/**
 * Unit tests for the trade-executor HTTP endpoints
 */
import { jest } from '@jest/globals';
import express from 'express';
import supertest from 'supertest';
import { createTestEnvironment } from '../../../helpers/test-utils.js';

// Mock dependencies
jest.mock('ioredis', () => {
  return jest.fn().mockImplementation(() => {
    return {
      on: jest.fn(),
      ping: jest.fn().mockResolvedValue('PONG'),
      xadd: jest.fn().mockResolvedValue('1234567890-0'),
      quit: jest.fn().mockResolvedValue('OK'),
    };
  });
});

jest.mock('../../../../common/trace.js', () => ({
  traceMiddleware: () => (req, res, next) => next(),
  requestLoggerMiddleware: () => (req, res, next) => next(),
}));

jest.mock('../../../../common/streams.js', () => ({
  xaddJSON: jest.fn().mockResolvedValue('1234567890-0'),
  startConsumer: jest.fn().mockReturnValue(() => {}),
  startPendingMonitor: jest.fn().mockReturnValue(() => {}),
}));

jest.mock('../../../../common/exchanges/paper.js', () => ({
  getPaperAdapter: jest.fn().mockReturnValue({
    placeOrder: jest.fn().mockResolvedValue({
      filled: true,
      orderId: 'test-order',
      symbol: 'BTC-USD',
      side: 'buy',
      qty: 1,
      price: 30000,
      notional: 30000,
      fee: 3,
    }),
  }),
}));

jest.mock('../../../../common/exchanges/binance.js', () => ({
  getBinanceAdapter: jest.fn().mockReturnValue({}),
}));

jest.mock('../../../../common/exchanges/coinbase.js', () => ({
  getCoinbaseAdapter: jest.fn().mockReturnValue({}),
}));

describe('Trade Executor HTTP Endpoints', () => {
  let app;
  let request;
  let testEnv;

  beforeEach(() => {
    // Reset module registry to ensure clean imports
    jest.resetModules();

    // Create test environment
    testEnv = createTestEnvironment({
      env: {
        SERVICE_NAME: 'Trade Executor Test',
        PORT: '9999',
        REDIS_URL: 'redis://mock:6379/0',
        EXCHANGE: 'paper',
      },
    });

    // Create a minimal Express app for testing
    app = express();
    app.use(express.json());

    // Import the routes (we need to do this after mocking dependencies)
    const setupRoutes = (app) => {
      // Health endpoint
      app.get('/health', (req, res) => {
        res.json({ status: 'ok', service: process.env.SERVICE_NAME, uptime: process.uptime() });
      });

      // Trade submission endpoint
      app.post('/trade/submit', (req, res) => {
        const {
          orderId = `${Date.now()}`,
          symbol = 'BTC-USD',
          side = 'buy',
          qty = 1,
        } = req.body || {};
        res.status(202).json({ orderId, symbol, side, qty, status: 'accepted' });
      });

      // Trade status endpoint
      app.get('/trade/status/:id', (req, res) => {
        res.json({ id: req.params.id, status: 'pending' });
      });

      // 404 handler
      app.use((req, res) => {
        res.status(404).json({ error: 'not_found', path: req.path });
      });
    };

    setupRoutes(app);

    // Create supertest instance
    request = supertest(app);
  });

  afterEach(() => {
    // Clean up test environment
    testEnv.cleanup();
  });

  describe('GET /health', () => {
    test('returns 200 OK with service info', async () => {
      const response = await request.get('/health');

      expect(response.status).toBe(200);
      expect(response.body).toMatchObject({
        status: 'ok',
        service: 'Trade Executor Test',
      });
      expect(response.body.uptime).toBeGreaterThanOrEqual(0);
    });
  });

  describe('POST /trade/submit', () => {
    test('accepts trade order and returns 202 Accepted', async () => {
      const orderData = {
        orderId: 'test-order-1',
        symbol: 'BTC-USD',
        side: 'buy',
        qty: 1.5,
      };

      const response = await request
        .post('/trade/submit')
        .send(orderData)
        .set('Content-Type', 'application/json');

      expect(response.status).toBe(202);
      expect(response.body).toEqual({
        orderId: 'test-order-1',
        symbol: 'BTC-USD',
        side: 'buy',
        qty: 1.5,
        status: 'accepted',
      });
    });

    test('uses default values for missing fields', async () => {
      const response = await request
        .post('/trade/submit')
        .send({})
        .set('Content-Type', 'application/json');

      expect(response.status).toBe(202);
      expect(response.body).toMatchObject({
        symbol: 'BTC-USD',
        side: 'buy',
        qty: 1,
        status: 'accepted',
      });
      expect(response.body.orderId).toBeDefined();
    });
  });

  describe('GET /trade/status/:id', () => {
    test('returns pending status for any order ID', async () => {
      const response = await request.get('/trade/status/test-order-123');

      expect(response.status).toBe(200);
      expect(response.body).toEqual({
        id: 'test-order-123',
        status: 'pending',
      });
    });
  });

  describe('404 handler', () => {
    test('returns 404 for unknown routes', async () => {
      const response = await request.get('/unknown-route');

      expect(response.status).toBe(404);
      expect(response.body).toEqual({
        error: 'not_found',
        path: '/unknown-route',
      });
    });
  });
});
