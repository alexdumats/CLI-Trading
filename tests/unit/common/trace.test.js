/**
 * Unit tests for the trace module
 */
import { jest } from '@jest/globals';
import { traceMiddleware, requestLoggerMiddleware, withTrace } from '../../../common/trace.js';

describe('Trace Module', () => {
  describe('traceMiddleware()', () => {
    test('generates requestId and traceId when missing and sets headers', () => {
      const req = {
        header: jest.fn().mockReturnValue(undefined),
      };
      const res = {
        setHeader: jest.fn(),
      };
      const next = jest.fn();

      const mw = traceMiddleware('TestService');
      mw(req, res, next);

      expect(req.ids).toBeDefined();
      expect(req.ids.requestId).toBeDefined();
      expect(req.ids.traceId).toBeDefined();

      expect(res.setHeader).toHaveBeenCalledWith('X-Request-Id', req.ids.requestId);
      expect(res.setHeader).toHaveBeenCalledWith('X-Trace-Id', req.ids.traceId);
      expect(res.setHeader).toHaveBeenCalledWith('X-Service', 'TestService');
      expect(next).toHaveBeenCalled();
    });

    test('uses incoming ids when provided via headers', () => {
      const req = {
        header: jest.fn((name) => {
          if (name === 'x-request-id') return 'incoming-req-1';
          if (name === 'x-trace-id') return 'incoming-trace-1';
          return undefined;
        }),
      };
      const res = { setHeader: jest.fn() };
      const next = jest.fn();

      traceMiddleware('TestService')(req, res, next);

      expect(req.ids).toEqual({ requestId: 'incoming-req-1', traceId: 'incoming-trace-1' });
      expect(res.setHeader).toHaveBeenCalledWith('X-Request-Id', 'incoming-req-1');
      expect(res.setHeader).toHaveBeenCalledWith('X-Trace-Id', 'incoming-trace-1');
      expect(res.setHeader).toHaveBeenCalledWith('X-Service', 'TestService');
      expect(next).toHaveBeenCalled();
    });
  });

  describe('requestLoggerMiddleware()', () => {
    test('logs request info on response finish', () => {
      const logger = { info: jest.fn() };
      const mw = requestLoggerMiddleware(logger);

      const req = {
        method: 'GET',
        originalUrl: '/health',
        url: '/health',
        ip: '127.0.0.1',
        headers: { 'user-agent': 'jest', host: 'localhost' },
        ids: { requestId: 'req-1', traceId: 'trace-1' },
      };

      let finishHandler;
      const res = {
        statusCode: 200,
        on: (evt, cb) => {
          if (evt === 'finish') finishHandler = cb;
        },
      };
      const next = jest.fn();

      mw(req, res, next);

      // simulate response finished
      expect(typeof finishHandler).toBe('function');
      finishHandler();

      expect(logger.info).toHaveBeenCalledWith(
        'http_request',
        expect.objectContaining({
          method: 'GET',
          path: '/health',
          status: 200,
          requestId: 'req-1',
          traceId: 'trace-1',
          remote: '127.0.0.1',
          ua: 'jest',
          host: 'localhost',
        })
      );
      // durationMs should be a number
      const call = logger.info.mock.calls[0][1];
      expect(typeof call.durationMs).toBe('number');
      expect(next).toHaveBeenCalled();
    });
  });

  describe('withTrace()', () => {
    test('merges requestId and traceId into extra object', () => {
      const extra = { key: 'value' };
      const out = withTrace(extra, { requestId: 'r1', traceId: 't1' });
      expect(out).toEqual({ key: 'value', requestId: 'r1', traceId: 't1' });
    });

    test('handles missing ids object', () => {
      const out = withTrace({ a: 1 }, undefined);
      expect(out).toEqual({ a: 1, requestId: undefined, traceId: undefined });
    });
  });
});
