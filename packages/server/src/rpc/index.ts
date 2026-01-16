/**
 * @fileoverview RPC Module Exports
 *
 * This module provides the context factory and adapter factories for creating
 * RpcContext from EventStoreOrchestrator. The adapters translate between
 * orchestrator methods and the RpcContext interface expected by @tron/core's
 * RpcHandler.
 *
 * ## Architecture
 *
 * ```
 * EventStoreOrchestrator
 *         │
 *         ▼
 * ┌───────────────────────────────────────┐
 * │       createRpcContext(deps)          │
 * ├───────────────────────────────────────┤
 * │  ┌─────────────────────────────────┐  │
 * │  │  Orchestrator-dependent adapters │  │
 * │  ├─────────────────────────────────┤  │
 * │  │ sessionManager    ◄── session   │  │
 * │  │ agentManager      ◄── agent     │  │
 * │  │ eventStore        ◄── event-store│  │
 * │  │ worktreeManager   ◄── worktree  │  │
 * │  │ contextManager    ◄── context   │  │
 * │  │ browserManager    ◄── browser   │  │
 * │  │ skillManager      ◄── skill     │  │
 * │  └─────────────────────────────────┘  │
 * │  ┌─────────────────────────────────┐  │
 * │  │  Standalone adapters            │  │
 * │  ├─────────────────────────────────┤  │
 * │  │ memoryStore       ◄── memory    │  │
 * │  │ transcription...  ◄── transcr.  │  │
 * │  └─────────────────────────────────┘  │
 * └───────────────────────────────────────┘
 *         │
 *         ▼
 *    RpcContext (passed to RpcHandler)
 * ```
 *
 * ## Migration Status
 *
 * Phase 0: Foundation
 * - [x] Directory structure created
 * - [x] Types defined
 *
 * Phase 1: Extract adapters
 * - [x] transcription.adapter.ts
 * - [x] memory.adapter.ts
 * - [x] browser.adapter.ts
 * - [x] worktree.adapter.ts
 * - [x] context.adapter.ts
 * - [x] event-store.adapter.ts
 * - [x] session.adapter.ts
 * - [x] skill.adapter.ts
 * - [x] agent.adapter.ts
 *
 * Phase 2: Context factory (CURRENT)
 * - [x] context-factory.ts created
 * - [ ] Integrate into server
 *
 * Phase 3: Cleanup
 * - [ ] Remove legacy code from server/index.ts
 */

// =============================================================================
// Context Factory (main entry point)
// =============================================================================

export {
  createRpcContext,
  createMinimalRpcContext,
  isFullRpcContext,
  type RpcContextOptions,
} from './context-factory.js';

// =============================================================================
// Types
// =============================================================================

export type {
  AdapterDependencies,
  AdapterFactory,
  SessionManagerAdapter,
  AgentManagerAdapter,
  MemoryStoreAdapter,
  TranscriptionManagerAdapter,
  EventStoreManagerAdapter,
  WorktreeManagerAdapter,
  ContextManagerAdapter,
  BrowserManagerAdapter,
  SkillManagerAdapter,
  OrchestratorSessionInfo,
  OrchestratorMessage,
  EventSummary,
  TreeNode,
} from './types.js';

// =============================================================================
// Individual Adapter Factories (for advanced use cases)
// =============================================================================

// Orchestrator-dependent adapters
export { createSessionAdapter } from './adapters/session.adapter.js';
export { createAgentAdapter } from './adapters/agent.adapter.js';
export { createEventStoreAdapter, getEventSummary, getEventDepth } from './adapters/event-store.adapter.js';
export { createWorktreeAdapter } from './adapters/worktree.adapter.js';
export { createContextAdapter } from './adapters/context.adapter.js';
export { createBrowserAdapter } from './adapters/browser.adapter.js';
export { createSkillAdapter } from './adapters/skill.adapter.js';

// Standalone adapters (no orchestrator dependency)
export { createMemoryAdapter } from './adapters/memory.adapter.js';
export { createTranscriptionAdapter } from './adapters/transcription.adapter.js';
