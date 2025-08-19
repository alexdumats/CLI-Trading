/**
 * Adapter contract tests to ensure all exchange adapters satisfy the required shape.
 */
import { jest } from '@jest/globals';
import { getPaperAdapter } from '../../../../common/exchanges/paper.js';
import { getBinanceAdapter } from '../../../../common/exchanges/binance.js';
import { getCoinbaseAdapter } from '../../../../common/exchanges/coinbase.js';

function expectHasPlaceOrder(adapter) {
  expect(adapter).toBeDefined();
  expect(typeof adapter.placeOrder).toBe('function');
}

function validateFillShape(fill, { expectFilled, order }) {
  expect(fill).toBeDefined();
  expect(typeof fill.filled).toBe('boolean');
  expect(fill.orderId).toBe(order.orderId);
  expect(fill.symbol).toBe(order.symbol);
  expect(fill.side).toBe(order.side);
  expect(fill.qty).toBe(order.qty);

  if (expectFilled) {
    expect(fill.filled).toBe(true);
    expect(typeof fill.price).toBe('number');
    expect(typeof fill.notional).toBe('number');
    expect(typeof fill.fee).toBe('number');
  } else {
    expect(fill.filled).toBe(false);
  }
}

describe('Exchange Adapter Contract', () => {
  const order = { orderId: 'contract-1', symbol: 'BTC-USD', side: 'buy', qty: 1 };

  test('Paper adapter satisfies contract and returns a filled trade', async () => {
    const adapter = getPaperAdapter();
    expectHasPlaceOrder(adapter);

    const fill = await adapter.placeOrder(order);
    validateFillShape(fill, { expectFilled: true, order });
  });

  test('Binance adapter has placeOrder and returns structured stub without creds', async () => {
    delete process.env.BINANCE_API_KEY;
    delete process.env.BINANCE_API_SECRET;

    const adapter = getBinanceAdapter();
    expectHasPlaceOrder(adapter);

    const fill = await adapter.placeOrder(order);
    validateFillShape(fill, { expectFilled: false, order });
    expect(fill.raw).toBeDefined();
  });

  test('Coinbase adapter has placeOrder and returns structured stub without creds', async () => {
    delete process.env.COINBASE_API_KEY;
    delete process.env.COINBASE_API_SECRET;
    delete process.env.COINBASE_API_PASSPHRASE;

    const adapter = getCoinbaseAdapter();
    expectHasPlaceOrder(adapter);

    const fill = await adapter.placeOrder(order);
    validateFillShape(fill, { expectFilled: false, order });
    expect(fill.raw).toBeDefined();
  });
});
