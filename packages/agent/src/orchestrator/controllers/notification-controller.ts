/**
 * @fileoverview Notification Controller
 *
 * Extracted from EventStoreOrchestrator to handle push notification operations.
 * Manages APNS (Apple Push Notification Service) delivery to iOS devices.
 *
 * ## Responsibilities
 *
 * - Send push notifications via APNS
 * - Manage device token lifecycle (deactivate unregistered tokens)
 * - Handle notification delivery results
 */

import { createLogger } from '../../logging/logger.js';
import type { EventStore } from '../../events/event-store.js';
import type { APNSService, APNSNotification } from '../../external/apns/index.js';
import type { NotifyAppResult } from '../../tools/ui/notify-app.js';

const logger = createLogger('notification-controller');

// =============================================================================
// Types
// =============================================================================

export interface NotificationControllerConfig {
  /** APNS service for push notifications */
  apnsService: APNSService | null;
  /** Event store for database access */
  eventStore: EventStore;
}

export interface NotificationPayload {
  title: string;
  body: string;
  data?: Record<string, string>;
  priority?: 'high' | 'normal';
  sound?: string;
  badge?: number;
}

// =============================================================================
// NotificationController Class
// =============================================================================

/**
 * Handles push notification delivery to iOS devices via APNS.
 */
export class NotificationController {
  private config: NotificationControllerConfig;

  constructor(config: NotificationControllerConfig) {
    this.config = config;
  }

  /**
   * Send a push notification to all registered devices.
   * Any agent/session can trigger notifications globally.
   * Used by the NotifyApp tool.
   *
   * @param sessionId - Session ID (for deep linking and thread grouping)
   * @param notification - Notification payload
   * @param toolCallId - Tool call ID (for iOS to scroll to notification chip)
   */
  async sendNotification(
    sessionId: string,
    notification: NotificationPayload,
    toolCallId: string
  ): Promise<NotifyAppResult> {
    if (!this.config.apnsService) {
      return { successCount: 0, failureCount: 0, errors: ['APNS not configured'] };
    }

    // Get ALL active device tokens (global notification)
    const db = this.config.eventStore.getDatabase();
    if (!db) {
      return { successCount: 0, failureCount: 0, errors: ['Database not available'] };
    }

    const tokens = db
      .prepare(`
        SELECT device_token, environment
        FROM device_tokens
        WHERE is_active = 1
      `)
      .all() as Array<{ device_token: string; environment: string }>;

    if (tokens.length === 0) {
      logger.debug('No device tokens registered');
      return { successCount: 0, failureCount: 0 };
    }

    // Build APNS notification payload
    const apnsNotification: APNSNotification = {
      title: notification.title,
      body: notification.body,
      data: {
        ...notification.data,
        sessionId, // Include sessionId for deep linking to the sending session
        toolCallId, // Include toolCallId so iOS can scroll to the notification chip
      },
      priority: notification.priority,
      sound: notification.sound,
      badge: notification.badge,
      threadId: sessionId, // Group notifications by session
    };

    // Send to all registered devices
    const deviceTokens = tokens.map((t) => t.device_token);
    const results = await this.config.apnsService.sendToMany(deviceTokens, apnsNotification);

    // Handle invalid tokens (APNS 410 = unregistered)
    for (const result of results) {
      if (!result.success && result.reason === 'Unregistered') {
        // Mark token as invalid
        db.prepare('UPDATE device_tokens SET is_active = 0 WHERE device_token = ?')
          .run(result.deviceToken);
        logger.info('Marked unregistered device token as inactive', {
          deviceToken: result.deviceToken.substring(0, 8) + '...',
        });
      }
    }

    const successCount = results.filter((r) => r.success).length;
    const failureCount = results.filter((r) => !r.success).length;
    const errors = results
      .filter((r) => !r.success && r.error)
      .map((r) => r.error!);

    return { successCount, failureCount, errors: errors.length > 0 ? errors : undefined };
  }

  /**
   * Check if APNS is configured and available.
   */
  isAvailable(): boolean {
    return this.config.apnsService !== null;
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create a NotificationController instance.
 */
export function createNotificationController(
  config: NotificationControllerConfig
): NotificationController {
  return new NotificationController(config);
}
