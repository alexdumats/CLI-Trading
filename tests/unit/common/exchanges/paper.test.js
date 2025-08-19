/**
 * Unit tests for the paper exchange adapter
 */
import { jest } from '@jest/globals';
import { getPaperAdapter } from '../../../../common/exchanges/paper.js';

describe('Paper Exchange Adapter', () => {
  let originalEnv;

  beforeEach(() => {
    // Save original environment
    originalEnv = { ...process.env };
  });

  afterEach(() => {
    // Restore original environment
    process.env = originalEnv;
  });

  describe('getPaperAdapter', () => {
    test('creates an adapter with default configuration', () => {
      const adapter = getPaperAdapter();

      expect(adapter).toBeDefined();
      expect(adapter.placeOrder).toBeInstanceOf(Function);
    });
  });

  describe('placeOrder', () => {
    test('returns a filled order with default price and fee', async () => {
      const adapter = getPaperAdapter();

      const order = {
        orderId: 'test-order-1',
        symbol: 'BTC-USD',
        side: 'buy',
        qty: 1,
      };

      const result = await adapter.placeOrder(order);

      expect(result).toEqual({
        filled: true,
        orderId: 'test-order-1',
        symbol: 'BTC-USD',
        side: 'buy',
        qty: 1,
        price: 30000, // Default price
        notional: 30000, // qty * price
        fee: 30, // 0.01% of notional
      });
    });

    test('calculates fees based on custom price', async () => {
      process.env.PAPER_PRICE_DEFAULT = '50000';
      process.env.EXCHANGE_FEE_BPS = '20'; // 0.20%

      const adapter = getPaperAdapter();

      const order = {
        orderId: 'test-order-2',
        symbol: 'BTC-USD',
        side: 'sell',
        qty: 0.5,
      };

      const result = await adapter.placeOrder(order);

      expect(result).toEqual({
        filled: true,
        orderId: 'test-order-2',
        symbol: 'BTC-USD',
        side: 'sell',
        qty: 0.5,
        price: 50000,
        notional: 25000, // 0.5 * 50000
        fee: 50, // 0.02% of 25000
      });
    });

    test('applies slippage to notional calculation', async () => {
      process.env.PAPER_PRICE_DEFAULT = '40000';
      process.env.EXCHANGE_FEE_BPS = '10'; // 0.10%
      process.env.SLIPPAGE_BPS = '5'; // 0.05% slippage

      const adapter = getPaperAdapter();

      const order = {
        orderId: 'test-order-3',
        symbol: 'ETH-USD',
        side: 'buy',
        qty: 2,
      };

      const result = await adapter.placeOrder(order);

      // Expected notional: 2 * 40000 * (1 + 5/10000) = 80000 * 1.0005 = 80040
      // Expected fee: 80040 * (10/10000) = 80.04

      expect(result).toEqual({
        filled: true,
        orderId: 'test-order-3',
        symbol: 'ETH-USD',
        side: 'buy',
        qty: 2,
        price: 40000,
        notional: 80040,
        fee: 80.04,
      });
    });

    test('handles negative quantity correctly', async () => {
      const adapter = getPaperAdapter();

      const order = {
        orderId: 'test-order-4',
        symbol: 'BTC-USD',
        side: 'sell',
        qty: -1.5,
      };

      const result = await adapter.placeOrder(order);

      expect(result).toEqual({
        filled: true,
        orderId: 'test-order-4',
        symbol: 'BTC-USD',
        side: 'sell',
        qty: -1.5,
        price: 30000,
        notional: 45000, // 1.5 * 30000
        fee: 45, // 0.01% of 45000
      });
    });
  });
});
