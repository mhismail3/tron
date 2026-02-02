/**
 * @fileoverview Device Tokens Migration
 *
 * Creates the device_tokens table for storing APNS push notification
 * device tokens. These tokens are used by the NotifyApp tool to send
 * push notifications to iOS devices.
 */

import type { Migration } from '../types.js';

export const migration: Migration = {
  version: 3,
  description: 'Add device_tokens table for push notifications',
  up: (db) => {
    db.exec(`
      -- Device tokens for push notifications
      CREATE TABLE IF NOT EXISTS device_tokens (
        id TEXT PRIMARY KEY,
        device_token TEXT NOT NULL,
        session_id TEXT REFERENCES sessions(id),
        workspace_id TEXT REFERENCES workspaces(id),
        platform TEXT NOT NULL DEFAULT 'ios',
        environment TEXT NOT NULL DEFAULT 'production',
        created_at TEXT NOT NULL,
        last_used_at TEXT NOT NULL,
        is_active INTEGER DEFAULT 1,
        UNIQUE(device_token, platform)
      );

      -- Index for finding active tokens by session
      CREATE INDEX IF NOT EXISTS idx_device_tokens_session
        ON device_tokens(session_id) WHERE is_active = 1;

      -- Index for finding active tokens by workspace
      CREATE INDEX IF NOT EXISTS idx_device_tokens_workspace
        ON device_tokens(workspace_id) WHERE is_active = 1;

      -- Index for finding tokens by device_token (for deactivation on APNS 410)
      CREATE INDEX IF NOT EXISTS idx_device_tokens_token
        ON device_tokens(device_token);
    `);
  },
};
