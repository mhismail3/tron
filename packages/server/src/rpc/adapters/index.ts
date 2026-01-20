/**
 * @fileoverview RPC Adapter Exports
 *
 * Exports all adapter factory functions for creating RpcContext managers.
 */

// Simple adapters (no orchestrator dependency)
export { createTranscriptionAdapter } from './transcription.adapter.js';
export { createMemoryAdapter } from './memory.adapter.js';
export { createCanvasAdapter } from './canvas.adapter.js';

// Orchestrator-dependent adapters
export { createBrowserAdapter } from './browser.adapter.js';
export { createWorktreeAdapter } from './worktree.adapter.js';
export { createContextAdapter } from './context.adapter.js';
export { createEventStoreAdapter, getEventSummary, getEventDepth } from './event-store.adapter.js';

export { createSessionAdapter } from './session.adapter.js';
export { createSkillAdapter } from './skill.adapter.js';
export { createAgentAdapter } from './agent.adapter.js';
