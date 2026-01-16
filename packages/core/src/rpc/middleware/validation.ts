/**
 * @fileoverview Validation Middleware
 *
 * Provides schema-based parameter validation for RPC handlers using Zod.
 * Validates request params against registered schemas before handlers execute.
 */

import { z, type ZodSchema, type ZodError } from 'zod';
import type { RpcRequest, RpcResponse } from '../types.js';
import type { Middleware, MiddlewareNext } from './index.js';
import { MethodRegistry } from '../registry.js';

// =============================================================================
// Types
// =============================================================================

/**
 * Schema registry maps method names to Zod schemas
 */
export type SchemaRegistry = Map<string, ZodSchema>;

/**
 * Validation result
 */
export interface ValidationResult {
  success: boolean;
  data?: unknown;
  errors?: ValidationError[];
}

/**
 * Validation error details
 */
export interface ValidationError {
  path: string;
  message: string;
  code: string;
}

/**
 * Options for validation middleware
 */
export interface ValidationMiddlewareOptions {
  /** Whether to strip unknown keys from validated objects (default: false) */
  stripUnknown?: boolean;
  /** Custom error formatter */
  formatError?: (errors: ValidationError[], requestId: string | number) => RpcResponse;
}

// =============================================================================
// Utilities
// =============================================================================

/**
 * Convert Zod error to ValidationError array
 */
export function zodErrorToValidationErrors(error: ZodError): ValidationError[] {
  return error.errors.map((issue) => ({
    path: issue.path.join('.') || 'params',
    message: issue.message,
    code: issue.code,
  }));
}

/**
 * Format validation errors into a human-readable message
 */
export function formatValidationMessage(errors: ValidationError[]): string {
  if (errors.length === 1) {
    const err = errors[0]!;
    return err.path === 'params' ? err.message : `${err.path}: ${err.message}`;
  }
  return errors.map((e) => `${e.path}: ${e.message}`).join('; ');
}

/**
 * Default error formatter
 */
function defaultFormatError(errors: ValidationError[], requestId: string | number): RpcResponse {
  return MethodRegistry.errorResponse(
    requestId,
    'INVALID_PARAMS',
    formatValidationMessage(errors),
    { errors }
  );
}

// =============================================================================
// Middleware
// =============================================================================

/**
 * Create a validation middleware that validates params against registered schemas
 *
 * @param schemas - Map of method names to Zod schemas
 * @param options - Validation options
 * @returns Middleware function
 *
 * @example
 * ```typescript
 * const schemas = new Map([
 *   ['session.create', z.object({ workingDirectory: z.string() })],
 *   ['session.resume', z.object({ sessionId: z.string() })],
 * ]);
 *
 * registry.use(createValidationMiddleware(schemas));
 * ```
 */
export function createValidationMiddleware(
  schemas: SchemaRegistry,
  options: ValidationMiddlewareOptions = {}
): Middleware {
  const { stripUnknown = false, formatError = defaultFormatError } = options;

  return async (request: RpcRequest, next: MiddlewareNext): Promise<RpcResponse> => {
    const schema = schemas.get(request.method);

    // If no schema registered, pass through
    if (!schema) {
      return next(request);
    }

    // Validate params
    const params = request.params ?? {};
    const parseOptions = stripUnknown ? { strict: false } : undefined;

    try {
      const result = schema.safeParse(params, parseOptions);

      if (!result.success) {
        const errors = zodErrorToValidationErrors(result.error);
        return formatError(errors, request.id);
      }

      // Pass validated data (potentially transformed) to handler
      const validatedRequest = {
        ...request,
        params: result.data,
      };

      return next(validatedRequest);
    } catch (error) {
      // Handle unexpected errors
      return MethodRegistry.errorResponse(
        request.id,
        'VALIDATION_ERROR',
        error instanceof Error ? error.message : 'Validation failed'
      );
    }
  };
}

// =============================================================================
// Schema Builder Utilities
// =============================================================================

/**
 * Create a schema registry from an object mapping methods to schemas
 *
 * @example
 * ```typescript
 * const schemas = createSchemaRegistry({
 *   'session.create': z.object({ workingDirectory: z.string() }),
 *   'session.resume': z.object({ sessionId: z.string() }),
 * });
 * ```
 */
export function createSchemaRegistry(
  schemas: Record<string, ZodSchema>
): SchemaRegistry {
  return new Map(Object.entries(schemas));
}

/**
 * Merge multiple schema registries
 */
export function mergeSchemaRegistries(...registries: SchemaRegistry[]): SchemaRegistry {
  const merged = new Map<string, ZodSchema>();
  for (const registry of registries) {
    for (const [method, schema] of registry) {
      merged.set(method, schema);
    }
  }
  return merged;
}

// =============================================================================
// Common Schema Patterns
// =============================================================================

/**
 * Common Zod schemas for reuse
 */
export const commonSchemas = {
  /** Session ID (UUID string) */
  sessionId: z.string().uuid('sessionId must be a valid UUID'),

  /** Event ID (string) */
  eventId: z.string().min(1, 'eventId is required'),

  /** File/directory path */
  path: z.string().min(1, 'path is required'),

  /** Non-empty string */
  nonEmpty: z.string().min(1),

  /** Optional pagination limit */
  limit: z.number().int().min(1).max(1000).optional(),

  /** Optional pagination offset */
  offset: z.number().int().min(0).optional(),

  /** Optional boolean */
  optionalBoolean: z.boolean().optional(),

  /** Empty params (methods that take no params) */
  empty: z.object({}).strict(),
};
