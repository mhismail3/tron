/**
 * @fileoverview Tests for Validation Middleware
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { z } from 'zod';
import {
  createValidationMiddleware,
  createSchemaRegistry,
  mergeSchemaRegistries,
  zodErrorToValidationErrors,
  formatValidationMessage,
  commonSchemas,
  type SchemaRegistry,
  type ValidationError,
} from '../validation.js';
import type { RpcRequest, RpcResponse } from '../types.js';
import type { MiddlewareNext } from '../index.js';

describe('Validation Middleware', () => {
  let schemas: SchemaRegistry;
  let next: MiddlewareNext;
  let nextResponse: RpcResponse;

  beforeEach(() => {
    nextResponse = {
      id: '1',
      success: true,
      result: { ok: true },
    };
    next = vi.fn().mockResolvedValue(nextResponse);
    schemas = new Map();
  });

  describe('createValidationMiddleware', () => {
    it('should pass through when no schema is registered for method', async () => {
      const middleware = createValidationMiddleware(schemas);
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'unknown.method',
        params: { anything: 'goes' },
      };

      const response = await middleware(request, next);

      expect(next).toHaveBeenCalledWith(request);
      expect(response).toBe(nextResponse);
    });

    it('should validate params against schema', async () => {
      schemas.set('test.method', z.object({
        name: z.string(),
        count: z.number(),
      }));

      const middleware = createValidationMiddleware(schemas);
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'test.method',
        params: { name: 'test', count: 42 },
      };

      const response = await middleware(request, next);

      expect(next).toHaveBeenCalled();
      expect(response).toBe(nextResponse);
    });

    it('should return INVALID_PARAMS for missing required field', async () => {
      schemas.set('test.method', z.object({
        name: z.string(),
      }));

      const middleware = createValidationMiddleware(schemas);
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'test.method',
        params: {},
      };

      const response = await middleware(request, next);

      expect(next).not.toHaveBeenCalled();
      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('name');
    });

    it('should return INVALID_PARAMS for wrong type', async () => {
      schemas.set('test.method', z.object({
        count: z.number(),
      }));

      const middleware = createValidationMiddleware(schemas);
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'test.method',
        params: { count: 'not a number' },
      };

      const response = await middleware(request, next);

      expect(next).not.toHaveBeenCalled();
      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
    });

    it('should include validation errors in details', async () => {
      schemas.set('test.method', z.object({
        name: z.string(),
        count: z.number(),
      }));

      const middleware = createValidationMiddleware(schemas);
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'test.method',
        params: { name: 123, count: 'wrong' },
      };

      const response = await middleware(request, next);

      expect(response.error?.details).toBeDefined();
      expect((response.error?.details as any).errors).toHaveLength(2);
    });

    it('should handle undefined params as empty object', async () => {
      schemas.set('test.method', z.object({
        optional: z.string().optional(),
      }));

      const middleware = createValidationMiddleware(schemas);
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'test.method',
      };

      const response = await middleware(request, next);

      expect(next).toHaveBeenCalled();
      expect(response).toBe(nextResponse);
    });

    it('should pass validated data to next', async () => {
      schemas.set('test.method', z.object({
        count: z.number().default(0),
      }));

      const middleware = createValidationMiddleware(schemas);
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'test.method',
        params: {},
      };

      await middleware(request, next);

      expect(next).toHaveBeenCalledWith(
        expect.objectContaining({
          params: { count: 0 },
        })
      );
    });

    it('should use custom error formatter when provided', async () => {
      schemas.set('test.method', z.object({
        name: z.string(),
      }));

      const customFormat = vi.fn().mockReturnValue({
        id: '1',
        success: false,
        error: { code: 'CUSTOM_ERROR', message: 'Custom message' },
      });

      const middleware = createValidationMiddleware(schemas, {
        formatError: customFormat,
      });

      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'test.method',
        params: {},
      };

      const response = await middleware(request, next);

      expect(customFormat).toHaveBeenCalled();
      expect(response.error?.code).toBe('CUSTOM_ERROR');
    });

    it('should preserve request id in error response', async () => {
      schemas.set('test.method', z.object({
        name: z.string(),
      }));

      const middleware = createValidationMiddleware(schemas);
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: 'my-unique-id',
        method: 'test.method',
        params: {},
      };

      const response = await middleware(request, next);

      expect(response.id).toBe('my-unique-id');
    });
  });

  describe('createSchemaRegistry', () => {
    it('should create registry from object', () => {
      const registry = createSchemaRegistry({
        'method.a': z.object({ a: z.string() }),
        'method.b': z.object({ b: z.number() }),
      });

      expect(registry.has('method.a')).toBe(true);
      expect(registry.has('method.b')).toBe(true);
      expect(registry.size).toBe(2);
    });
  });

  describe('mergeSchemaRegistries', () => {
    it('should merge multiple registries', () => {
      const registry1 = createSchemaRegistry({
        'method.a': z.object({ a: z.string() }),
      });
      const registry2 = createSchemaRegistry({
        'method.b': z.object({ b: z.number() }),
      });

      const merged = mergeSchemaRegistries(registry1, registry2);

      expect(merged.has('method.a')).toBe(true);
      expect(merged.has('method.b')).toBe(true);
      expect(merged.size).toBe(2);
    });

    it('should override with later registry schemas', () => {
      const registry1 = createSchemaRegistry({
        'method.a': z.object({ a: z.string() }),
      });
      const registry2 = createSchemaRegistry({
        'method.a': z.object({ a: z.number() }),
      });

      const merged = mergeSchemaRegistries(registry1, registry2);
      const schema = merged.get('method.a');

      // Schema from registry2 should win
      expect(schema?.safeParse({ a: 123 }).success).toBe(true);
      expect(schema?.safeParse({ a: 'string' }).success).toBe(false);
    });
  });

  describe('zodErrorToValidationErrors', () => {
    it('should convert Zod error to ValidationError array', () => {
      const schema = z.object({
        name: z.string(),
        nested: z.object({
          value: z.number(),
        }),
      });

      const result = schema.safeParse({ name: 123, nested: { value: 'wrong' } });
      const errors = zodErrorToValidationErrors(result.error!);

      expect(errors).toHaveLength(2);
      expect(errors.some((e) => e.path === 'name')).toBe(true);
      expect(errors.some((e) => e.path === 'nested.value')).toBe(true);
    });

    it('should handle root-level errors', () => {
      const schema = z.string();
      const result = schema.safeParse(123);
      const errors = zodErrorToValidationErrors(result.error!);

      expect(errors).toHaveLength(1);
      expect(errors[0]?.path).toBe('params');
    });
  });

  describe('formatValidationMessage', () => {
    it('should format single error without path prefix when path is params', () => {
      const errors: ValidationError[] = [
        { path: 'params', message: 'Expected string', code: 'invalid_type' },
      ];

      const message = formatValidationMessage(errors);
      expect(message).toBe('Expected string');
    });

    it('should format single error with path prefix', () => {
      const errors: ValidationError[] = [
        { path: 'name', message: 'Required', code: 'invalid_type' },
      ];

      const message = formatValidationMessage(errors);
      expect(message).toBe('name: Required');
    });

    it('should format multiple errors', () => {
      const errors: ValidationError[] = [
        { path: 'name', message: 'Required', code: 'invalid_type' },
        { path: 'count', message: 'Must be number', code: 'invalid_type' },
      ];

      const message = formatValidationMessage(errors);
      expect(message).toBe('name: Required; count: Must be number');
    });
  });

  describe('commonSchemas', () => {
    it('should validate sessionId as UUID', () => {
      expect(commonSchemas.sessionId.safeParse('not-a-uuid').success).toBe(false);
      expect(
        commonSchemas.sessionId.safeParse('123e4567-e89b-12d3-a456-426614174000').success
      ).toBe(true);
    });

    it('should validate eventId as non-empty string', () => {
      expect(commonSchemas.eventId.safeParse('').success).toBe(false);
      expect(commonSchemas.eventId.safeParse('evt-123').success).toBe(true);
    });

    it('should validate path as non-empty string', () => {
      expect(commonSchemas.path.safeParse('').success).toBe(false);
      expect(commonSchemas.path.safeParse('/some/path').success).toBe(true);
    });

    it('should validate limit within bounds', () => {
      expect(commonSchemas.limit.safeParse(0).success).toBe(false);
      expect(commonSchemas.limit.safeParse(1001).success).toBe(false);
      expect(commonSchemas.limit.safeParse(50).success).toBe(true);
      expect(commonSchemas.limit.safeParse(undefined).success).toBe(true);
    });

    it('should validate offset as non-negative', () => {
      expect(commonSchemas.offset.safeParse(-1).success).toBe(false);
      expect(commonSchemas.offset.safeParse(0).success).toBe(true);
      expect(commonSchemas.offset.safeParse(undefined).success).toBe(true);
    });

    it('should validate empty object strictly', () => {
      expect(commonSchemas.empty.safeParse({}).success).toBe(true);
      expect(commonSchemas.empty.safeParse({ extra: 'field' }).success).toBe(false);
    });
  });
});
