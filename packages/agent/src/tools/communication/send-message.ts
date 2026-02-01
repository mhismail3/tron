/**
 * @fileoverview Send Message Tool
 *
 * Allows agents to send messages to other agent sessions.
 */

import type { TronTool, TronToolResult } from '../../types/index.js';
import type { MessageBus } from '../../communication/bus/types.js';
import type { SendMessageParams, SendMessageResult } from './types.js';
import { createLogger } from '../../logging/index.js';

const logger = createLogger('tool:send-message');

/**
 * Configuration for SendMessageTool
 */
export interface SendMessageToolConfig {
  /** The current session ID (sender identity) */
  sessionId: string;
  /** Message bus instance */
  messageBus: MessageBus;
  /** Default timeout for waiting on replies (ms) */
  defaultReplyTimeout?: number;
}

/**
 * Tool for sending messages to other agent sessions
 */
export class SendMessageTool implements TronTool<SendMessageParams, SendMessageResult> {
  readonly name = 'send_message';
  readonly description = 'Send a message to another agent session. Can optionally wait for a reply.';

  readonly parameters = {
    type: 'object' as const,
    properties: {
      targetSessionId: {
        type: 'string' as const,
        description: 'Session ID to send the message to',
      },
      messageType: {
        type: 'string' as const,
        description: 'Type of message for routing (e.g., "task", "query", "notification")',
      },
      payload: {
        type: 'object' as const,
        description: 'Message content/data',
      },
      waitForReply: {
        type: 'boolean' as const,
        description: 'Whether to wait for a reply message',
      },
      timeout: {
        type: 'number' as const,
        description: 'Timeout in milliseconds when waiting for reply (default: 30000)',
      },
    },
    required: ['targetSessionId', 'messageType', 'payload'] as string[],
  };

  private config: SendMessageToolConfig;

  constructor(config: SendMessageToolConfig) {
    this.config = {
      defaultReplyTimeout: 30000,
      ...config,
    };
  }

  async execute(params: SendMessageParams): Promise<TronToolResult<SendMessageResult>> {
    const { targetSessionId, messageType, payload, waitForReply, timeout } = params;

    try {
      // Send the message
      const messageId = await this.config.messageBus.send(targetSessionId, {
        type: messageType,
        payload,
      });

      logger.debug('Message sent', {
        messageId,
        targetSessionId,
        messageType,
      });

      // If not waiting for reply, return immediately
      if (!waitForReply) {
        const result: SendMessageResult = {
          success: true,
          messageId,
        };
        return {
          content: `Message sent successfully (id: ${messageId})`,
          details: result,
        };
      }

      // Wait for a reply
      const replyTimeout = timeout ?? this.config.defaultReplyTimeout ?? 30000;
      const startTime = Date.now();

      while (Date.now() - startTime < replyTimeout) {
        // Check for replies to our message
        const messages = await this.config.messageBus.receive(
          this.config.sessionId,
          {
            fromSessionId: targetSessionId,
            unreadOnly: true,
          },
          10
        );

        // Find a reply to our message
        const reply = messages.find((m) => m.replyTo === messageId);
        if (reply) {
          await this.config.messageBus.markAsRead([reply.id]);
          const result: SendMessageResult = {
            success: true,
            messageId,
            reply: {
              messageId: reply.id,
              payload: reply.payload,
            },
          };
          return {
            content: `Message sent and reply received (reply id: ${reply.id})`,
            details: result,
          };
        }

        // Wait a bit before checking again
        await new Promise((resolve) => setTimeout(resolve, 500));
      }

      // Timeout waiting for reply
      const result: SendMessageResult = {
        success: true,
        messageId,
        error: `Timeout waiting for reply after ${replyTimeout}ms`,
      };
      return {
        content: `Message sent (id: ${messageId}) but timed out waiting for reply`,
        details: result,
      };
    } catch (error) {
      const errorMsg = error instanceof Error ? error.message : 'Failed to send message';
      logger.error('Failed to send message', { error: errorMsg });
      return {
        content: `Error: ${errorMsg}`,
        isError: true,
        details: {
          success: false,
          messageId: '',
          error: errorMsg,
        },
      };
    }
  }
}
