/**
 * Unit tests for the logger module
 */
import { jest } from '@jest/globals';
import { createLogger } from '../../../common/logger.js';

describe('Logger Module', () => {
  let originalStdout;
  let stdoutMock;
  let capturedLogs;

  beforeEach(() => {
    // Save original stdout.write
    originalStdout = process.stdout.write;

    // Set up mock for stdout.write
    capturedLogs = [];
    stdoutMock = jest.fn((data) => {
      capturedLogs.push(data);
      return true;
    });
    process.stdout.write = stdoutMock;
  });

  afterEach(() => {
    // Restore original stdout.write
    process.stdout.write = originalStdout;
  });

  test('creates a logger with the specified service name', () => {
    const logger = createLogger('test-service');
    expect(logger).toBeDefined();
    expect(logger.info).toBeInstanceOf(Function);
    expect(logger.warn).toBeInstanceOf(Function);
    expect(logger.error).toBeInstanceOf(Function);
    expect(logger.debug).toBeInstanceOf(Function);
  });

  test('logs messages with the correct format', () => {
    const logger = createLogger('test-service');
    logger.info('test message');

    expect(stdoutMock).toHaveBeenCalledTimes(1);

    const logEntry = JSON.parse(capturedLogs[0]);
    expect(logEntry).toMatchObject({
      level: 'info',
      service: 'test-service',
      msg: 'test message',
    });
    expect(logEntry.time).toBeDefined();
  });

  test('includes extra fields in log messages', () => {
    const logger = createLogger('test-service');
    const extra = { requestId: '123', userId: '456' };

    logger.info('test message with extra', extra);

    const logEntry = JSON.parse(capturedLogs[0]);
    expect(logEntry).toMatchObject({
      level: 'info',
      service: 'test-service',
      msg: 'test message with extra',
      requestId: '123',
      userId: '456',
    });
  });

  test('supports different log levels', () => {
    const logger = createLogger('test-service');

    logger.info('info message');
    logger.warn('warn message');
    logger.error('error message');
    logger.debug('debug message');

    expect(stdoutMock).toHaveBeenCalledTimes(4);

    const infoLog = JSON.parse(capturedLogs[0]);
    const warnLog = JSON.parse(capturedLogs[1]);
    const errorLog = JSON.parse(capturedLogs[2]);
    const debugLog = JSON.parse(capturedLogs[3]);

    expect(infoLog.level).toBe('info');
    expect(warnLog.level).toBe('warn');
    expect(errorLog.level).toBe('error');
    expect(debugLog.level).toBe('debug');
  });

  test('creates child loggers with bindings', () => {
    const logger = createLogger('test-service');
    const childLogger = logger.child({ requestId: '123' });

    childLogger.info('child logger message');

    const logEntry = JSON.parse(capturedLogs[0]);
    expect(logEntry).toMatchObject({
      level: 'info',
      service: 'test-service',
      msg: 'child logger message',
      requestId: '123',
    });
  });

  test('child logger merges bindings with extra fields', () => {
    const logger = createLogger('test-service');
    const childLogger = logger.child({ requestId: '123' });

    childLogger.info('child logger message', { userId: '456' });

    const logEntry = JSON.parse(capturedLogs[0]);
    expect(logEntry).toMatchObject({
      level: 'info',
      service: 'test-service',
      msg: 'child logger message',
      requestId: '123',
      userId: '456',
    });
  });

  test('child logger bindings take precedence over extra fields with same name', () => {
    const logger = createLogger('test-service');
    const childLogger = logger.child({ requestId: '123' });

    childLogger.info('child logger message', { requestId: '456' });

    const logEntry = JSON.parse(capturedLogs[0]);
    expect(logEntry.requestId).toBe('456');
  });
});
