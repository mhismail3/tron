/**
 * @fileoverview Communication domain - Inter-agent messaging
 *
 * Provides RPC handlers for agent-to-agent communication.
 *
 * @see src/communication/bus/ for the underlying message bus implementation
 */

// Re-export message bus types and factory
export {
  type MessageBus,
  type AgentMessage,
  type MessageFilter,
  type MessageHandler,
  type MessageBusConfig,
  type Unsubscribe,
  InMemoryMessageBus,
  createMessageBus,
} from '../../../../communication/bus/index.js';
