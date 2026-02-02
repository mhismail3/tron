/**
 * @fileoverview Tests for Tron logger
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import {
  TronLogger,
  getLogger,
  createLogger,
  resetLogger,
} from '../logger.js';

describe('TronLogger', () => {
  beforeEach(() => {
    resetLogger();
  });

  describe('getLogger', () => {
    it('should return a singleton logger instance', () => {
      const logger1 = getLogger();
      const logger2 = getLogger();

      expect(logger1).toBe(logger2);
    });

    it('should create logger with default options', () => {
      const logger = getLogger();

      expect(logger).toBeInstanceOf(TronLogger);
    });
  });

  describe('createLogger', () => {
    it('should create a child logger with component context', () => {
      const logger = createLogger('test-component');

      expect(logger).toBeInstanceOf(TronLogger);
    });

    it('should create child logger with additional context', () => {
      const logger = createLogger('agent', { sessionId: 'sess_123' });

      expect(logger).toBeInstanceOf(TronLogger);
    });
  });

  describe('TronLogger instance', () => {
    let logger: TronLogger;

    beforeEach(() => {
      logger = new TronLogger({ level: 'trace', pretty: false });
    });

    it('should create child loggers', () => {
      const childLogger = logger.child({ sessionId: 'sess_123' });

      expect(childLogger).toBeInstanceOf(TronLogger);
    });

    it('should have all log level methods', () => {
      expect(typeof logger.trace).toBe('function');
      expect(typeof logger.debug).toBe('function');
      expect(typeof logger.info).toBe('function');
      expect(typeof logger.warn).toBe('function');
      expect(typeof logger.error).toBe('function');
      expect(typeof logger.fatal).toBe('function');
    });

    it('should support startTimer for performance tracking', () => {
      const endTimer = logger.startTimer('test-operation');

      expect(typeof endTimer).toBe('function');

      // Calling endTimer should not throw
      endTimer();
    });

    it('should support timed async operations', async () => {
      const result = await logger.timed('async-operation', async () => {
        return 'result';
      });

      expect(result).toBe('result');
    });

    it('should propagate errors in timed operations', async () => {
      await expect(
        logger.timed('failing-operation', async () => {
          throw new Error('Test error');
        })
      ).rejects.toThrow('Test error');
    });
  });

  describe('log methods', () => {
    let logger: TronLogger;

    beforeEach(() => {
      logger = new TronLogger({ level: 'trace', pretty: false });
    });

    it('should log with trace level', () => {
      // Should not throw
      logger.trace('Trace message');
      logger.trace('Trace with data', { key: 'value' });
    });

    it('should log with debug level', () => {
      logger.debug('Debug message');
      logger.debug('Debug with data', { count: 42 });
    });

    it('should log with info level', () => {
      logger.info('Info message');
      logger.info('Info with data', { status: 'ok' });
    });

    it('should log with warn level', () => {
      logger.warn('Warn message');
      logger.warn('Warn with data', { warning: 'deprecated' });
    });

    it('should log with error level', () => {
      logger.error('Error message');
      logger.error('Error with data', { code: 500 });
      logger.error('Error with Error object', new Error('Test error'));
    });

    it('should log with fatal level', () => {
      logger.fatal('Fatal message');
      logger.fatal('Fatal with Error', new Error('Critical error'));
    });
  });
});
