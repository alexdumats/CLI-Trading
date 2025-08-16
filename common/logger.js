import { stdout } from 'node:process';

export function createLogger(service) {
  function write(level, msg, extra = {}) {
    const entry = {
      level,
      service,
      msg,
      time: new Date().toISOString(),
      ...extra,
    };
    stdout.write(JSON.stringify(entry) + '\n');
  }
  return {
    info: (msg, extra) => write('info', msg, extra),
    warn: (msg, extra) => write('warn', msg, extra),
    error: (msg, extra) => write('error', msg, extra),
    debug: (msg, extra) => write('debug', msg, extra),
    child: (bindings = {}) => ({
      info: (msg, extra) => write('info', msg, { ...bindings, ...extra }),
      warn: (msg, extra) => write('warn', msg, { ...bindings, ...extra }),
      error: (msg, extra) => write('error', msg, { ...bindings, ...extra }),
      debug: (msg, extra) => write('debug', msg, { ...bindings, ...extra }),
    })
  };
}
