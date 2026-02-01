/**
 * @fileoverview Message domain - Message operations
 *
 * Handles message deletion and management.
 *
 * @migration Re-exports from rpc/handlers during transition
 */

// Re-export handlers
export {
  handleMessageDelete,
  createMessageHandlers,
} from '../../../../rpc/handlers/message.handler.js';

// Re-export types
export type {
  MessageDeleteParams,
  MessageDeleteResult,
} from '../../../../rpc/types/message.js';
