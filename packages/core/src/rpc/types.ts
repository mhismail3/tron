/**
 * @fileoverview RPC Protocol Types
 *
 * Defines the message protocol for communication between
 * clients (TUI, Web) and the server.
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
  | 'session.rewind'
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
  // Skill execution
  | 'skill.execute'
  | 'skill.list'
  // System
  | 'system.ping'
  | 'system.getInfo'
  | 'system.shutdown';

// =============================================================================
// Session Methods
// =============================================================================

/** Create new session */
export interface SessionCreateParams {
  /** Working directory for the session */
  workingDirectory: string;
  /** Model to use (optional, defaults to config) */
  model?: string;
  /** Initial context files to load */
  contextFiles?: string[];
}

export interface SessionCreateResult {
  sessionId: string;
  model: string;
  createdAt: string;
}

/** Resume existing session */
export interface SessionResumeParams {
  /** Session ID to resume */
  sessionId: string;
}

export interface SessionResumeResult {
  sessionId: string;
  model: string;
  messageCount: number;
  lastActivity: string;
}

/** List sessions */
export interface SessionListParams {
  /** Filter by working directory */
  workingDirectory?: string;
  /** Max sessions to return */
  limit?: number;
  /** Include ended sessions */
  includeEnded?: boolean;
}

export interface SessionListResult {
  sessions: Array<{
    sessionId: string;
    workingDirectory: string;
    model: string;
    messageCount: number;
    createdAt: string;
    lastActivity: string;
    isActive: boolean;
  }>;
}

/** Delete session */
export interface SessionDeleteParams {
  sessionId: string;
}

export interface SessionDeleteResult {
  deleted: boolean;
}

/** Fork session */
export interface SessionForkParams {
  sessionId: string;
  /** Optional: fork from specific message index */
  fromMessageIndex?: number;
}

export interface SessionForkResult {
  newSessionId: string;
  forkedFrom: string;
  messageCount: number;
}

/** Rewind session */
export interface SessionRewindParams {
  sessionId: string;
  /** Rewind to this message index (0-based) */
  toMessageIndex: number;
}

export interface SessionRewindResult {
  sessionId: string;
  newMessageCount: number;
  removedCount: number;
}

// =============================================================================
// Agent Methods
// =============================================================================

/** Send prompt to agent */
export interface AgentPromptParams {
  /** Session to send to */
  sessionId: string;
  /** User message */
  prompt: string;
  /** Optional image attachments (base64) */
  images?: Array<{
    data: string;
    mimeType: string;
  }>;
}

export interface AgentPromptResult {
  /** Response will be streamed via events */
  acknowledged: boolean;
}

/** Abort current agent run */
export interface AgentAbortParams {
  sessionId: string;
}

export interface AgentAbortResult {
  aborted: boolean;
}

/** Get agent state */
export interface AgentGetStateParams {
  sessionId: string;
}

export interface AgentGetStateResult {
  isRunning: boolean;
  currentTurn: number;
  messageCount: number;
  tokenUsage: {
    input: number;
    output: number;
  };
  model: string;
  tools: string[];
}

// =============================================================================
// Model Methods
// =============================================================================

/** Switch model */
export interface ModelSwitchParams {
  sessionId: string;
  model: string;
}

export interface ModelSwitchResult {
  previousModel: string;
  newModel: string;
}

/** List available models */
export interface ModelListParams {}

export interface ModelListResult {
  models: Array<{
    id: string;
    name: string;
    provider: string;
    contextWindow: number;
    supportsThinking: boolean;
    supportsImages: boolean;
  }>;
}

// =============================================================================
// Memory Methods
// =============================================================================

/** Search memory */
export interface MemorySearchParams {
  searchText?: string;
  type?: 'pattern' | 'decision' | 'preference' | 'lesson' | 'error';
  source?: 'immediate' | 'session' | 'project' | 'global';
  limit?: number;
}

export interface RpcMemorySearchResult {
  entries: Array<{
    id: string;
    type: string;
    content: string;
    source: string;
    relevance: number;
    timestamp: string;
  }>;
  totalCount: number;
}

/** Alias for backward compatibility */
export type MemorySearchResultRpc = RpcMemorySearchResult;

