/**
 * @fileoverview RPC domain handlers
 *
 * Handlers are organized by domain/namespace:
 *
 * Core:
 * - agent: Agent lifecycle and execution
 * - session: Session management
 * - system: System information and control
 *
 * Filesystem:
 * - filesystem: File operations (file, filesystem, git)
 *
 * Data:
 * - context: Context loading and management
 * - events: Event store operations
 * - model: Model selection and switching
 *
 * Features:
 * - browser: Browser automation
 * - skill: Skill loading and management
 * - search: Content and event search
 * - tree: Session tree visualization
 * - todo: Task management
 * - worktree: Git worktree operations
 * - message: Message operations
 * - transcribe: Audio transcription
 * - voice-notes: Voice note management
 * - canvas: UI canvas operations
 * - device: Device registration
 * - tool: Tool result handling
 *
 * New Capabilities:
 * - client: Client identification and capabilities
 * - communication: Inter-agent messaging
 */

// Core domains
export * from './agent/index.js';
export * from './session/index.js';
export * from './system/index.js';

// Filesystem domain
export * from './filesystem/index.js';

// Data domains
export * from './context/index.js';
export * from './events/index.js';
export * from './model/index.js';

// Feature domains
export * from './browser/index.js';
export * from './skill/index.js';
export * from './search/index.js';
export * from './tree/index.js';
export * from './todo/index.js';
export * from './worktree/index.js';
export * from './message/index.js';
export * from './transcribe/index.js';
export * from './voice-notes/index.js';
export * from './canvas/index.js';
export * from './device/index.js';
export * from './tool/index.js';

// New capability domains
export * from './client/index.js';
export * from './communication/index.js';

// Re-export base utilities for backward compatibility
export {
  extractParams,
  extractRequiredParams,
  requireManager,
  withErrorHandling,
  createHandler,
  notFoundError,
  type TypedHandler,
  type ParamsOf,
  type CreateHandlerOptions,
} from '@interface/rpc/handlers/base.js';
