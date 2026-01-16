/**
 * @fileoverview System RPC Method Schemas
 *
 * Zod schemas for validating system.* RPC method parameters.
 */

import { z } from 'zod';
import { commonSchemas, createSchemaRegistry, type SchemaRegistry } from '../middleware/validation.js';

// =============================================================================
// Schemas
// =============================================================================

/**
 * system.ping params (empty)
 */
export const systemPingSchema = commonSchemas.empty;

/**
 * system.getInfo params (empty)
 */
export const systemGetInfoSchema = commonSchemas.empty;

/**
 * system.shutdown params
 */
export const systemShutdownSchema = z.object({
  force: z.boolean().optional(),
  timeout: z.number().int().min(0).optional(),
}).optional().default({});

// =============================================================================
// Registry
// =============================================================================

/**
 * Create system schema registry
 */
export function createSystemSchemas(): SchemaRegistry {
  return createSchemaRegistry({
    'system.ping': systemPingSchema,
    'system.getInfo': systemGetInfoSchema,
    'system.shutdown': systemShutdownSchema,
  });
}
