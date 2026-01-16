/**
 * @fileoverview Session RPC Method Schemas
 *
 * Zod schemas for validating session.* RPC method parameters.
 */

import { z } from 'zod';
import { commonSchemas, createSchemaRegistry, type SchemaRegistry } from '../middleware/validation.js';

// =============================================================================
// Schemas
// =============================================================================

/**
 * session.create params
 */
export const sessionCreateSchema = z.object({
  workingDirectory: z.string().min(1, 'workingDirectory is required'),
  initialModel: z.string().optional(),
  resumeIfExists: z.boolean().optional(),
  title: z.string().optional(),
  metadata: z.record(z.unknown()).optional(),
});

/**
 * session.resume params
 */
export const sessionResumeSchema = z.object({
  sessionId: commonSchemas.sessionId,
});

/**
 * session.list params (all optional)
 */
export const sessionListSchema = z.object({
  workingDirectory: z.string().optional(),
  isActive: z.boolean().optional(),
  limit: commonSchemas.limit,
  offset: commonSchemas.offset,
}).optional().default({});

/**
 * session.delete params
 */
export const sessionDeleteSchema = z.object({
  sessionId: commonSchemas.sessionId,
});

/**
 * session.fork params
 */
export const sessionForkSchema = z.object({
  sessionId: commonSchemas.sessionId,
  fromEventId: z.string().optional(),
});

// =============================================================================
// Registry
// =============================================================================

/**
 * Create session schema registry
 */
export function createSessionSchemas(): SchemaRegistry {
  return createSchemaRegistry({
    'session.create': sessionCreateSchema,
    'session.resume': sessionResumeSchema,
    'session.list': sessionListSchema,
    'session.delete': sessionDeleteSchema,
    'session.fork': sessionForkSchema,
  });
}
