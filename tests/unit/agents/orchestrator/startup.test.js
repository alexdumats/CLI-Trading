/**
 * Startup tests for Orchestrator agent
 * Verifies that the service boots, registers routes, and listens on the configured port
 * without performing real network/redis/pg activity.
 */
import { jest } from '@jest/globals';

// Mock heavy dependencies
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
// Prevent real pg connections during import of createPgPool()
jest.mock('pg', () => {
  const mockPoolInstance = {
    query: jest.fn().mockResolvedValue({ rows: [], rowCount: 0 }),
    end: jest.fn().mockResolvedValue(undefined),
  };
  return {
    Pool: jest.fn().mockImplementation(() => mockPoolInstance),
  };
});

// Prom metrics stubs
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
  return {
    Registry: jest.fn(() => register),
    collectDefaultMetrics: jest.fn(),
    Histogram,
    Gauge,
  };
});

// HTTP client
jest.mock('axios', () => {
  const instance = {
    post: jest.fn().mockResolvedValue({ status: 200, data: {} }),
  };
  return {
    default: {
      create: jest.fn(() => instance),
    },
  };
});

// Prevent background consumers/monitors from starting real loops
jest.mock('../../../../common/streams.js', () => ({
  ensureGroup: jest.fn().mockResolvedValue(undefined),
  xaddJSON: jest.fn().mockResolvedValue('1-0'),
  startPendingMonitor: jest.fn().mockReturnValue(() => {}),
  startConsumer: jest.fn().mockReturnValue(() => {}),
}));

// Express app stub
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

describe('Orchestrator startup', () => {
  const OLD_ENV = process.env;

  beforeEach(() => {
    jest.clearAllMocks();
    process.env = { ...OLD_ENV };
    process.env.SERVICE_NAME = 'Claude Orchestrator Test';
    process.env.PORT = '7101';
    process.env.REDIS_URL = 'redis://mock:6379/0';
    process.env.START_EQUITY = '1000';
    process.env.DAILY_TARGET_PCT = '1';
    process.env.COMM_MODE = 'pubsub';
  });

  afterEach(() => {
    process.env = OLD_ENV;
    jest.resetModules();
  });

  test('boots server, registers core routes, and listens on configured port', async () => {
    // Dynamic import after mocks configured
    await import('../../../agents/orchestrator/src/index.js');

    // listen called with PORT
    expect(listenMock).toHaveBeenCalledTimes(1);
    const [port] = listenMock.mock.calls[0];
    expect(port).toBe(7101);

    // routes registered
    // health
    expect(expressGet).toHaveBeenCalledWith('/health', expect.any(Function));
    // metrics
    expect(expressGet).toHaveBeenCalledWith('/metrics', expect.any(Function));
    // pnl status route
    expect(expressGet).toHaveBeenCalledWith('/pnl/status', expect.any(Function));
    // orchestrate run route
    expect(expressPost).toHaveBeenCalledWith('/orchestrate/run', expect.any(Function));
  });
});
