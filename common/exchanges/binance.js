// Binance adapter (stub implementation)
// Reads credentials from env or *_FILE secrets
// - BINANCE_API_KEY or BINANCE_API_KEY_FILE
// - BINANCE_API_SECRET or BINANCE_API_SECRET_FILE
// Network I/O is intentionally omitted here and should be filled when going live.

import fs from 'node:fs';

function readSecret(path) {
  try {
    return fs.readFileSync(path, 'utf8').trim();
  } catch {
    return '';
  }
}

function getCreds() {
  let key = process.env.BINANCE_API_KEY || '';
  if (!key && process.env.BINANCE_API_KEY_FILE) key = readSecret(process.env.BINANCE_API_KEY_FILE);
  let secret = process.env.BINANCE_API_SECRET || '';
  if (!secret && process.env.BINANCE_API_SECRET_FILE)
    secret = readSecret(process.env.BINANCE_API_SECRET_FILE);
  return { key, secret };
}

export function getBinanceAdapter() {
  const creds = getCreds();
  return {
    async placeOrder({ orderId, symbol, side, qty }) {
      if (!creds.key || !creds.secret) {
        // Stub: reject when creds missing
        return { filled: false, orderId, symbol, side, qty, raw: { error: 'missing_creds' } };
      }
      // TODO: implement signed REST request to /api/v3/order and return parsed fill
      return { filled: false, orderId, symbol, side, qty, raw: { note: 'binance stub' } };
    },
  };
}
