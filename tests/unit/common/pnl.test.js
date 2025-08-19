/**
 * Unit tests for the PnL module
 */
import { jest } from '@jest/globals';
import {
  initDayIfNeeded,
  getStatus,
  resetDay,
  incrementPnl,
  setHalted,
  isHalted,
} from '../../../common/pnl.js';
import { RedisMock } from '../../helpers/redis-mock.js';

describe('PnL Module', () => {
  let redis;
  const FIXED_DATE = new Date('2023-01-02T00:00:00.000Z');

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(FIXED_DATE);
    redis = new RedisMock();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  test('initDayIfNeeded initializes hash with defaults when missing', async () => {
    const key = await initDayIfNeeded(redis, { startEquity: 1000, dailyTargetPct: 1 });
    expect(key).toBe('pnl:2023-01-02');
    const raw = await redis.hgetall(key);
    expect(raw).toEqual({
      date: '2023-01-02',
      startEquity: '1000',
      realized: '0',
      percent: '0',
      dailyTargetPct: '1',
      halted: '0',
    });
  });

  test('getStatus returns normalized defaults when no data for the day', async () => {
    const status = await getStatus(redis);
    expect(status).toEqual({
      date: '2023-01-02',
      startEquity: 0,
      realized: 0,
      percent: 0,
      dailyTargetPct: 1,
      halted: false,
    });
  });

  test('resetDay overwrites values and returns normalized status', async () => {
    const status = await resetDay(redis, { startEquity: 2000, dailyTargetPct: 2 });
    expect(status.date).toBe('2023-01-02');
    expect(status.startEquity).toBe(2000);
    expect(status.realized).toBe(0);
    expect(status.percent).toBe(0);
    expect(status.dailyTargetPct).toBe(2);
    expect(status.halted).toBe(false);
  });

  test('incrementPnl adjusts realized and percent based on startEquity', async () => {
    await initDayIfNeeded(redis, { startEquity: 1000, dailyTargetPct: 1 });
    const afterFirst = await incrementPnl(redis, 50);
    expect(afterFirst.realized).toBeCloseTo(50, 6);
    expect(afterFirst.percent).toBeCloseTo(5, 6);
    const afterSecond = await incrementPnl(redis, -20);
    expect(afterSecond.realized).toBeCloseTo(30, 6);
    expect(afterSecond.percent).toBeCloseTo(3, 6);
  });

  test('setHalted and isHalted toggle halted state', async () => {
    await setHalted(redis, true);
    expect(await isHalted(redis)).toBe(true);
    await setHalted(redis, false);
    expect(await isHalted(redis)).toBe(false);
  });
});
