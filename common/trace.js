import crypto from 'crypto';
import os from 'os';

export function traceMiddleware(service) {
  return (req, res, next) => {
    const incomingRequestId = req.header('x-request-id');
    const incomingTraceId = req.header('x-trace-id');
    const requestId = incomingRequestId || crypto.randomUUID();
    const traceId = incomingTraceId || crypto.randomUUID();
    req.ids = { requestId, traceId };
    res.setHeader('X-Request-Id', requestId);
    res.setHeader('X-Trace-Id', traceId);
    res.setHeader('X-Service', service);
    next();
  };
}

export function requestLoggerMiddleware(logger) {
  return (req, res, next) => {
    const start = process.hrtime.bigint();
    const { requestId, traceId } = req.ids || {};
    res.on('finish', () => {
      const durNs = Number(process.hrtime.bigint() - start);
      const durationMs = Math.round(durNs / 1e6);
      logger.info('http_request', {
        method: req.method,
        path: req.originalUrl || req.url,
        status: res.statusCode,
        durationMs,
        requestId,
        traceId,
        remote: req.ip,
        ua: req.headers['user-agent'],
        host: req.headers['host'] || os.hostname(),
      });
    });
    next();
  };
}

export function withTrace(extra, ids) {
  const { requestId, traceId } = ids || {};
  return { ...extra, requestId, traceId };
}
