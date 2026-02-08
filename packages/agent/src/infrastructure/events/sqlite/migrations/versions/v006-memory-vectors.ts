/**
 * @fileoverview Memory Vectors Migration
 *
 * Creates the memory_vectors virtual table for semantic search via sqlite-vec.
 *
 * NOTE: This migration is a no-op — the virtual table requires the sqlite-vec
 * extension to be loaded, which happens at runtime after migrations run.
 * The actual table creation is done by VectorRepository.ensureTable() after
 * sqlite-vec is loaded. This migration entry exists to track the schema version.
 */

import type { Migration } from '../types.js';

export const migration: Migration = {
  version: 6,
  description: 'Register memory_vectors schema version (table created at runtime after sqlite-vec load)',
  up: () => {
    // No-op: sqlite-vec virtual table is created by VectorRepository.ensureTable()
    // after the extension is loaded at runtime. We can't create it here because
    // the migration runner doesn't load extensions.
  },
};
