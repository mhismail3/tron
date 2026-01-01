/**
 * @fileoverview Session module exports
 */
export * from './types.js';
export { SessionManager, type SessionManagerConfig } from './manager.js';
export {
  WorktreeManager,
  createWorktreeManager,
  type WorktreeManagerConfig,
  type Worktree,
  type WorktreeStatus,
} from './worktree.js';
