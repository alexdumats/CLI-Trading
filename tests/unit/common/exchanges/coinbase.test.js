/**
 * Unit tests for the Coinbase exchange adapter (stub)
 */
import { jest } from '@jest/globals';
import { getCoinbaseAdapter } from '../../../../common/exchanges/coinbase.js';

describe('Coinbase Exchange Adapter (stub)', () => {
  let originalEnv;

  beforeEach(() => {
    originalEnv = { ...process.env };
    jest.clearAllMocks();
  });

  afterEach(() => {
    process.env = originalEnv;
  });

  test('returns missing_creds when API key/secret/passphrase are not provided', async () => {
    delete process.env.COINBASE_API_KEY;
    delete process.env.COINBASE_API_SECRET;
    delete process.env.COINBASE_API_PASSPHRASE;
    delete process.env.COINBASE_API_KEY_FILE;
    delete process.env.COINBASE_API_SECRET_FILE;
    delete process.env.COINBASE_API_PASSPHRASE_FILE;

    const adapter = getCoinbaseAdapter();
    const res = await adapter.placeOrder({ orderId: 'c1', symbol: 'BTC-USD', side: 'buy', qty: 1 });

    expect(res).toEqual({
      filled: false,
      orderId: 'c1',
      symbol: 'BTC-USD',
      side: 'buy',
      qty: 1,
      raw: { error: 'missing_creds' },
    });
  });

  test('when creds exist, returns stub note and does not fill', async () => {
    process.env.COINBASE_API_KEY = 'ckey';
    process.env.COINBASE_API_SECRET = 'csecret';
    process.env.COINBASE_API_PASSPHRASE = 'cpass';

    const adapter = getCoinbaseAdapter();
    const res = await adapter.placeOrder({
      orderId: 'c2',
      symbol: 'ETH-USD',
      side: 'sell',
      qty: 0.25,
    });

    expect(res.filled).toBe(false);
    expect(res).toMatchObject({
      orderId: 'c2',
      symbol: 'ETH-USD',
      side: 'sell',
      qty: 0.25,
      raw: { note: 'coinbase stub' },
    });
  });
});
