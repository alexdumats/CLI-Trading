import os from 'os';

export async function ensureGroup(redis, stream, group) {
  try {
    await redis.xgroup('CREATE', stream, group, '$', 'MKSTREAM');
  } catch (e) {
    const msg = String(e?.message || e);
    if (!msg.includes('BUSYGROUP')) throw e;
  }
}

export async function xaddJSON(redis, stream, payload) {
  const data = JSON.stringify(payload);
  return redis.xadd(stream, '*', 'data', data);
}

// Monitor pending count periodically and set via callback
export function startPendingMonitor({ redis, stream, group, intervalMs = 10000, onCount }) {
  let stopped = false;
  const loop = async () => {
    while (!stopped) {
      try {
        const summary = await redis.xpending(stream, group);
        // summary can be: [ count, smallestId, greatestId, [ [consumer, count], ... ] ]
        const count = Array.isArray(summary) ? parseInt(summary[0] || 0, 10) : 0;
        onCount?.(count);
      } catch (e) {
        // ignore
      }
      await new Promise((r) => {
        const h = setTimeout(r, intervalMs);
        if (h && typeof h.unref === 'function') h.unref();
      });
    }
  };
  loop();
  return () => {
    stopped = true;
  };
}

// Start a consumer with optional idempotency and DLQ support
export function startConsumer({
  redis,
  stream,
  group,
  consumerName,
  handler,
  logger,
  idempotency,
  dlqStream,
  maxFailures = 5,
}) {
  let stopped = false;
  const consumer = consumerName || `${os.hostname()}-${process.pid}`;
  const failureHashKey = `stream:${stream}:group:${group}:failures`;
  (async () => {
    await ensureGroup(redis, stream, group);
    while (!stopped) {
      try {
        // First, attempt to read pending (non-blocking)
        let res = await redis.xreadgroup(
          'GROUP',
          group,
          consumer,
          'COUNT',
          10,
          'STREAMS',
          stream,
          '0'
        );
        if (!res) {
          // Then, block for new messages
          res = await redis.xreadgroup(
            'GROUP',
            group,
            consumer,
            'COUNT',
            10,
            'BLOCK',
            10000,
            'STREAMS',
            stream,
            '>'
          );
          if (!res) {
            // avoid tight loop when mocks return null immediately
            await new Promise((r) => setTimeout(r, 5));
            continue;
          }
        }
        for (const [sname, entries] of res) {
          for (const [id, fields] of entries) {
            const idx = fields.findIndex((v, i) => i % 2 === 0 && v === 'data');
            const jsonStr = idx >= 0 ? fields[idx + 1] : null;
            const payload = jsonStr ? JSON.parse(jsonStr) : {};

            // Idempotency check
            let isDup = false;
            let idKey = id;
            try {
              if (idempotency?.redis && idempotency?.keyFn) {
                idKey = idempotency.keyFn(payload) || id;
                const set = await idempotency.redis.set(
                  `idem:${stream}:${group}:${idKey}`,
                  '1',
                  'EX',
                  idempotency.ttlSeconds || 86400,
                  'NX'
                );
                if (set !== 'OK') {
                  isDup = true;
                }
              }
            } catch (e) {
              logger?.error?.('idempotency_error', {
                stream,
                group,
                error: String(e?.message || e),
              });
            }

            if (isDup) {
              try {
                await redis.xack(stream, group, id);
              } catch {}
              continue;
            }

            try {
              await handler({ id, stream: sname, payload });
              await redis.xack(stream, group, id);
              // clear failure count if any
              try {
                await redis.hdel(failureHashKey, id);
              } catch {}
            } catch (err) {
              logger?.error?.('stream_handler_error', {
                stream,
                group,
                error: String(err?.message || err),
              });
              // increment failures
              let failures = 0;
              try {
                failures = await redis.hincrby(failureHashKey, id, 1);
              } catch {}
              if (failures >= maxFailures && dlqStream) {
                try {
                  await xaddJSON(redis, dlqStream, {
                    originalStream: stream,
                    group,
                    id,
                    payload,
                    error: String(err?.message || err),
                    ts: new Date().toISOString(),
                  });
                  await redis.xack(stream, group, id);
                  await redis.hdel(failureHashKey, id);
                } catch (e2) {
                  logger?.error?.('dlq_publish_error', {
                    stream,
                    group,
                    error: String(e2?.message || e2),
                  });
                }
              }
              // else: leave pending for retry
            }
          }
        }
      } catch (e) {
        logger?.error?.('stream_read_error', { stream, group, error: String(e?.message || e) });
      }
    }
  })();
  return () => {
    stopped = true;
  };
}
