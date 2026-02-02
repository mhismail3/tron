/**
 * @fileoverview Tests for RPC error types
 *
 * TDD: Tests for typed RPC error hierarchy
 */

import { describe, it, expect } from 'vitest';
import {
  RpcError,
  RpcErrorCode,
  SessionNotFoundError,
  SessionNotActiveError,
  ManagerNotAvailableError,
  InvalidParamsError,
  FileNotFoundError,
  InternalError,
  isRpcError,
  toRpcErrorResponse,
} from '../rpc-errors.js';

describe('RpcError hierarchy', () => {
  describe('RpcError base class', () => {
    it('extends Error with code property', () => {
      const err = new RpcError(RpcErrorCode.INTERNAL_ERROR, 'Test error');
      expect(err).toBeInstanceOf(Error);
      expect(err.code).toBe('INTERNAL_ERROR');
      expect(err.message).toBe('Test error');
      expect(err.name).toBe('RpcError');
    });
  });

  describe('SessionNotFoundError', () => {
    it('has correct code and message', () => {
      const err = new SessionNotFoundError('sess_123');
      expect(err.code).toBe('SESSION_NOT_FOUND');
      expect(err.message).toContain('sess_123');
      expect(err).toBeInstanceOf(RpcError);
      expect(err).toBeInstanceOf(Error);
    });
  });

  describe('SessionNotActiveError', () => {
    it('has correct code and message', () => {
      const err = new SessionNotActiveError('sess_456');
      expect(err.code).toBe('SESSION_NOT_ACTIVE');
      expect(err.message).toContain('sess_456');
      expect(err).toBeInstanceOf(RpcError);
    });
  });

  describe('ManagerNotAvailableError', () => {
    it('has correct code and message', () => {
      const err = new ManagerNotAvailableError('contextManager');
      expect(err.code).toBe('NOT_AVAILABLE');
      expect(err.message).toContain('contextManager');
      expect(err).toBeInstanceOf(RpcError);
    });
  });

  describe('InvalidParamsError', () => {
    it('has correct code and message', () => {
      const err = new InvalidParamsError('sessionId is required');
      expect(err.code).toBe('INVALID_PARAMS');
      expect(err.message).toBe('sessionId is required');
      expect(err).toBeInstanceOf(RpcError);
    });
  });

  describe('FileNotFoundError', () => {
    it('has correct code and message', () => {
      const err = new FileNotFoundError('/path/to/file.txt');
      expect(err.code).toBe('FILE_NOT_FOUND');
      expect(err.message).toContain('/path/to/file.txt');
      expect(err).toBeInstanceOf(RpcError);
    });
  });

  describe('InternalError', () => {
    it('has correct code and message', () => {
      const err = new InternalError('Something went wrong');
      expect(err.code).toBe('INTERNAL_ERROR');
      expect(err.message).toBe('Something went wrong');
      expect(err).toBeInstanceOf(RpcError);
    });
  });

  describe('isRpcError type guard', () => {
    it('returns true for RpcError instances', () => {
      expect(isRpcError(new RpcError(RpcErrorCode.INTERNAL_ERROR, 'test'))).toBe(true);
      expect(isRpcError(new SessionNotFoundError('x'))).toBe(true);
      expect(isRpcError(new InvalidParamsError('x'))).toBe(true);
    });

    it('returns false for generic Error', () => {
      expect(isRpcError(new Error('generic'))).toBe(false);
    });

    it('returns false for non-errors', () => {
      expect(isRpcError(null)).toBe(false);
      expect(isRpcError(undefined)).toBe(false);
      expect(isRpcError('string')).toBe(false);
      expect(isRpcError({ code: 'fake' })).toBe(false);
    });
  });

  describe('toRpcErrorResponse', () => {
    it('converts error to response format', () => {
      const err = new SessionNotFoundError('sess_123');
      const response = toRpcErrorResponse('req_1', err);

      expect(response.id).toBe('req_1');
      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('SESSION_NOT_FOUND');
      expect(response.error?.message).toContain('sess_123');
    });

    it('works with numeric request id', () => {
      const err = new InvalidParamsError('missing field');
      const response = toRpcErrorResponse(123, err);

      expect(response.id).toBe(123);
      expect(response.error?.code).toBe('INVALID_PARAMS');
    });
  });
});

describe('RpcErrorCode enum', () => {
  it('contains all expected codes', () => {
    expect(RpcErrorCode.INVALID_PARAMS).toBe('INVALID_PARAMS');
    expect(RpcErrorCode.SESSION_NOT_FOUND).toBe('SESSION_NOT_FOUND');
    expect(RpcErrorCode.SESSION_NOT_ACTIVE).toBe('SESSION_NOT_ACTIVE');
    expect(RpcErrorCode.NOT_AVAILABLE).toBe('NOT_AVAILABLE');
    expect(RpcErrorCode.INTERNAL_ERROR).toBe('INTERNAL_ERROR');
    expect(RpcErrorCode.FILE_NOT_FOUND).toBe('FILE_NOT_FOUND');
    expect(RpcErrorCode.BROWSER_ERROR).toBe('BROWSER_ERROR');
    expect(RpcErrorCode.SKILL_ERROR).toBe('SKILL_ERROR');
  });
});
