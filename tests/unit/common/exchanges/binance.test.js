/**
 * Unit tests for the Binance exchange adapter (stub)
 */
import { jest } from '@jest/globals';
import { getBinanceAdapter } from '../../../../common/exchanges/binance.js';

describe('Binance Exchange Adapter (stub)', () => {
  let originalEnv;

  beforeEach(() => {
    originalEnv = { ...process.env };
    jest.clearAllMocks();
  });

  afterEach(() => {
    process.env = originalEnv;
  });

  test('returns missing_creds when API key/secret are not provided', async () => {
    delete process.env.BINANCE_API_KEY;
    delete process.env.BINANCE_API_SECRET;
    delete process.env.BINANCE_API_KEY_FILE;
    delete process.env.BINANCE_API_SECRET_FILE;

    const adapter = getBinanceAdapter();
    const res = await adapter.placeOrder({ orderId: 'o1', symbol: 'BTC-USD', side: 'buy', qty: 1 });

    expect(res).toEqual({
      filled: false,
      orderId: 'o1',
      symbol: 'BTC-USD',
      side: 'buy',
      qty: 1,
      raw: { error: 'missing_creds' },
    });
  });

  test('when creds exist, returns stub note and does not fill', async () => {
    process.env.BINANCE_API_KEY = 'key';
    process.env.BINANCE_API_SECRET = 'secret';

    const adapter = getBinanceAdapter();
    const res = await adapter.placeOrder({
      orderId: 'o2',
      symbol: 'ETH-USD',
      side: 'sell',
      qty: 0.5,
    });

    expect(res.filled).toBe(false);
    expect(res).toMatchObject({
      orderId: 'o2',
      symbol: 'ETH-USD',
      side: 'sell',
      qty: 0.5,
      raw: { note: 'binance stub' },
    });
  });
});
