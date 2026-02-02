/**
 * @fileoverview Context domain - Context management
 *
 * Handles context snapshots, compaction, and capacity management.
 *
 * @migration Re-exports from rpc/handlers during transition
 */

// Re-export handlers
export {
  handleContextGetSnapshot,
  handleContextGetDetailedSnapshot,
  handleContextShouldCompact,
  handleContextPreviewCompaction,
  handleContextConfirmCompaction,
  handleContextCanAcceptTurn,
  handleContextClear,
  createContextHandlers,
} from '../../../../rpc/handlers/context.handler.js';

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
} from '../../../../rpc/types/context.js';
