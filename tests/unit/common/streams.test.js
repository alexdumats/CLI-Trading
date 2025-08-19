/**
 * Unit tests for the streams module
 */
import { jest } from '@jest/globals';
import {
  ensureGroup,
  xaddJSON,
  startPendingMonitor,
  startConsumer,
} from '../../../common/streams.js';
import { RedisMock } from '../../helpers/redis-mock.js';

describe('Streams Module', () => {
  let redisMock;
  let loggerMock;

  beforeEach(() => {
    // Create a fresh Redis mock for each test
    redisMock = new RedisMock();

    // Create a mock logger
    loggerMock = {
      info: jest.fn(),
      warn: jest.fn(),
      error: jest.fn(),
      debug: jest.fn(),
    };
  });

  describe('ensureGroup', () => {
    test('creates a consumer group if it does not exist', async () => {
      // Spy on xgroup method
      const xgroupSpy = jest.spyOn(redisMock, 'xgroup');

      await ensureGroup(redisMock, 'test-stream', 'test-group');

      expect(xgroupSpy).toHaveBeenCalledWith(
        'CREATE',
        'test-stream',
        'test-group',
        '$',
        'MKSTREAM'
      );
    });

    test('ignores BUSYGROUP errors', async () => {
      // Mock xgroup to throw a BUSYGROUP error
      jest.spyOn(redisMock, 'xgroup').mockImplementation(() => {
        const error = new Error('BUSYGROUP Consumer Group name already exists');
        return Promise.reject(error);
      });

      // This should not throw
      await expect(ensureGroup(redisMock, 'test-stream', 'test-group')).resolves.not.toThrow();
    });

    test('propagates other errors', async () => {
      // Mock xgroup to throw a different error
      jest.spyOn(redisMock, 'xgroup').mockImplementation(() => {
        const error = new Error('Some other error');
        return Promise.reject(error);
      });

      // This should throw
      await expect(ensureGroup(redisMock, 'test-stream', 'test-group')).rejects.toThrow(
        'Some other error'
      );
    });
  });

  describe('xaddJSON', () => {
    test('adds a JSON payload to a stream', async () => {
      const payload = { key: 'value', nested: { foo: 'bar' } };
      const xaddSpy = jest.spyOn(redisMock, 'xadd');

      await xaddJSON(redisMock, 'test-stream', payload);

      expect(xaddSpy).toHaveBeenCalledWith('test-stream', '*', 'data', JSON.stringify(payload));
    });

    test('returns the message ID', async () => {
      // Mock xadd to return a specific ID
      jest.spyOn(redisMock, 'xadd').mockResolvedValue('1234567890-0');

      const result = await xaddJSON(redisMock, 'test-stream', { key: 'value' });

      expect(result).toBe('1234567890-0');
    });
  });

  describe('startPendingMonitor', () => {
    test('periodically checks pending count and calls onCount', async () => {
      // Mock xpending to return a specific count
      jest.spyOn(redisMock, 'xpending').mockResolvedValue([5, null, null, []]);

      const onCountMock = jest.fn();

      // Start the monitor with a short interval
      const stopMonitor = startPendingMonitor({
        redis: redisMock,
        stream: 'test-stream',
        group: 'test-group',
        intervalMs: 100,
        onCount: onCountMock,
      });

      // Wait for the monitor to run at least once
      await new Promise((resolve) => setTimeout(resolve, 150));

      // Stop the monitor
      stopMonitor();

      // Verify onCount was called with the correct count
      expect(onCountMock).toHaveBeenCalledWith(5);
    });

    test('handles errors gracefully', async () => {
      // Mock xpending to throw an error
      jest.spyOn(redisMock, 'xpending').mockImplementation(() => {
        throw new Error('Redis error');
      });

      const onCountMock = jest.fn();

      // Start the monitor with a short interval
      const stopMonitor = startPendingMonitor({
        redis: redisMock,
        stream: 'test-stream',
        group: 'test-group',
        intervalMs: 100,
        onCount: onCountMock,
      });

      // Wait for the monitor to run at least once
      await new Promise((resolve) => setTimeout(resolve, 150));

      // Stop the monitor
      stopMonitor();

      // Verify onCount was not called
      expect(onCountMock).not.toHaveBeenCalled();
    });
  });

  describe('startConsumer', () => {
    test('processes messages from a stream', async () => {
      // Set up a mock handler
      const handlerMock = jest.fn().mockResolvedValue(undefined);
      const xackSpy = jest.spyOn(redisMock, 'xack');

      // Mock xreadgroup to return a message
      const mockPayload = { key: 'value' };
      const mockMessage = [
        ['test-stream', [['1234567890-0', ['data', JSON.stringify(mockPayload)]]]],
      ];

      jest
        .spyOn(redisMock, 'xreadgroup')
        .mockResolvedValueOnce(mockMessage) // First call returns a message
        .mockResolvedValue(null); // Subsequent calls return null

      // Start the consumer
      const stopConsumer = startConsumer({
        redis: redisMock,
        stream: 'test-stream',
        group: 'test-group',
        handler: handlerMock,
        logger: loggerMock,
      });

      // Wait for the consumer to process the message
      await new Promise((resolve) => setTimeout(resolve, 100));

      // Stop the consumer
      stopConsumer();

      // Verify the handler was called with the correct payload
      expect(handlerMock).toHaveBeenCalledWith({
        id: '1234567890-0',
        stream: 'test-stream',
        payload: mockPayload,
      });

      // Verify the message was acknowledged
      expect(xackSpy).toHaveBeenCalledWith('test-stream', 'test-group', '1234567890-0');
    });

    test('handles handler errors and increments failure count', async () => {
      // Set up a mock handler that throws an error
      const handlerMock = jest.fn().mockRejectedValue(new Error('Handler error'));

      // Mock xreadgroup to return a message
      const mockPayload = { key: 'value' };
      const mockMessage = [
        ['test-stream', [['1234567890-0', ['data', JSON.stringify(mockPayload)]]]],
      ];

      jest
        .spyOn(redisMock, 'xreadgroup')
        .mockResolvedValueOnce(mockMessage) // First call returns a message
        .mockResolvedValue(null); // Subsequent calls return null

      // Start the consumer
      const hincrbySpy = jest.spyOn(redisMock, 'hincrby');
      const stopConsumer = startConsumer({
        redis: redisMock,
        stream: 'test-stream',
        group: 'test-group',
        handler: handlerMock,
        logger: loggerMock,
      });

      // Wait for the consumer to process the message
      await new Promise((resolve) => setTimeout(resolve, 100));

      // Stop the consumer
      stopConsumer();

      // Verify the error was logged
      expect(loggerMock.error).toHaveBeenCalledWith(
        'stream_handler_error',
        expect.objectContaining({
          stream: 'test-stream',
          group: 'test-group',
          error: 'Handler error',
        })
      );

      // Verify the failure count was incremented
      const hincrbySpyArgs = hincrbySpy.mock.calls[0];
      expect(hincrbySpyArgs[0]).toContain('failures');
      expect(hincrbySpyArgs[1]).toBe('1234567890-0');
      expect(hincrbySpyArgs[2]).toBe(1);
    });

    test('moves messages to DLQ after max failures', async () => {
      // Set up a mock handler that throws an error
      const handlerMock = jest.fn().mockRejectedValue(new Error('Handler error'));

      // Mock xreadgroup to return a message
      const mockPayload = { key: 'value' };
      const mockMessage = [
        ['test-stream', [['1234567890-0', ['data', JSON.stringify(mockPayload)]]]],
      ];

      jest
        .spyOn(redisMock, 'xreadgroup')
        .mockResolvedValueOnce(mockMessage) // First call returns a message
        .mockResolvedValue(null); // Subsequent calls return null

      // Mock hincrby to return max failures
      jest.spyOn(redisMock, 'hincrby').mockResolvedValue(5);

      // Start the consumer with DLQ
      const xaddSpy = jest.spyOn(redisMock, 'xadd');
      const xackSpy = jest.spyOn(redisMock, 'xack');
      const hdelSpy = jest.spyOn(redisMock, 'hdel');
      const stopConsumer = startConsumer({
        redis: redisMock,
        stream: 'test-stream',
        group: 'test-group',
        handler: handlerMock,
        logger: loggerMock,
        dlqStream: 'test-stream.dlq',
        maxFailures: 5,
      });

      // Wait for the consumer to process the message
      await new Promise((resolve) => setTimeout(resolve, 100));

      // Stop the consumer
      stopConsumer();

      // Verify the message was moved to DLQ
      expect(xaddSpy).toHaveBeenCalledWith(
        'test-stream.dlq',
        '*',
        'data',
        expect.stringContaining('originalStream')
      );

      // Verify the message was acknowledged
      expect(xackSpy).toHaveBeenCalledWith('test-stream', 'test-group', '1234567890-0');

      // Verify the failure count was cleared
      expect(hdelSpy).toHaveBeenCalledWith(expect.stringContaining('failures'), '1234567890-0');
    });
  });
});
