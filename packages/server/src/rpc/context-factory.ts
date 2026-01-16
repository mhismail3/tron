/**
 * @fileoverview RPC Context Factory
 *
 * Composes all adapter modules into a complete RpcContext that can be
 * passed to RpcHandler. This factory is the single point of assembly
 * for all RPC adapters.
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
 */

import type { RpcContext } from '@tron/core';
import type { AdapterDependencies } from './types.js';

// Orchestrator-dependent adapters
import { createSessionAdapter } from './adapters/session.adapter.js';
import { createAgentAdapter } from './adapters/agent.adapter.js';
import { createEventStoreAdapter } from './adapters/event-store.adapter.js';
import { createWorktreeAdapter } from './adapters/worktree.adapter.js';
import { createContextAdapter } from './adapters/context.adapter.js';
import { createBrowserAdapter } from './adapters/browser.adapter.js';
import { createSkillAdapter } from './adapters/skill.adapter.js';

// Standalone adapters (no orchestrator dependency)
import { createMemoryAdapter } from './adapters/memory.adapter.js';
import { createTranscriptionAdapter } from './adapters/transcription.adapter.js';

// =============================================================================
// Context Factory
// =============================================================================

/**
 * Configuration options for creating RpcContext
 */
export interface RpcContextOptions {
  /**
   * Skip creating optional managers (for testing or minimal setups)
   */
  minimal?: boolean;

  /**
   * Skip transcription manager (e.g., when sidecar not available)
   */
  skipTranscription?: boolean;
}

/**
 * Creates a complete RpcContext by composing all adapter modules
 *
 * This is the main entry point for creating the RPC context that gets
 * passed to RpcHandler. It assembles all the individual adapters into
 * a cohesive context object.
 *
 * @param deps - Dependencies including the EventStoreOrchestrator
 * @param options - Optional configuration
 * @returns Complete RpcContext ready for RpcHandler
 *
 * @example
 * ```typescript
 * const orchestrator = new EventStoreOrchestrator(config);
 * const rpcContext = createRpcContext({ orchestrator });
 * const handler = new RpcHandler(rpcContext);
 * ```
 */
export function createRpcContext(
  deps: AdapterDependencies,
  options: RpcContextOptions = {},
): RpcContext {
  // Always create required managers
  const sessionManager = createSessionAdapter(deps);
  const agentManager = createAgentAdapter(deps);
  const memoryStore = createMemoryAdapter();

  // Build the base context with required managers
  const context: RpcContext = {
    sessionManager,
    agentManager,
    memoryStore,
  };

  // Add optional managers unless minimal mode requested
  if (!options.minimal) {
    // Transcription is standalone (no orchestrator needed)
    if (!options.skipTranscription) {
      context.transcriptionManager = createTranscriptionAdapter();
    }

    // All other optional managers depend on orchestrator
    context.eventStore = createEventStoreAdapter(deps);
    context.worktreeManager = createWorktreeAdapter(deps);
    context.contextManager = createContextAdapter(deps);
    context.browserManager = createBrowserAdapter(deps);
    context.skillManager = createSkillAdapter(deps);
  }

  return context;
}

/**
 * Creates a minimal RpcContext with only required managers
 *
 * Useful for testing or when you only need basic session/agent functionality.
 *
 * @param deps - Dependencies including the EventStoreOrchestrator
 * @returns Minimal RpcContext with only required managers
 */
export function createMinimalRpcContext(deps: AdapterDependencies): RpcContext {
  return createRpcContext(deps, { minimal: true });
}

/**
 * Type guard to check if context has all optional managers
 */
export function isFullRpcContext(
  context: RpcContext,
): context is Required<RpcContext> {
  return (
    context.eventStore !== undefined &&
    context.worktreeManager !== undefined &&
    context.transcriptionManager !== undefined &&
    context.contextManager !== undefined &&
    context.browserManager !== undefined &&
    context.skillManager !== undefined
  );
}
