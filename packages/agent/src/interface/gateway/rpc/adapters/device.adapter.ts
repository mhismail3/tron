/**
 * @fileoverview Device Token Adapter
 *
 * Adapts device token operations for the DeviceTokenRpcManager interface.
 * Handles APNS device token registration, lookup, and lifecycle management.
 */

import { createLogger } from '@infrastructure/logging/index.js';
import type { DeviceTokenRpcManager, RpcDeviceToken } from '../../../rpc/index.js';
import type { AdapterDependencies } from '../types.js';
import { randomUUID } from 'crypto';

const logger = createLogger('device-adapter');

// =============================================================================
// Device Token Adapter Factory
// =============================================================================

/**
 * Creates a device token manager adapter for RPC operations
 *
 * @param deps - Adapter dependencies including the orchestrator
 * @returns DeviceTokenRpcManager implementation
 */
export function createDeviceAdapter(deps: AdapterDependencies): DeviceTokenRpcManager {
  const { orchestrator } = deps;

  // Get database from orchestrator's event store
  const getDb = () => {
    const db = orchestrator.getEventStore().getDatabase();
    if (!db) {
      throw new Error('Database not available');
    }
    return db;
  };

  return {
    /**
     * Register or update a device token
     */
    async registerToken(params: {
      deviceToken: string;
      sessionId?: string;
      workspaceId?: string;
      environment?: 'sandbox' | 'production';
    }): Promise<{ id: string; created: boolean }> {
      const db = getDb();
      const now = new Date().toISOString();

      // Validate device token format (64-char hex for iOS)
      if (!/^[a-fA-F0-9]{64}$/.test(params.deviceToken)) {
        throw new Error('Invalid device token format: must be 64 hex characters');
      }

      // Check if token already exists
      const existing = db
        .prepare('SELECT id FROM device_tokens WHERE device_token = ? AND platform = ?')
        .get(params.deviceToken, 'ios') as { id: string } | undefined;

      if (existing) {
        // Update existing token
        db.prepare(`
          UPDATE device_tokens
          SET session_id = ?,
              workspace_id = ?,
              environment = ?,
              last_used_at = ?,
              is_active = 1
          WHERE id = ?
        `).run(
          params.sessionId || null,
          params.workspaceId || null,
          params.environment || 'production',
          now,
          existing.id
        );

        logger.debug('Updated device token registration', {
          id: existing.id,
          sessionId: params.sessionId,
        });

        return { id: existing.id, created: false };
      }

      // Insert new token
      const id = randomUUID();
      db.prepare(`
        INSERT INTO device_tokens (
          id, device_token, session_id, workspace_id, platform, environment,
          created_at, last_used_at, is_active
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)
      `).run(
        id,
        params.deviceToken,
        params.sessionId || null,
        params.workspaceId || null,
        'ios',
        params.environment || 'production',
        now,
        now
      );

      logger.info('Registered new device token', {
        id,
        sessionId: params.sessionId,
        environment: params.environment || 'production',
      });

      return { id, created: true };
    },

    /**
     * Unregister (deactivate) a device token
     */
    async unregisterToken(deviceToken: string): Promise<{ success: boolean }> {
      const db = getDb();

      const result = db
        .prepare('UPDATE device_tokens SET is_active = 0 WHERE device_token = ?')
        .run(deviceToken);

      if (result.changes > 0) {
        logger.info('Unregistered device token', {
          deviceToken: deviceToken.substring(0, 8) + '...',
        });
        return { success: true };
      }

      return { success: false };
    },

    /**
     * Get active tokens for a session
     */
    async getTokensForSession(sessionId: string): Promise<RpcDeviceToken[]> {
      const db = getDb();

      const rows = db
        .prepare(`
          SELECT id, device_token, session_id, workspace_id, platform,
                 environment, created_at, last_used_at, is_active
          FROM device_tokens
          WHERE session_id = ? AND is_active = 1
        `)
        .all(sessionId) as Array<{
          id: string;
          device_token: string;
          session_id: string | null;
          workspace_id: string | null;
          platform: string;
          environment: string;
          created_at: string;
          last_used_at: string;
          is_active: number;
        }>;

      return rows.map(mapRowToToken);
    },

    /**
     * Get active tokens for a workspace
     */
    async getTokensForWorkspace(workspaceId: string): Promise<RpcDeviceToken[]> {
      const db = getDb();

      const rows = db
        .prepare(`
          SELECT id, device_token, session_id, workspace_id, platform,
                 environment, created_at, last_used_at, is_active
          FROM device_tokens
          WHERE workspace_id = ? AND is_active = 1
        `)
        .all(workspaceId) as Array<{
          id: string;
          device_token: string;
          session_id: string | null;
          workspace_id: string | null;
          platform: string;
          environment: string;
          created_at: string;
          last_used_at: string;
          is_active: number;
        }>;

      return rows.map(mapRowToToken);
    },

    /**
     * Mark a token as invalid (e.g., after APNS 410 response)
     */
    async markTokenInvalid(deviceToken: string): Promise<void> {
      const db = getDb();

      db.prepare('UPDATE device_tokens SET is_active = 0 WHERE device_token = ?')
        .run(deviceToken);

      logger.info('Marked device token as invalid', {
        deviceToken: deviceToken.substring(0, 8) + '...',
      });
    },

    /**
     * Get all active device tokens (for global notifications)
     * Any agent/session can send notifications to all registered devices
     */
    async getAllActiveTokens(): Promise<RpcDeviceToken[]> {
      const db = getDb();

      const rows = db
        .prepare(`
          SELECT id, device_token, session_id, workspace_id, platform,
                 environment, created_at, last_used_at, is_active
          FROM device_tokens
          WHERE is_active = 1
        `)
        .all() as Array<{
          id: string;
          device_token: string;
          session_id: string | null;
          workspace_id: string | null;
          platform: string;
          environment: string;
          created_at: string;
          last_used_at: string;
          is_active: number;
        }>;

      return rows.map(mapRowToToken);
    },
  };
}

/**
 * Map database row to RpcDeviceToken
 */
function mapRowToToken(row: {
  id: string;
  device_token: string;
  session_id: string | null;
  workspace_id: string | null;
  platform: string;
  environment: string;
  created_at: string;
  last_used_at: string;
  is_active: number;
}): RpcDeviceToken {
  return {
    id: row.id,
    deviceToken: row.device_token,
    sessionId: row.session_id || undefined,
    workspaceId: row.workspace_id || undefined,
    platform: row.platform as 'ios',
    environment: row.environment as 'sandbox' | 'production',
    createdAt: row.created_at,
    lastUsedAt: row.last_used_at,
    isActive: row.is_active === 1,
  };
}
