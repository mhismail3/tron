/**
 * @fileoverview HTTP gateway module
 *
 * Provides HTTP API endpoints and SSE event streaming.
 *
 * Components:
 * - health.ts: Health check endpoint
 * - api.ts: REST API endpoints
 *
 * @migration Health server moved from gateway/health.ts
 */

// Re-export health server during migration
export {
  HealthServer,
  type HealthServerConfig,
} from '../../../gateway/health.js';

// HTTP API
export * from './types.js';
export * from './api.js';

// Webhook handler
export * from './webhook.js';
