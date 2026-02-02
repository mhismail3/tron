/**
 * @fileoverview RPC Schema Registry
 *
 * Exports all namespace schemas and provides a combined registry
 * for use with the validation middleware.
 */

import { mergeSchemaRegistries, type SchemaRegistry } from '../middleware/validation.js';
import { createSessionSchemas } from './session.js';
import { createSystemSchemas } from './system.js';

// Re-export individual schemas
export * from './session.js';
export * from './system.js';

// =============================================================================
// Combined Registry
// =============================================================================

/**
 * Create the combined schema registry with all namespace schemas
 *
 * @example
 * ```typescript
 * import { createAllSchemas } from './schemas/index.js';
 * import { createValidationMiddleware } from './middleware/validation.js';
 *
 * const schemas = createAllSchemas();
 * registry.use(createValidationMiddleware(schemas));
 * ```
 */
export function createAllSchemas(): SchemaRegistry {
  return mergeSchemaRegistries(
    createSessionSchemas(),
    createSystemSchemas()
    // Add more namespace schemas as they are created:
    // createAgentSchemas(),
    // createModelSchemas(),
    // etc.
  );
}
