// Coinbase adapter (stub implementation)
// Reads credentials from env or *_FILE secrets
// - COINBASE_API_KEY / COINBASE_API_KEY_FILE
// - COINBASE_API_SECRET / COINBASE_API_SECRET_FILE
// - COINBASE_API_PASSPHRASE / COINBASE_API_PASSPHRASE_FILE
//
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
  let key = process.env.COINBASE_API_KEY || '';
  if (!key && process.env.COINBASE_API_KEY_FILE)
    key = readSecret(process.env.COINBASE_API_KEY_FILE);
  let secret = process.env.COINBASE_API_SECRET || '';
  if (!secret && process.env.COINBASE_API_SECRET_FILE)
    secret = readSecret(process.env.COINBASE_API_SECRET_FILE);
  let passphrase = process.env.COINBASE_API_PASSPHRASE || '';
  if (!passphrase && process.env.COINBASE_API_PASSPHRASE_FILE)
    passphrase = readSecret(process.env.COINBASE_API_PASSPHRASE_FILE);
  return { key, secret, passphrase };
}

export function getCoinbaseAdapter() {
  const creds = getCreds();
  return {
    async placeOrder({ orderId, symbol, side, qty }) {
      if (!creds.key || !creds.secret || !creds.passphrase) {
        // Stub: reject when creds missing
        return { filled: false, orderId, symbol, side, qty, raw: { error: 'missing_creds' } };
      }
      // TODO: implement signed REST request and return parsed fill
      return { filled: false, orderId, symbol, side, qty, raw: { note: 'coinbase stub' } };
    },
  };
}
