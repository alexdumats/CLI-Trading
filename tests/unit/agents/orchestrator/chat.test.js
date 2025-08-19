/**
 * Tests for Orchestrator /chat endpoint intents (status | run)
 */
import { jest } from '@jest/globals';

// Mocks similar to startup test to avoid real side-effects
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
    startTimer() {
      return () => {};
    }
  }
  class Gauge {
    set() {}
  }
  class Counter {
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

jest.mock('pg', () => {
  const mockPoolInstance = {
    query: jest.fn().mockResolvedValue({ rows: [], rowCount: 0 }),
    end: jest.fn().mockResolvedValue(undefined),
  };
  return { Pool: jest.fn().mockImplementation(() => mockPoolInstance) };
});

// streams helpers used by /chat
jest.mock('../../../../common/streams.js', () => ({
  ensureGroup: jest.fn().mockResolvedValue(undefined),
  xaddJSON: jest.fn().mockResolvedValue('1-0'),
  startPendingMonitor: jest.fn().mockReturnValue(() => {}),
  startConsumer: jest.fn().mockReturnValue(() => {}),
}));

// axios client used by orchestrator's HTTP pipeline (not used in these tests)
jest.mock('axios', () => ({
  default: {
    create: jest.fn(() => ({ post: jest.fn().mockResolvedValue({ status: 200, data: {} }) })),
  },
}));

// Express stub to capture routes
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

// Utility to invoke a registered POST handler
function findPostHandler(path) {
  const call = expressPost.mock.calls.find(([p]) => p === path);
  if (!call) return null;
  return call[1];
}

// Fake req/res for handler invocation
function makeReqRes({ body = {}, headers = {} } = {}) {
  const res = {
    _status: 200,
    _json: null,
    status(code) {
      this._status = code;
      return this;
    },
    json(obj) {
      this._json = obj;
      return this;
    },
    setHeader() {},
    on() {},
  };
  const req = {
    body,
    header: (h) => headers[h.toLowerCase()] || headers[h] || '',
    ids: { requestId: 'req-1', traceId: 'trace-1' },
  };
  return { req, res };
}

// Mock global fetch used by /chat
const realFetch = global.fetch;

describe('Orchestrator /chat endpoint', () => {
  const OLD_ENV = process.env;

  beforeEach(async () => {
    jest.clearAllMocks();
    process.env = { ...OLD_ENV };
    process.env.PORT = '0';
    process.env.REDIS_URL = 'redis://mock:6379/0';
    process.env.SERVICE_NAME = 'Claude Orchestrator Test';

    // Mock fetch with route-based responses
    global.fetch = jest.fn(async (url, init) => {
      const u = String(url);
      if (u.endsWith('/status')) {
        return new Response(JSON.stringify({ status: 'ok' }), {
          status: 200,
          headers: { 'content-type': 'application/json' },
        });
      }
      if (u.includes('/orchestrate/run')) {
        return new Response(JSON.stringify({ status: 'accepted', requestId: 'r1' }), {
          status: 202,
          headers: { 'content-type': 'application/json' },
        });
      }
      return new Response('not found', { status: 404 });
    });

    // Import orchestrator after mocks are set
    await import('../../../../agents/orchestrator/src/index.js');
  });

  afterEach(() => {
    process.env = OLD_ENV;
    global.fetch = realFetch;
    jest.resetModules();
  });

  test('status intent aggregates service status', async () => {
    const handler = findPostHandler('/chat');
    expect(handler).toBeInstanceOf(Function);
    const { req, res } = makeReqRes({ body: { input: 'status' } });
    await handler(req, res);
    expect(res._status).toBe(200);
    expect(res._json?.ok).toBe(true);
    expect(res._json?.text).toMatch(/Service status summary/);
  });

  test('run intent proxies to /orchestrate/run', async () => {
    const handler = findPostHandler('/chat');
    const { req, res } = makeReqRes({ body: { input: 'run BTC-USD http' } });
    await handler(req, res);
    expect(res._status).toBe(200);
    expect(res._json?.ok).toBe(true);
    expect(res._json?.data?.status || res._json?.data?.mode).toBeDefined();
  });

  test('halt intent requires admin token (401 when missing)', async () => {
    const handler = findPostHandler('/chat');
    const { req, res } = makeReqRes({ body: { input: 'halt' } });
    await handler(req, res);
    expect(res._status).toBe(401);
    expect(res._json?.error).toBe('unauthorized');
  });

  test('halt/unhalt intents succeed with admin token', async () => {
    process.env.ADMIN_TOKEN = 'adm';
    const handler = findPostHandler('/chat');
    let rr = makeReqRes({ body: { input: 'halt' }, headers: { 'x-admin-token': 'adm' } });
    await handler(rr.req, rr.res);
    expect(rr.res._status).toBe(200);
    expect(String(rr.res._json?.text || '')).toMatch(/halted/i);

    rr = makeReqRes({ body: { input: 'unhalt' }, headers: { 'x-admin-token': 'adm' } });
    await handler(rr.req, rr.res);
    expect(rr.res._status).toBe(200);
    expect(String(rr.res._json?.text || '')).toMatch(/resumed/i);
  });

  test('dlq list returns entries (happy path)', async () => {
    process.env.ADMIN_TOKEN = 'adm';
    const IORedis = (await import('ioredis')).default;
    // sub instance is the second Redis() call in orchestrator
    const subInst = IORedis.mock.results[1]?.value;
    subInst.xrange.mockResolvedValue([
      [
        '1700000-0',
        [
          'data',
          JSON.stringify({ originalStream: 'analysis.signals', payload: { type: 'analyze' } }),
        ],
      ],
    ]);

    const handler = findPostHandler('/chat');
    const { req, res } = makeReqRes({
      body: { input: 'dlq list' },
      headers: { 'x-admin-token': 'adm' },
    });
    await handler(req, res);
    expect(res._status).toBe(200);
    expect(res._json?.ok).toBe(true);
    expect(res._json?.data?.entries?.length).toBeGreaterThanOrEqual(1);
  });

  test('dlq requeue succeeds for provided id', async () => {
    process.env.ADMIN_TOKEN = 'adm';
    const IORedis = (await import('ioredis')).default;
    const subInst = IORedis.mock.results[1]?.value;
    subInst.xrange.mockImplementation(async (stream, start, end) => {
      return [
        [
          '1700000-0',
          [
            'data',
            JSON.stringify({
              originalStream: 'analysis.signals',
              payload: { type: 'analyze', requestId: 'X' },
            }),
          ],
        ],
      ];
    });
    subInst.xdel.mockResolvedValue(1);

    const handler = findPostHandler('/chat');
    const { req, res } = makeReqRes({
      body: { input: 'dlq requeue 1700000-0' },
      headers: { 'x-admin-token': 'adm' },
    });
    await handler(req, res);
    expect(res._status).toBe(200);
    expect(String(res._json?.text || '')).toMatch(/Requeued/i);
  });
});
