/**
 * @fileoverview Core type definitions
 *
 * This module exports all core types used across the Tron agent system.
 * Types are organized by concern:
 * - events.ts: Event sourcing types
 * - messages.ts: Message types
 * - tools.ts: Tool-related types
 *
 * @migration This module consolidates types previously in types/ folder.
 * Old imports should be updated to use this module.
 */

// Re-export from legacy location during migration
// These will be moved here incrementally
export * from '../../types/index.js';
