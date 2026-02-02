/**
 * @fileoverview Base RPC Protocol Types
 *
 * Core request/response/error types for RPC communication.
 */

// =============================================================================
// Request/Response Pattern
// =============================================================================

/**
 * Base request structure - all requests have an id and method
 */
export interface RpcRequest<TMethod extends string = string, TParams = unknown> {
  /** Unique request identifier for correlation */
  id: string;
  /** The method being called */
  method: TMethod;
  /** Method parameters */
  params?: TParams;
  /** Optional idempotency key for request deduplication */
  idempotencyKey?: string;
}

/**
 * Base response structure
 */
export interface RpcResponse<TResult = unknown> {
  /** Request ID this response is for */
  id: string;
  /** Whether the request succeeded */
  success: boolean;
  /** Result data (if success) */
  result?: TResult;
  /** Error information (if !success) */
  error?: RpcError;
}

/**
 * Error structure for failed requests
 */
export interface RpcError {
  /** Error code */
  code: string;
  /** Human-readable message */
  message: string;
  /** Additional error details */
  details?: unknown;
}

// =============================================================================
// Event Types (Server → Client)
// =============================================================================

/**
 * Server-to-client events for real-time updates
 */
export interface RpcEvent<TType extends string = string, TData = unknown> {
  /** Event type identifier */
  type: TType;
  /** Session ID if applicable */
  sessionId?: string;
  /** Event timestamp */
  timestamp: string;
  /** Event-specific data */
  data: TData;
  /** Run ID for correlating events to agent runs */
  runId?: string;
}

// =============================================================================
// Method Definitions
// =============================================================================

/**
 * Available RPC methods
 */
export type RpcMethod =
  // Session management
  | 'session.create'
  | 'session.resume'
  | 'session.list'
  | 'session.delete'
  | 'session.fork'
  | 'session.getHead'
  | 'session.getState'
  // Worktree operations
  | 'worktree.getStatus'
  | 'worktree.commit'
  | 'worktree.merge'
  | 'worktree.list'
  // Event operations
  | 'events.getHistory'
  | 'events.getSince'
  | 'events.subscribe'
  | 'events.unsubscribe'
  | 'events.append'
  // Tree operations
  | 'tree.getVisualization'
  | 'tree.getBranches'
  | 'tree.getSubtree'
  | 'tree.getAncestors'
  | 'tree.compareBranches'
  // Agent interaction
  | 'agent.prompt'
  | 'agent.abort'
  | 'agent.getState'
  // Model management
  | 'model.switch'
  | 'model.list'
  // Memory operations
  | 'memory.search'
  | 'memory.addEntry'
  | 'memory.getHandoffs'
  // Skill operations
  | 'skill.list'
  | 'skill.get'
  | 'skill.refresh'
  | 'skill.remove'
  // Filesystem operations
  | 'filesystem.listDir'
  | 'filesystem.getHome'
  | 'filesystem.createDir'
  // Git operations
  | 'git.clone'
  // File operations
  | 'file.read'
  // Search
  | 'search.content'
  | 'search.events'
  // System
  | 'system.ping'
  | 'system.getInfo'
  | 'system.shutdown'
  // Transcription
  | 'transcribe.audio'
  | 'transcribe.listModels'
  // Context management
  | 'context.getSnapshot'
  | 'context.getDetailedSnapshot'
  | 'context.shouldCompact'
  | 'context.previewCompaction'
  | 'context.confirmCompaction'
  | 'context.canAcceptTurn'
  | 'context.clear'
  | 'context.compact'
  // Voice Notes
  | 'voiceNotes.save'
  | 'voiceNotes.list'
  | 'voiceNotes.delete'
  // Message operations
  | 'message.delete'
  // Browser automation
  | 'browser.startStream'
  | 'browser.stopStream'
  | 'browser.getStatus'
  // Tool operations
  | 'tool.result'
  // Canvas operations
  | 'canvas.get'
  // Plan mode operations
  | 'plan.enter'
  | 'plan.exit'
  | 'plan.getState'
  // Inter-agent communication
  | 'communication.send'
  | 'communication.receive'
  | 'communication.subscribe'
  | 'communication.unsubscribe'
  // Self-deployment operations
  | 'deployment.trigger'
  | 'deployment.status'
  | 'deployment.approve'
  | 'deployment.rollback'
  | 'deployment.healthCheck';
