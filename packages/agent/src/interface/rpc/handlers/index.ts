/**
 * @fileoverview RPC Handlers Module
 *
 * Exports handler utilities and handler factory functions.
 * Each handler module provides a factory that returns MethodRegistration[].
 */

// Base utilities
export {
  extractParams,
  extractRequiredParams,
  requireManager,
  withErrorHandling,
  createHandler,
  ErrorCodes,
  notFoundError,
  type TypedHandler,
  type ParamsOf,
  type CreateHandlerOptions,
} from './base.js';

// Handler factory functions
export { createSystemHandlers } from './system.handler.js';
export { createFilesystemHandlers } from './filesystem.handler.js';
export { createModelHandlers } from './model.handler.js';
export { createMemoryHandlers } from './memory.handler.js';
export { createTranscribeHandlers } from './transcribe.handler.js';
export { createSessionHandlers } from './session.handler.js';
export { createAgentHandlers } from './agent.handler.js';
export { createEventsHandlers } from './events.handler.js';
export { createTreeHandlers } from './tree.handler.js';
export { createSearchHandlers } from './search.handler.js';
export { createWorktreeHandlers } from './worktree.handler.js';
export { createContextHandlers } from './context.handler.js';
export { createMessageHandlers } from './message.handler.js';
export { createBrowserHandlers } from './browser.handler.js';
export { createSkillHandlers } from './skill.handler.js';
export { createFileHandlers } from './file.handler.js';
export { createToolHandlers } from './tool.handler.js';
export { createGitHandlers } from './git.handler.js';
export { createVoiceNotesHandlers } from './voiceNotes.handler.js';
export { createCanvasHandlers } from './canvas.handler.js';
export { createTodoHandlers } from './todo.handler.js';
export { getDeviceHandlers } from './device.handler.js';
