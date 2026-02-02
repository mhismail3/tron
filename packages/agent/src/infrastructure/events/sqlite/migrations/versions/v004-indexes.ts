/**
 * @fileoverview Database Optimization Migration
 *
 * Adds performance indexes and FTS sync triggers:
 * - idx_events_tool_call_id: Tool result matching during message reconstruction
 * - idx_blobs_ref_count: Efficient blob cleanup queries
 * - idx_sessions_created: Session ordering by creation time
 * - idx_events_message_preview: Message preview optimization
 * - idx_events_session_covering: Covering index for common event queries
 * - FTS triggers for automatic events_fts and logs_fts synchronization
 */

import type { Migration } from '../types.js';

export const migration: Migration = {
  version: 4,
  description: 'Add performance indexes and FTS sync triggers',
  up: (db) => {
    db.exec(`
      -- Tool result matching (used in message reconstruction)
      -- Partial index: only index rows where tool_call_id is not null
      CREATE INDEX IF NOT EXISTS idx_events_tool_call_id
        ON events(tool_call_id) WHERE tool_call_id IS NOT NULL;

      -- Blob cleanup (DELETE WHERE ref_count <= 0)
      -- Partial index: only index blobs ready for cleanup
      CREATE INDEX IF NOT EXISTS idx_blobs_ref_count
        ON blobs(ref_count) WHERE ref_count <= 0;

      -- Sessions by created_at (used in ORDER BY queries)
      CREATE INDEX IF NOT EXISTS idx_sessions_created
        ON sessions(created_at DESC);

      -- Message preview optimization
      -- Partial index for fetching recent user/assistant messages
      CREATE INDEX IF NOT EXISTS idx_events_message_preview
        ON events(session_id, type, sequence DESC)
        WHERE type IN ('message.user', 'message.assistant');

      -- Covering index for common getBySession queries
      -- Avoids table lookup for frequently accessed columns
      CREATE INDEX IF NOT EXISTS idx_events_session_covering
        ON events(session_id, sequence, type, timestamp, parent_id);

      -- =========================================================
      -- FTS Sync Triggers
      -- Automatically keep FTS tables in sync with main tables
      -- =========================================================

      -- Auto-sync events to FTS on insert
      CREATE TRIGGER IF NOT EXISTS events_fts_insert
      AFTER INSERT ON events
      BEGIN
        INSERT INTO events_fts (id, session_id, type, content, tool_name)
        VALUES (
          NEW.id,
          NEW.session_id,
          NEW.type,
          CASE WHEN json_valid(NEW.payload)
            THEN COALESCE(json_extract(NEW.payload, '$.content'), '')
            ELSE ''
          END,
          COALESCE(
            NEW.tool_name,
            CASE WHEN json_valid(NEW.payload)
              THEN COALESCE(
                json_extract(NEW.payload, '$.toolName'),
                json_extract(NEW.payload, '$.name')
              )
              ELSE NULL
            END,
            ''
          )
        );
      END;

      -- Auto-sync events FTS on delete
      CREATE TRIGGER IF NOT EXISTS events_fts_delete
      AFTER DELETE ON events
      BEGIN
        DELETE FROM events_fts WHERE id = OLD.id;
      END;

      -- Auto-sync logs to FTS on insert
      CREATE TRIGGER IF NOT EXISTS logs_fts_insert
      AFTER INSERT ON logs
      BEGIN
        INSERT INTO logs_fts (log_id, session_id, component, message, error_message)
        VALUES (
          NEW.id,
          NEW.session_id,
          NEW.component,
          NEW.message,
          COALESCE(NEW.error_message, '')
        );
      END;

      -- Auto-sync logs FTS on delete
      CREATE TRIGGER IF NOT EXISTS logs_fts_delete
      AFTER DELETE ON logs
      BEGIN
        DELETE FROM logs_fts WHERE log_id = OLD.id;
      END;
    `);
  },
};
