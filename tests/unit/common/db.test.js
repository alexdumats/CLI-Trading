/**
 * Unit tests for the db module
 */
import { jest } from '@jest/globals';
import fs from 'node:fs';

// ESM-safe mocking: define the pg mock before importing the module under test
let createPgPool;
let insertAudit;
let upsertPnl;
let pg;

beforeAll(async () => {
  // Build a single mockPool instance shared across tests
  const mockPool = {
    query: jest.fn().mockResolvedValue({ rows: [], rowCount: 0 }),
    connect: jest.fn().mockResolvedValue({ query: jest.fn(), release: jest.fn() }),
    end: jest.fn().mockResolvedValue(),
  };

  // Mock 'pg' as an ESM module default export with Pool
  await jest.unstable_mockModule('pg', () => {
    const Pool = jest.fn().mockImplementation(() => mockPool);
    // Expose both default (with Pool) and named Pool to satisfy different import styles
    return {
      __esModule: true,
      default: { Pool },
      Pool,
    };
  });

  // Now dynamically import the mocked module and the module under test
  pg = await import('pg');
  ({ createPgPool, insertAudit, upsertPnl } = await import('../../../common/db.js'));
});

describe('Database Module', () => {
  let mockPool;
  let originalEnv;

  beforeEach(() => {
    // Save original environment
    originalEnv = { ...process.env };

    // Reset mock implementation
    jest.clearAllMocks();

    // Get reference to the mock pool constructed by our mock
    mockPool = new pg.Pool();
  });

  afterEach(() => {
    // Restore original environment
    process.env = originalEnv;
  });

  describe('createPgPool', () => {
    test('creates a pool with default configuration', () => {
      const pool = createPgPool();

      expect(pg.Pool).toHaveBeenCalledWith({
        host: 'localhost',
        port: 5432,
        user: 'postgres',
        password: '',
        database: 'postgres',
        max: 10,
        idleTimeoutMillis: 30000,
      });

      expect(pool).toBe(mockPool);
    });

    test('uses environment variables for configuration', () => {
      process.env.POSTGRES_HOST = 'test-host';
      process.env.POSTGRES_PORT = '5433';
      process.env.POSTGRES_USER = 'test-user';
      process.env.POSTGRES_PASSWORD = 'test-password';
      process.env.POSTGRES_DB = 'test-db';

      createPgPool();

      expect(pg.Pool).toHaveBeenCalledWith({
        host: 'test-host',
        port: 5433,
        user: 'test-user',
        password: 'test-password',
        database: 'test-db',
        max: 10,
        idleTimeoutMillis: 30000,
      });
    });

    test('reads password from file if POSTGRES_PASSWORD_FILE is set', () => {
      const spy = jest.spyOn(fs, 'readFileSync').mockReturnValue('file-password\n');

      process.env.POSTGRES_PASSWORD_FILE = '/path/to/password';

      createPgPool();

      expect(spy).toHaveBeenCalledWith('/path/to/password', 'utf8');
      expect(pg.Pool).toHaveBeenCalledWith(
        expect.objectContaining({
          password: 'file-password',
        })
      );

      spy.mockRestore();
    });
  });

  describe('insertAudit', () => {
    test('inserts audit record with correct parameters', async () => {
      const auditData = {
        type: 'test-event',
        severity: 'info',
        payload: { key: 'value' },
        requestId: 'req-123',
        traceId: 'trace-456',
      };

      await insertAudit(mockPool, auditData);

      expect(mockPool.query).toHaveBeenCalledWith(
        expect.stringContaining('insert into audit_events'),
        ['test-event', 'info', JSON.stringify({ key: 'value' }), 'req-123', 'trace-456']
      );
    });

    test('uses default severity if not provided', async () => {
      const auditData = {
        type: 'test-event',
      };

      await insertAudit(mockPool, auditData);

      expect(mockPool.query).toHaveBeenCalledWith(expect.any(String), [
        'test-event',
        'info',
        '{}',
        null,
        null,
      ]);
    });

    test('uses empty object for payload if not provided', async () => {
      const auditData = {
        type: 'test-event',
        severity: 'error',
      };

      await insertAudit(mockPool, auditData);

      expect(mockPool.query).toHaveBeenCalledWith(expect.any(String), [
        'test-event',
        'error',
        '{}',
        null,
        null,
      ]);
    });
  });

  describe('upsertPnl', () => {
    test('upserts PnL record with correct parameters', async () => {
      const pnlData = {
        date: '2023-01-01',
        startEquity: 1000,
        realized: 50,
        percent: 5,
        dailyTargetPct: 2,
        halted: false,
      };

      await upsertPnl(mockPool, pnlData);

      expect(mockPool.query).toHaveBeenCalledWith(expect.stringContaining('insert into pnl_days'), [
        '2023-01-01',
        1000,
        50,
        5,
        2,
        false,
      ]);
    });

    test('handles all required parameters', async () => {
      const pnlData = {
        date: '2023-01-01',
        startEquity: 1000,
        realized: 50,
        percent: 5,
        dailyTargetPct: 2,
        halted: true,
      };

      await upsertPnl(mockPool, pnlData);

      expect(mockPool.query).toHaveBeenCalledWith(
        expect.stringContaining('on conflict (date) do update'),
        ['2023-01-01', 1000, 50, 5, 2, true]
      );
    });
  });
});
