/**
 * @fileoverview Context domain - Context management
 *
 * Handles context snapshots, compaction, and capacity management.
 */

// Re-export handler factory
export { createContextHandlers } from '@interface/rpc/handlers/context.handler.js';

// Re-export types
export type {
  ContextGetSnapshotParams,
  ContextGetSnapshotResult,
  ContextGetDetailedSnapshotParams,
  ContextGetDetailedSnapshotResult,
  ContextShouldCompactParams,
  ContextShouldCompactResult,
  ContextPreviewCompactionParams,
  ContextPreviewCompactionResult,
  ContextConfirmCompactionParams,
  ContextConfirmCompactionResult,
  ContextCanAcceptTurnParams,
  ContextCanAcceptTurnResult,
  ContextClearParams,
  ContextClearResult,
} from '@interface/rpc/types/context.js';
