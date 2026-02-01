/**
 * @fileoverview Communication tools index
 *
 * Tools for inter-agent communication.
 */

export { SendMessageTool } from './send-message.js';
export type { SendMessageToolConfig } from './send-message.js';
export { ReceiveMessagesTool } from './receive-messages.js';
export type { ReceiveMessagesToolConfig } from './receive-messages.js';
export type {
  SendMessageParams,
  SendMessageResult,
  ReceiveMessagesParams,
  ReceiveMessagesResult,
  ReceivedMessage,
} from './types.js';
