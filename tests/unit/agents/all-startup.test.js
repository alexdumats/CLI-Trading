/**
 * Startup tests for all agents
 * - Verifies each service boots and calls express.listen on the configured PORT
 * - Avoids real network/Redis/Postgres/Streams side effects via module mocks
 */
import { jest } from '@jest/globals';

// Shared mocks for heavy deps across all agents
jest.mock('ioredis', () => {
  return jest.fn().mockImplementation(() => ({
    on: jest.fn(),
    ping: jest.fn().mockResolvedValue('PONG'),
    quit: jest.fn().mockResolvedValue('OK'),
    publish: jest.fn().mockResolvedValue(1),
    xadd: jest.fn().mockResolvedValue('1-0'),
    xgroup: jest.fn().mockResolvedValue('OK'),
    xpending: jest.fn().mockResolvedValue([0, null, null, []]),
    xreadgroup: jest.fn().mockResolvedValue(null),
    xrange: jest.fn().mockResolvedValue([]),
    xdel: jest.fn().mockResolvedValue(1),
    scan: jest.fn().mockResolvedValue(['0', []]),
    hgetall: jest.fn().mockResolvedValue({}),
    hset: jest.fn().mockResolvedValue(1),
    hincrby: jest.fn().mockResolvedValue(1),
    set: jest.fn().mockResolvedValue('OK'),
    exists: jest.fn().mockResolvedValue(0),
  }));
});

jest.mock('prom-client', () => {
  const register = {
    contentType: 'text/plain',
    metrics: jest.fn().mockResolvedValue('# HELP test\n'),
    registerMetric: jest.fn(),
  };
  class Histogram {
    constructor() {}
    startTimer() {
      return () => {};
    }
  }
  class Gauge {
    constructor() {}
    set() {}
  }
  class Counter {
    constructor() {}
    inc() {}
  }
  return {
    Registry: jest.fn(() => register),
    collectDefaultMetrics: jest.fn(),
    Histogram,
    Gauge,
    Counter,
  };
});

// Prevent real pg connections during import of createPgPool() used by some agents
jest.mock('pg', () => {
  const mockPoolInstance = {
    query: jest.fn().mockResolvedValue({ rows: [], rowCount: 0 }),
    end: jest.fn().mockResolvedValue(undefined),
  };
  return {
    Pool: jest.fn().mockImplementation(() => mockPoolInstance),
  };
});

// axios used by some agents via axios.create()
jest.mock('axios', () => {
  const instance = {
    post: jest.fn().mockResolvedValue({ status: 200, data: {} }),
    get: jest.fn().mockResolvedValue({ status: 200, data: {} }),
  };
  return {
    default: {
      create: jest.fn(() => instance),
      post: instance.post,
      get: instance.get,
    },
  };
});

// Prevent background loops from streams helpers
jest.mock('../../../common/streams.js', () => ({
  ensureGroup: jest.fn().mockResolvedValue(undefined),
  xaddJSON: jest.fn().mockResolvedValue('1-0'),
  startPendingMonitor: jest.fn().mockReturnValue(() => {}),
  startConsumer: jest.fn().mockReturnValue(() => {}),
}));

// Replace express app with a stub to capture listen and route bindings
const expressUse = jest.fn();
const expressGet = jest.fn();
const expressPost = jest.fn();
const listenMock = jest.fn((port, cb) => {
  if (cb) cb();
  return { close: jest.fn() };
});
jest.mock('express', () => {
  const express = jest.fn(() => ({
    use: expressUse,
    get: expressGet,
    post: expressPost,
    listen: listenMock,
  }));
  express.json = () => (req, res, next) => next();
  return express;
});

// Mock morgan to avoid dependency and side effects
jest.mock(
  'morgan',
  () => {
    return () => (req, res, next) => next();
  },
  { virtual: true }
);

// Stub setInterval to avoid background handles during agent imports
const REAL_SET_INTERVAL = global.setInterval;
beforeAll(() => {
  // Prevent real intervals from creating open handles in agent modules (e.g., trade-executor reconciliation loop)
  global.setInterval = jest.fn(() => ({ unref: () => {} }));
});
afterAll(() => {
  global.setInterval = REAL_SET_INTERVAL;
});

describe('All agents startup', () => {
  const OLD_ENV = process.env;

  // Define agent entrypoints
  const agents = [
    { name: 'orchestrator', path: '../../../agents/orchestrator/src/index.js' },
    { name: 'market-analyst', path: '../../../agents/market-analyst/src/index.js' },
    { name: 'trade-executor', path: '../../../agents/trade-executor/src/index.js' },
    { name: 'notification-manager', path: '../../../agents/notification-manager/src/index.js' },
    { name: 'parameter-optimizer', path: '../../../agents/parameter-optimizer/src/index.js' },
    { name: 'portfolio-manager', path: '../../../agents/portfolio-manager/src/index.js' },
    { name: 'risk-manager', path: '../../../agents/risk-manager/src/index.js' },
    { name: 'mcp-hub-controller', path: '../../../agents/mcp-hub-controller/src/index.js' },
    { name: 'integrations-broker', path: '../../../agents/integrations-broker/src/index.js' },
  ];

  beforeEach(() => {
    jest.clearAllMocks();
    process.env = { ...OLD_ENV };
    // Provide safe defaults for agents
    process.env.REDIS_URL = 'redis://mock:6379/0';
    process.env.SERVICE_NAME = 'Agent Test';
    process.env.START_EQUITY = '1000';
    process.env.DAILY_TARGET_PCT = '1';
  });

  afterEach(() => {
    process.env = OLD_ENV;
    jest.resetModules();
  });

  for (const agent of agents) {
    test(`boots ${agent.name} and listens on PORT=0 without side-effects`, async () => {
      // Force an ephemeral port and COMM_MODE to 'pubsub' to avoid axios flows
      process.env.PORT = '0';
      process.env.COMM_MODE = 'pubsub';

      await jest.isolateModulesAsync(async () => {
        await import(agent.path);
      });

      // Verify express.listen called once with port 0
      expect(listenMock).toHaveBeenCalledTimes(1);
      const [port] = listenMock.mock.calls[0];
      expect(port).toBe(0);

      // Verify basic middlewares/routes plugged (at least one use() and 404 handler via use)
      expect(expressUse).toHaveBeenCalled();

      // Reset for next agent
      listenMock.mockClear();
      expressUse.mockClear();
      expressGet.mockClear();
      expressPost.mockClear();
    });
  }
});
