/**
 * @fileoverview Message domain - Message operations
 *
 * Handles message deletion and management.
 */

// Re-export handler factory
export { createMessageHandlers } from '@interface/rpc/handlers/message.handler.js';

// Re-export types
export type {
  MessageDeleteParams,
  MessageDeleteResult,
} from '@interface/rpc/types/message.js';
