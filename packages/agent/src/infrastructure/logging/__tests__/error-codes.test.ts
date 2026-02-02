/**
 * @fileoverview Tests for error categorization system
 */

import { describe, it, expect } from 'vitest';
import {
  LogErrorCategory,
  LogErrorCodes,
  categorizeError,
  createStructuredError,
} from '../error-codes.js';

describe('LogErrorCategory', () => {
  it('should have all expected categories', () => {
    expect(LogErrorCategory.DATABASE).toBe('DB');
    expect(LogErrorCategory.FILESYSTEM).toBe('FS');
    expect(LogErrorCategory.NETWORK).toBe('NET');
    expect(LogErrorCategory.PROVIDER_AUTH).toBe('PAUTH');
    expect(LogErrorCategory.PROVIDER_RATE_LIMIT).toBe('PRATE');
    expect(LogErrorCategory.PROVIDER_API).toBe('PAPI');
    expect(LogErrorCategory.PROVIDER_STREAM).toBe('PSTRM');
    expect(LogErrorCategory.TOOL_EXECUTION).toBe('TOOL');
    expect(LogErrorCategory.TOOL_VALIDATION).toBe('TVAL');
    expect(LogErrorCategory.GUARDRAIL).toBe('GUARD');
    expect(LogErrorCategory.SESSION_STATE).toBe('SESS');
    expect(LogErrorCategory.EVENT_PERSIST).toBe('EVNT');
    expect(LogErrorCategory.COMPACTION).toBe('COMP');
    expect(LogErrorCategory.TOKEN_LIMIT).toBe('TLIM');
    expect(LogErrorCategory.SKILL_LOAD).toBe('SKILL');
    expect(LogErrorCategory.HOOK_EXECUTION).toBe('HOOK');
    expect(LogErrorCategory.SUBAGENT).toBe('SUB');
    expect(LogErrorCategory.UNKNOWN).toBe('UNK');
  });
});

describe('LogErrorCodes', () => {
  it('should have filesystem error codes', () => {
    expect(LogErrorCodes.FS_NOT_FOUND).toBe('FS_NOT_FOUND');
    expect(LogErrorCodes.FS_PERMISSION).toBe('FS_PERMISSION');
    expect(LogErrorCodes.FS_DISK_FULL).toBe('FS_DISK_FULL');
  });

  it('should have provider error codes', () => {
    expect(LogErrorCodes.PAUTH_INVALID).toBe('PAUTH_INVALID');
    expect(LogErrorCodes.PRATE_429).toBe('PRATE_429');
    expect(LogErrorCodes.PAPI_OVERLOADED).toBe('PAPI_OVERLOADED');
  });

  it('should have tool error codes', () => {
    expect(LogErrorCodes.TOOL_NOT_FOUND).toBe('TOOL_NOT_FOUND');
    expect(LogErrorCodes.TOOL_TIMEOUT).toBe('TOOL_TIMEOUT');
    expect(LogErrorCodes.TOOL_ERROR).toBe('TOOL_ERROR');
  });
});

