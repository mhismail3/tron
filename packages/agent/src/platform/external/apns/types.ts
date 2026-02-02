/**
 * @fileoverview APNS Types
 *
 * Type definitions for Apple Push Notification Service integration.
 */

/**
 * APNS configuration loaded from ~/.tron/mods/apns/config.json
 */
export interface APNSConfig {
  /** Path to the p8 key file */
  keyPath: string;
  /** Key ID from Apple Developer portal */
  keyId: string;
  /** Team ID from Apple Developer portal */
  teamId: string;
  /** Bundle ID of the iOS app */
  bundleId: string;
  /** APNS environment: 'sandbox' for development, 'production' for release */
  environment: 'sandbox' | 'production';
}

/**
 * Notification payload to send via APNS
 */
export interface APNSNotification {
  /** Notification title (max 50 chars recommended) */
  title: string;
  /** Notification body (max 200 chars recommended) */
  body: string;
  /** Custom data payload */
  data?: Record<string, string>;
  /** Notification priority: 'high' (10) or 'normal' (5) */
  priority?: 'high' | 'normal';
  /** Sound name (default: 'default') */
  sound?: string;
  /** Badge count to show on app icon */
  badge?: number;
  /** Thread ID for notification grouping */
  threadId?: string;
}

/**
 * Result of sending a notification to a single device
 */
export interface APNSSendResult {
  /** Whether the send was successful */
  success: boolean;
  /** Device token that was sent to */
  deviceToken: string;
  /** APNS ID returned on success */
  apnsId?: string;
  /** Error message if failed */
  error?: string;
  /** HTTP status code from APNS */
  statusCode?: number;
  /** APNS error reason (e.g., 'BadDeviceToken', 'Unregistered') */
  reason?: string;
}

/**
 * APNS payload structure (internal)
 */
export interface APNSPayload {
  aps: {
    alert: {
      title: string;
      body: string;
    };
    sound?: string;
    badge?: number;
    'thread-id'?: string;
    'mutable-content'?: number;
  };
  [key: string]: unknown;
}

/**
 * Device token stored in database
 */
export interface DeviceToken {
  id: string;
  deviceToken: string;
  sessionId?: string;
  workspaceId?: string;
  platform: 'ios';
  environment: 'sandbox' | 'production';
  createdAt: string;
  lastUsedAt: string;
  isActive: boolean;
}

/**
 * Parameters for registering a device token
 */
export interface RegisterTokenParams {
  /** The APNS device token (64-char hex string) */
  deviceToken: string;
  /** Session ID to associate with */
  sessionId?: string;
  /** Workspace ID to associate with */
  workspaceId?: string;
  /** APNS environment */
  environment?: 'sandbox' | 'production';
}
