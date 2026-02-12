/**
 * @fileoverview Areas Migration
 *
 * Adds the areas table for PARA-model support (Areas = ongoing responsibilities).
 * Also adds area_id foreign key to projects and tasks tables,
 * and creates FTS index on areas for full-text search.
 */

import type { Migration } from '../types.js';

export const migration: Migration = {
  version: 8,
  description: 'Add areas table and area_id to projects/tasks for PARA model support',
  up: (db) => {
    db.exec(`
      -- =======================================================================
      -- Areas (ongoing responsibilities)
      -- =======================================================================
      CREATE TABLE IF NOT EXISTS areas (
        id            TEXT PRIMARY KEY,
        workspace_id  TEXT NOT NULL DEFAULT 'default',
        title         TEXT NOT NULL,
        description   TEXT,
        status        TEXT NOT NULL DEFAULT 'active',
        tags          TEXT DEFAULT '[]',
        sort_order    REAL NOT NULL DEFAULT 0,
        created_at    TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at    TEXT NOT NULL DEFAULT (datetime('now')),
        metadata      TEXT DEFAULT '{}'
      );

      CREATE INDEX IF NOT EXISTS idx_areas_workspace ON areas(workspace_id);
      CREATE INDEX IF NOT EXISTS idx_areas_status ON areas(status);

      -- =======================================================================
      -- Add area_id to projects and tasks
      -- =======================================================================
      ALTER TABLE projects ADD COLUMN area_id TEXT REFERENCES areas(id) ON DELETE SET NULL;
      CREATE INDEX IF NOT EXISTS idx_projects_area ON projects(area_id);

      ALTER TABLE tasks ADD COLUMN area_id TEXT REFERENCES areas(id) ON DELETE SET NULL;
      CREATE INDEX IF NOT EXISTS idx_tasks_area ON tasks(area_id);

      -- =======================================================================
      -- Full-Text Search on Areas
      -- =======================================================================
      CREATE VIRTUAL TABLE IF NOT EXISTS areas_fts USING fts5(
        area_id UNINDEXED, title, description, tags,
        tokenize='porter unicode61'
      );

      -- FTS sync triggers
      CREATE TRIGGER IF NOT EXISTS areas_fts_insert
      AFTER INSERT ON areas
      BEGIN
        INSERT INTO areas_fts (area_id, title, description, tags)
        VALUES (NEW.id, NEW.title, COALESCE(NEW.description, ''), COALESCE(NEW.tags, '[]'));
      END;

      CREATE TRIGGER IF NOT EXISTS areas_fts_update
      AFTER UPDATE ON areas
      BEGIN
        DELETE FROM areas_fts WHERE area_id = OLD.id;
        INSERT INTO areas_fts (area_id, title, description, tags)
        VALUES (NEW.id, NEW.title, COALESCE(NEW.description, ''), COALESCE(NEW.tags, '[]'));
      END;

      CREATE TRIGGER IF NOT EXISTS areas_fts_delete
      AFTER DELETE ON areas
      BEGIN
        DELETE FROM areas_fts WHERE area_id = OLD.id;
      END;
    `);
  },
};