describe('categorizeError', () => {
  describe('HTTP status code errors', () => {
    it('should categorize 401 as auth error', () => {
      const error = Object.assign(new Error('Unauthorized'), { status: 401 });
      const result = categorizeError(error);

      expect(result.category).toBe(LogErrorCategory.PROVIDER_AUTH);
      expect(result.code).toBe(LogErrorCodes.PAUTH_INVALID);
      expect(result.retryable).toBe(false);
    });

    it('should categorize 429 as rate limit error', () => {
      const error = Object.assign(new Error('Too Many Requests'), { status: 429 });
      const result = categorizeError(error);

      expect(result.category).toBe(LogErrorCategory.PROVIDER_RATE_LIMIT);
      expect(result.code).toBe(LogErrorCodes.PRATE_429);
      expect(result.retryable).toBe(true);
    });

    it('should categorize 503 as overloaded', () => {
      const error = Object.assign(new Error('Service Unavailable'), { status: 503 });
      const result = categorizeError(error);

      expect(result.category).toBe(LogErrorCategory.PROVIDER_API);
      expect(result.code).toBe(LogErrorCodes.PAPI_OVERLOADED);
      expect(result.retryable).toBe(true);
    });

    it('should handle statusCode property', () => {
      const error = Object.assign(new Error('Bad Request'), { statusCode: 400 });
      const result = categorizeError(error);

      expect(result.category).toBe(LogErrorCategory.PROVIDER_API);
      expect(result.code).toBe(LogErrorCodes.PAPI_REQUEST);
    });
  });

  describe('Node.js error codes', () => {
    it('should categorize ENOENT as file not found', () => {
      const error = Object.assign(new Error('ENOENT: no such file'), { code: 'ENOENT' });
      const result = categorizeError(error);

      expect(result.category).toBe(LogErrorCategory.FILESYSTEM);
      expect(result.code).toBe(LogErrorCodes.FS_NOT_FOUND);
      expect(result.retryable).toBe(false);
    });

    it('should categorize EACCES as permission error', () => {
      const error = Object.assign(new Error('EACCES: permission denied'), { code: 'EACCES' });
      const result = categorizeError(error);

      expect(result.category).toBe(LogErrorCategory.FILESYSTEM);
      expect(result.code).toBe(LogErrorCodes.FS_PERMISSION);
    });

    it('should categorize ETIMEDOUT as network timeout', () => {
      const error = Object.assign(new Error('ETIMEDOUT'), { code: 'ETIMEDOUT' });
      const result = categorizeError(error);

      expect(result.category).toBe(LogErrorCategory.NETWORK);
      expect(result.code).toBe(LogErrorCodes.NET_TIMEOUT);
      expect(result.retryable).toBe(true);
    });

    it('should categorize ECONNREFUSED as network refused', () => {
      const error = Object.assign(new Error('ECONNREFUSED'), { code: 'ECONNREFUSED' });
      const result = categorizeError(error);

      expect(result.category).toBe(LogErrorCategory.NETWORK);
      expect(result.code).toBe(LogErrorCodes.NET_REFUSED);
      expect(result.retryable).toBe(true);
    });
  });

  describe('message pattern matching', () => {
    it('should categorize rate limit messages', () => {
      const error = new Error('Rate limit exceeded, please slow down');
      const result = categorizeError(error);

      expect(result.category).toBe(LogErrorCategory.PROVIDER_RATE_LIMIT);
      expect(result.code).toBe(LogErrorCodes.PRATE_429);
      expect(result.retryable).toBe(true);
    });

    it('should categorize unauthorized messages', () => {
      const error = new Error('Invalid API key provided');
      const result = categorizeError(error);

      expect(result.category).toBe(LogErrorCategory.PROVIDER_AUTH);
      expect(result.code).toBe(LogErrorCodes.PAUTH_INVALID);
    });

    it('should categorize timeout messages', () => {
      const error = new Error('Request timed out after 30000ms');
      const result = categorizeError(error);

      expect(result.category).toBe(LogErrorCategory.NETWORK);
      expect(result.code).toBe(LogErrorCodes.NET_TIMEOUT);
    });

    it('should categorize stream interruption', () => {
      const error = new Error('Stream error: connection interrupted');
      const result = categorizeError(error);

      expect(result.category).toBe(LogErrorCategory.PROVIDER_STREAM);
      expect(result.code).toBe(LogErrorCodes.PSTRM_INTERRUPTED);
    });

    it('should categorize overloaded messages', () => {
      const error = new Error('API is currently overloaded');
      const result = categorizeError(error);

      expect(result.category).toBe(LogErrorCategory.PROVIDER_API);
      expect(result.code).toBe(LogErrorCodes.PAPI_OVERLOADED);
    });
  });

  describe('context handling', () => {
    it('should include provided context', () => {
      const error = new Error('Test error');
      const result = categorizeError(error, { toolName: 'read', path: '/test' });

      expect(result.context).toEqual({ toolName: 'read', path: '/test' });
    });

    it('should preserve original error as cause', () => {
      const error = new Error('Original error');
      const result = categorizeError(error);

      expect(result.cause).toBe(error);
    });

    it('should handle non-Error values', () => {
      const result = categorizeError('string error');

      expect(result.message).toBe('string error');
      expect(result.cause).toBeInstanceOf(Error);
    });
  });

  describe('unknown errors', () => {
    it('should categorize unknown errors', () => {
      const error = new Error('Something completely unexpected');
      const result = categorizeError(error);

      expect(result.category).toBe(LogErrorCategory.UNKNOWN);
      expect(result.code).toBe(LogErrorCodes.UNKNOWN);
      expect(result.recoverable).toBe(false);
      expect(result.retryable).toBe(false);
    });
  });
});

describe('createStructuredError', () => {
  it('should create a structured error with required fields', () => {
    const result = createStructuredError(
      LogErrorCategory.TOOL_EXECUTION,
      LogErrorCodes.TOOL_TIMEOUT,
      'Tool execution timed out'
    );

    expect(result.category).toBe(LogErrorCategory.TOOL_EXECUTION);
    expect(result.code).toBe(LogErrorCodes.TOOL_TIMEOUT);
    expect(result.message).toBe('Tool execution timed out');
    expect(result.context).toEqual({});
    expect(result.recoverable).toBe(false);
    expect(result.retryable).toBe(false);
  });

  it('should accept optional fields', () => {
    const cause = new Error('Original');
    const result = createStructuredError(
      LogErrorCategory.PROVIDER_API,
      LogErrorCodes.PAPI_OVERLOADED,
      'API overloaded',
      {
        context: { model: 'claude-3', attempt: 2 },
        recoverable: true,
        retryable: true,
        cause,
      }
    );

    expect(result.context).toEqual({ model: 'claude-3', attempt: 2 });
    expect(result.recoverable).toBe(true);
    expect(result.retryable).toBe(true);
    expect(result.cause).toBe(cause);
  });
});
