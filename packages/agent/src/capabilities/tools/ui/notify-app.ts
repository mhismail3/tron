/**
 * @fileoverview NotifyApp Tool
 *
 * Sends push notifications to the Tron iOS app via APNS.
 * Useful for notifying users when:
 * - Long-running tasks complete
 * - Important results need attention
 * - User input is required (when app may be backgrounded)
 */

import type { TronTool, TronToolResult } from '@core/types/index.js';
import { createLogger } from '@infrastructure/logging/index.js';

const logger = createLogger('tool:notify-app');

// =============================================================================
// Types
// =============================================================================

/**
 * Input parameters for NotifyApp tool
 */
export interface NotifyAppParams {
  /** Notification title (max 50 characters recommended) */
  title: string;
  /** Notification body (max 200 characters recommended) */
  body: string;
  /** Markdown-formatted rich content for the detail sheet in the iOS app.
   * This content is NOT sent via APNS push - it's stored with the tool call
   * and rendered when the user taps the notification chip in the chat. */
  sheetContent?: string;
  /** Custom data to include with the notification */
  data?: Record<string, string>;
  /** Notification priority */
  priority?: 'high' | 'normal';
  /** Sound name (default: 'default') */
  sound?: string;
  /** Badge count to display on app icon */
  badge?: number;
}

/**
 * Result of sending a notification
 */
export interface NotifyAppResult {
  /** Number of devices notified successfully */
  successCount: number;
  /** Number of devices that failed */
  failureCount: number;
  /** Error messages for any failures */
  errors?: string[];
}

/**
 * Callback type for sending notifications
 */
export type NotifyAppCallback = (
  sessionId: string,
  notification: {
    title: string;
    body: string;
    data?: Record<string, string>;
    priority?: 'high' | 'normal';
    sound?: string;
    badge?: number;
  },
  /** The tool call ID - used for deep linking so iOS can scroll to the notification */
  toolCallId: string
) => Promise<NotifyAppResult>;

/**
 * Configuration for NotifyApp tool
 */
export interface NotifyAppToolConfig {
  /** Session ID for looking up device tokens */
  sessionId: string;
  /** Callback to send the notification */
  onNotify: NotifyAppCallback;
}

// =============================================================================
// Tool Implementation
// =============================================================================

/**
 * NotifyApp tool for sending push notifications to the iOS app.
 *
 * The agent can use this tool to:
 * - Notify the user when a long-running task completes
 * - Alert the user when important results are ready
 * - Request user attention when input is needed
 */
export class NotifyAppTool implements TronTool<NotifyAppParams, NotifyAppResult> {
  readonly name = 'NotifyApp';
  readonly label = 'Push Notification';
  readonly description = `Send a push notification to the Tron iOS app.

## When to Use
- Long-running task has completed and the user should know
- Important results are ready that need user attention
- User input is required and the app may be backgrounded
- Agent wants to prompt user to return to the conversation

## When NOT to Use
- For routine progress updates (use text output instead)
- When the user is actively engaged in the conversation
- For trivial or unimportant information

## Guidelines
- Keep titles concise (max 50 chars)
- Keep body text brief (max 200 chars)
- Use high priority sparingly (only for urgent notifications)
- Include relevant context in the body to help user understand why they're being notified`;

  readonly parameters = {
    type: 'object' as const,
    properties: {
      title: {
        type: 'string' as const,
        description: 'Notification title (max 50 chars recommended)',
        maxLength: 50,
      },
      body: {
        type: 'string' as const,
        description: 'Notification body (max 200 chars recommended)',
        maxLength: 200,
      },
      sheetContent: {
        type: 'string' as const,
        description:
          'Markdown-formatted rich content for the detail sheet. Shown when user taps notification chip in chat. Use for detailed info that does not fit in push notification.',
      },
      data: {
        type: 'object' as const,
        description: 'Optional custom data to include (key-value string pairs)',
        additionalProperties: { type: 'string' as const },
      },
      priority: {
        type: 'string' as const,
        enum: ['high', 'normal'],
        description: 'Notification priority (default: normal)',
        default: 'normal',
      },
      sound: {
        type: 'string' as const,
        description: 'Sound name (default: "default")',
        default: 'default',
      },
      badge: {
        type: 'number' as const,
        description: 'Badge count to display on app icon',
      },
    },
    required: ['title', 'body'] as string[],
  };

