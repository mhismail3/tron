/**
 * @fileoverview RPC Module Exports
 *
 * This module provides adapter factories for creating RpcContext from
 * EventStoreOrchestrator. The adapters translate between orchestrator
 * methods and the RpcContext interface expected by @tron/core's RpcHandler.
 *
 * ## Architecture
 *
 * ```
 * EventStoreOrchestrator
 *         │
 *         ▼
 * ┌───────────────────┐
 * │  Adapter Factory  │  (createRpcContext)
 * └───────────────────┘
 *         │
 *         ▼
 * ┌───────────────────┐
 * │    RpcContext     │  (passed to RpcHandler)
 * ├───────────────────┤
 * │ sessionManager    │ ◄── session.adapter.ts
 * │ agentManager      │ ◄── agent.adapter.ts
 * │ memoryStore       │ ◄── memory.adapter.ts
 * │ eventStore        │ ◄── event-store.adapter.ts
 * │ worktreeManager   │ ◄── worktree.adapter.ts
 * │ transcription...  │ ◄── transcription.adapter.ts
 * │ contextManager    │ ◄── context.adapter.ts
 * │ browserManager    │ ◄── browser.adapter.ts
 * │ skillManager      │ ◄── skill.adapter.ts
 * └───────────────────┘
 * ```
 *
 * ## Migration Status
 *
 * Phase 0: Foundation (CURRENT)
 * - [x] Directory structure created
 * - [x] Types defined
 * - [ ] Tests for adapter contracts
 *
 * Phase 1: Extract adapters incrementally
 * - [ ] transcription.adapter.ts
 * - [ ] memory.adapter.ts
 * - [ ] browser.adapter.ts
 * - [ ] worktree.adapter.ts
 * - [ ] context.adapter.ts
 * - [ ] event-store.adapter.ts
 * - [ ] session.adapter.ts
 * - [ ] skill.adapter.ts
 * - [ ] agent.adapter.ts
 *
 * Phase 2: Context factory
 * - [ ] Move assembly to context-factory.ts
 *
 * Phase 3: Cleanup
 * - [ ] Remove legacy code from index.ts
 */

// Types
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

// Adapters will be exported here as they are created
// export { createSessionAdapter } from './adapters/session.adapter.js';
// export { createAgentAdapter } from './adapters/agent.adapter.js';
// ... etc
