/**
 * @fileoverview RPC Adapter Types
 *
 * Type definitions for RPC adapter modules that bridge the
 * EventStoreOrchestrator to the RpcContext interface expected by @tron/core.
 *
 * Each adapter is responsible for translating between:
 * - Orchestrator methods (implementation details)
 * - RpcContext interface (public contract)
 */

import type { EventStoreOrchestrator } from '../event-store-orchestrator.js';
import type {
  RpcContext,
  EventStoreManager,
  WorktreeRpcManager,
  ContextRpcManager,
  BrowserRpcManager,
  SkillRpcManager,
} from '@tron/core';

// =============================================================================
// Adapter Factory Types
// =============================================================================

/**
 * Dependencies injected into adapter factories
 */
export interface AdapterDependencies {
  orchestrator: EventStoreOrchestrator;
}

/**
 * Factory function signature for creating an adapter
 */
export type AdapterFactory<T> = (deps: AdapterDependencies) => T;

// =============================================================================
// Manager Types (extracted from RpcContext)
// =============================================================================

/**
 * Session manager interface - handles session lifecycle
 */
export type SessionManagerAdapter = RpcContext['sessionManager'];

/**
 * Agent manager interface - handles agent prompts and state
 */
export type AgentManagerAdapter = RpcContext['agentManager'];

/**
 * Memory store interface - deprecated, returns empty results
 */
export type MemoryStoreAdapter = RpcContext['memoryStore'];

/**
 * Transcription manager interface - audio transcription
 */
export type TranscriptionManagerAdapter = NonNullable<RpcContext['transcriptionManager']>;

/**
 * Event store manager interface - event operations
 */
export type EventStoreManagerAdapter = EventStoreManager;

/**
 * Worktree manager interface - git worktree operations
 */
export type WorktreeManagerAdapter = WorktreeRpcManager;

/**
 * Context manager interface - context compaction operations
 */
export type ContextManagerAdapter = ContextRpcManager;

/**
 * Browser manager interface - browser automation
 */
export type BrowserManagerAdapter = BrowserRpcManager;

/**
 * Skill manager interface - skill loading and management
 */
export type SkillManagerAdapter = SkillRpcManager;

// =============================================================================
// Helper Types
// =============================================================================

/**
 * Session info returned from orchestrator (subset we care about)
 */
export interface OrchestratorSessionInfo {
  sessionId: string;
  workingDirectory: string;
  model: string;
  messageCount: number;
  inputTokens: number;
  outputTokens: number;
  lastTurnInputTokens: number;
  cacheReadTokens: number;
  cacheCreationTokens: number;
  cost: number;
  createdAt: string;
  lastActivity: string;
  isActive: boolean;
  lastUserPrompt?: string;
  lastAssistantResponse?: string;
}

/**
 * Message format from orchestrator
 */
export interface OrchestratorMessage {
  role: 'user' | 'assistant';
  content: unknown;
}

/**
 * Event summary helper result
 */
export interface EventSummary {
  type: string;
  summary: string;
}

/**
 * Tree node for visualization
 */
export interface TreeNode {
  id: string;
  parentId: string | null;
  type: string;
  timestamp: string;
  summary: string;
  hasChildren: boolean;
  childCount: number;
  depth: number;
  isBranchPoint: boolean;
  isHead: boolean;
}
