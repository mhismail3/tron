/**
 * @fileoverview Receive Messages Tool
 *
 * Allows agents to receive messages from other agent sessions.
 */

import type { TronTool, TronToolResult } from '@core/types/index.js';
import type { MessageBus } from '@infrastructure/communication/bus/types.js';
import type { ReceiveMessagesParams, ReceiveMessagesResult, ReceivedMessage } from './types.js';
import { createLogger } from '@infrastructure/logging/index.js';

const logger = createLogger('tool:receive-messages');

/**
 * Configuration for ReceiveMessagesTool
 */
export interface ReceiveMessagesToolConfig {
  /** The current session ID */
  sessionId: string;
  /** Message bus instance */
  messageBus: MessageBus;
  /** Default limit for messages returned */
  defaultLimit?: number;
}

/**
 * Tool for receiving messages from other agent sessions
 */
export class ReceiveMessagesTool implements TronTool<ReceiveMessagesParams, ReceiveMessagesResult> {
  readonly name = 'receive_messages';
  readonly description =
    'Check for messages sent to this session from other agents. Can filter by type or sender.';

  readonly parameters = {
    type: 'object' as const,
    properties: {
      type: {
        type: 'string' as const,
        description: 'Filter by message type',
      },
      fromSessionId: {
        type: 'string' as const,
        description: 'Filter by sender session ID',
      },
      limit: {
        type: 'number' as const,
        description: 'Maximum messages to return (default: 20)',
      },
      markAsRead: {
        type: 'boolean' as const,
        description: 'Whether to mark returned messages as read (default: true)',
      },
    },
    required: [] as string[],
  };

  private config: ReceiveMessagesToolConfig;

  constructor(config: ReceiveMessagesToolConfig) {
    this.config = {
      defaultLimit: 20,
      ...config,
    };
  }

  async execute(params: ReceiveMessagesParams): Promise<TronToolResult<ReceiveMessagesResult>> {
    const { type, fromSessionId, limit, markAsRead = true } = params;

    try {
      // Get unread count first
      const unreadCount = await this.config.messageBus.getUnreadCount(this.config.sessionId);

      // Fetch messages
      const messages = await this.config.messageBus.receive(
        this.config.sessionId,
        {
          type,
          fromSessionId,
          unreadOnly: true,
        },
        limit ?? this.config.defaultLimit
      );

      // Transform to result format
      const receivedMessages: ReceivedMessage[] = messages.map((m) => ({
        id: m.id,
        fromSessionId: m.fromSessionId,
        type: m.type,
        payload: m.payload,
        timestamp: m.timestamp,
        replyTo: m.replyTo,
      }));

      // Mark as read if requested
      if (markAsRead && messages.length > 0) {
        await this.config.messageBus.markAsRead(messages.map((m) => m.id));
      }

      logger.debug('Messages retrieved', {
        count: receivedMessages.length,
        unreadCount,
        sessionId: this.config.sessionId,
      });

      const result: ReceiveMessagesResult = {
        messages: receivedMessages,
        unreadCount,
      };

      if (receivedMessages.length === 0) {
        return {
          content: `No messages found. Total unread: ${unreadCount}`,
          details: result,
        };
      }

      // Format message summary
      const summary = receivedMessages
        .map((m) => `- [${m.type}] from ${m.fromSessionId}: ${JSON.stringify(m.payload).slice(0, 100)}`)
        .join('\n');

      return {
        content: `Found ${receivedMessages.length} messages (${unreadCount} unread total):\n${summary}`,
        details: result,
      };
    } catch (error) {
      const errorMsg = error instanceof Error ? error.message : 'Failed to receive messages';
      logger.error('Failed to receive messages', { error: errorMsg });
      return {
        content: `Error: ${errorMsg}`,
        isError: true,
        details: {
          messages: [],
          unreadCount: 0,
        },
      };
    }
  }
}
