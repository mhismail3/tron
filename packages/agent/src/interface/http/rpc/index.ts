/**
 * @fileoverview Server RPC module
 *
 * Provides the RPC infrastructure for the server:
 * - Domain handlers organized by namespace
 * - Middleware for cross-cutting concerns
 * - Registry for method dispatch
 *
 * @migration This wraps the existing rpc/ module during transition.
 */

// Re-export from existing RPC module
export * from '../../rpc/index.js';

// New domain structure (during migration, re-exports existing handlers)
export * from './domains/index.js';

// New middleware
export * from './middleware/idempotency/index.js';

// Run correlation
export * from './correlation/index.js';