/** Add memory entry */
export interface MemoryAddEntryParams {
  type: 'pattern' | 'decision' | 'preference' | 'lesson' | 'error';
  content: string;
  source?: 'project' | 'global';
  metadata?: Record<string, unknown>;
}

export interface MemoryAddEntryResult {
  id: string;
  created: boolean;
}

/** Get handoffs */
export interface MemoryGetHandoffsParams {
  workingDirectory?: string;
  limit?: number;
}

export interface MemoryGetHandoffsResult {
  handoffs: Array<{
    id: string;
    sessionId: string;
    summary: string;
    createdAt: string;
  }>;
}

// =============================================================================
// Skill Methods
// =============================================================================

/** Execute skill */
export interface SkillExecuteParams {
  sessionId: string;
  skillName: string;
  arguments?: Record<string, unknown>;
}

export interface SkillExecuteResult {
  success: boolean;
  output?: string;
  error?: string;
}

/** List available skills */
export interface SkillListParams {}

export interface SkillListResult {
  skills: Array<{
    name: string;
    description: string;
    arguments?: Array<{
      name: string;
      description: string;
      required: boolean;
    }>;
  }>;
}

// =============================================================================
// System Methods
// =============================================================================

/** Ping */
export interface SystemPingParams {}

export interface SystemPingResult {
  pong: true;
  timestamp: string;
}

/** Get system info */
export interface SystemGetInfoParams {}

export interface SystemGetInfoResult {
  version: string;
  uptime: number;
  activeSessions: number;
  memoryUsage: {
    heapUsed: number;
    heapTotal: number;
  };
}

/** Shutdown */
export interface SystemShutdownParams {
  /** Grace period in ms before force shutdown */
  gracePeriod?: number;
}

export interface SystemShutdownResult {
  acknowledged: boolean;
}

// =============================================================================
// Event Types
// =============================================================================

/**
 * All event types that can be sent from server to client
 */
export type RpcEventType =
  // Agent events
  | 'agent.turn_start'
  | 'agent.turn_end'
  | 'agent.text_delta'
  | 'agent.thinking_delta'
  | 'agent.tool_start'
  | 'agent.tool_end'
  | 'agent.error'
  | 'agent.complete'
  // Session events
  | 'session.created'
  | 'session.ended'
  | 'session.updated'
  // System events
  | 'system.connected'
  | 'system.disconnected'
  | 'system.error';

/**
 * Event data for agent text streaming
 */
export interface AgentTextDeltaEvent {
  delta: string;
  accumulated?: string;
}

/**
 * Event data for agent thinking streaming
 */
export interface AgentThinkingDeltaEvent {
  delta: string;
}

/**
 * Event data for tool start
 */
export interface AgentToolStartEvent {
  toolCallId: string;
  toolName: string;
  arguments: Record<string, unknown>;
}

/**
 * Event data for tool end
 */
export interface AgentToolEndEvent {
  toolCallId: string;
  toolName: string;
  duration: number;
  success: boolean;
  output?: string;
  error?: string;
}

/**
 * Event data for agent completion
 */
export interface AgentCompleteEvent {
  turns: number;
  tokenUsage: {
    input: number;
    output: number;
  };
  success: boolean;
  error?: string;
}

// =============================================================================
// Type Guards
// =============================================================================

export function isRpcRequest(msg: unknown): msg is RpcRequest {
  return (
    typeof msg === 'object' &&
    msg !== null &&
    'id' in msg &&
    'method' in msg &&
    typeof (msg as RpcRequest).id === 'string' &&
    typeof (msg as RpcRequest).method === 'string'
  );
}

export function isRpcResponse(msg: unknown): msg is RpcResponse {
  return (
    typeof msg === 'object' &&
    msg !== null &&
    'id' in msg &&
    'success' in msg &&
    typeof (msg as RpcResponse).id === 'string' &&
    typeof (msg as RpcResponse).success === 'boolean'
  );
}

export function isRpcEvent(msg: unknown): msg is RpcEvent {
  return (
    typeof msg === 'object' &&
    msg !== null &&
    'type' in msg &&
    'timestamp' in msg &&
    'data' in msg &&
    typeof (msg as RpcEvent).type === 'string'
  );
}