  private config: NotifyAppToolConfig;

  constructor(config: NotifyAppToolConfig) {
    this.config = config;
  }

  async execute(
    toolCallId: string,
    args: Record<string, unknown>,
    _signal: AbortSignal
  ): Promise<TronToolResult<NotifyAppResult>> {
    // Validate required parameters
    const title = args.title as string | undefined;
    const body = args.body as string | undefined;

    if (!title || typeof title !== 'string') {
      return {
        content: 'Error: title parameter is required and must be a string',
        isError: true,
      };
    }

    if (!body || typeof body !== 'string') {
      return {
        content: 'Error: body parameter is required and must be a string',
        isError: true,
      };
    }

    // Validate and truncate if needed
    const truncatedTitle = title.length > 50 ? title.substring(0, 47) + '...' : title;
    const truncatedBody = body.length > 200 ? body.substring(0, 197) + '...' : body;

    // Validate optional parameters
    const data = args.data as Record<string, string> | undefined;
    const priority = (args.priority as 'high' | 'normal') || 'normal';
    const sound = (args.sound as string) || 'default';
    const badge = args.badge as number | undefined;

    // Validate data object
    if (data !== undefined) {
      if (typeof data !== 'object' || data === null || Array.isArray(data)) {
        return {
          content: 'Error: data must be an object with string values',
          isError: true,
        };
      }

      for (const [key, value] of Object.entries(data)) {
        if (typeof value !== 'string') {
          return {
            content: `Error: data["${key}"] must be a string`,
            isError: true,
          };
        }
      }
    }

    // Validate priority
    if (priority && !['high', 'normal'].includes(priority)) {
      return {
        content: 'Error: priority must be "high" or "normal"',
        isError: true,
      };
    }

    // Validate badge
    if (badge !== undefined && (typeof badge !== 'number' || badge < 0)) {
      return {
        content: 'Error: badge must be a non-negative number',
        isError: true,
      };
    }

    logger.debug('NotifyApp tool called', {
      title: truncatedTitle,
      bodyLength: truncatedBody.length,
      priority,
      hasData: !!data,
    });

    try {
      const result = await this.config.onNotify(
        this.config.sessionId,
        {
          title: truncatedTitle,
          body: truncatedBody,
          data,
          priority,
          sound,
          badge,
        },
        toolCallId
      );

      // Build response message
      let message: string;
      if (result.successCount > 0 && result.failureCount === 0) {
        message = `Notification sent successfully to ${result.successCount} device${result.successCount > 1 ? 's' : ''}.`;
      } else if (result.successCount === 0 && result.failureCount === 0) {
        message = 'No devices registered to receive notifications.';
      } else if (result.successCount === 0) {
        message = `Failed to send notification to ${result.failureCount} device${result.failureCount > 1 ? 's' : ''}.`;
        if (result.errors && result.errors.length > 0) {
          message += ` Errors: ${result.errors.join(', ')}`;
        }
      } else {
        message = `Notification sent to ${result.successCount} device${result.successCount > 1 ? 's' : ''}, failed for ${result.failureCount}.`;
        if (result.errors && result.errors.length > 0) {
          message += ` Errors: ${result.errors.join(', ')}`;
        }
      }

      logger.info('NotifyApp tool completed', {
        successCount: result.successCount,
        failureCount: result.failureCount,
      });

      return {
        content: message,
        isError: result.successCount === 0 && result.failureCount > 0,
        details: result,
      };
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : String(error);
      logger.error('NotifyApp tool error', { error: errorMessage });

      return {
        content: `Failed to send notification: ${errorMessage}`,
        isError: true,
        details: {
          successCount: 0,
          failureCount: 0,
          errors: [errorMessage],
        },
      };
    }
  }
}
