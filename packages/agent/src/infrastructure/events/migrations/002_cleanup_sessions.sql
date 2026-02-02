-- Migration 002: Cleanup sessions table
-- Removes: provider, status columns
-- Renames: model -> latest_model
-- Note: status can be derived from ended_at IS NOT NULL
-- Note: provider can be derived from model name

-- This migration uses table rebuild approach because SQLite has limited ALTER TABLE support.
-- The actual migration is handled in runIncrementalMigrations() in sqlite-backend.ts
-- because SQLite migrations need to be done programmatically (checking column existence, etc.)

-- Schema version update will be inserted after successful migration
