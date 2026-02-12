/**
 * @fileoverview Context RPC Types
 *
 * Types for context management methods.
 */

// =============================================================================
// Context Methods
// =============================================================================

/** Get context snapshot for a session */
export interface ContextGetSnapshotParams {
  sessionId: string;
}

export interface ContextGetSnapshotResult {
  currentTokens: number;
  contextLimit: number;
  usagePercent: number;
  thresholdLevel: 'normal' | 'warning' | 'alert' | 'critical' | 'exceeded';
  breakdown: {
    systemPrompt: number;
    tools: number;
    rules: number;
    messages: number;
  };
}

/** Get detailed context snapshot with per-message token breakdown */
export interface ContextGetDetailedSnapshotParams {
  sessionId: string;
}

export interface ContextDetailedMessageInfo {
  index: number;
  role: 'user' | 'assistant' | 'toolResult';
  tokens: number;
  summary: string;
  content: string;
  toolCalls?: Array<{
    id: string;
    name: string;
    tokens: number;
    arguments: string;
  }>;
  toolCallId?: string;
  isError?: boolean;
}

/** Info about a skill explicitly added to session context */
export interface RpcAddedSkillInfo {
  /** Skill name */
  name: string;
  /** Where the skill was loaded from */
  source: 'global' | 'project';
  /** How the skill was added (via @mention or explicit selection) */
  addedVia: 'mention' | 'explicit';
  /** Event ID for removal tracking */
  eventId: string;
  /** Actual token count (calculated from content length) */
  tokens: number;
}

/** Info about a loaded rules file */
export interface RpcRulesFileInfo {
  /** Absolute path to the file */
  path: string;
  /** Path relative to working directory */
  relativePath: string;
  /** Level in hierarchy: global, project, or directory */
  level: 'global' | 'project' | 'directory';
  /** Depth from project root (-1 for global) */
  depth: number;
  /** File size in bytes (optional) */
  sizeBytes?: number;
}

/** Rules loaded for the session */
export interface RpcRulesInfo {
  /** List of loaded rules files */
  files: RpcRulesFileInfo[];
  /** Total number of rules files */
  totalFiles: number;
  /** Estimated token count for merged rules content */
  tokens: number;
}

/** A single auto-injected memory entry */
export interface RpcMemoryEntry {
  title: string;
  content: string;
}

/** Memory loaded for the session (if auto-inject enabled) */
export interface RpcMemoryInfo {
  /** Number of ledger entries loaded */
  count: number;
  /** Estimated token count */
  tokens: number;
  /** Individual memory entries with title and content */
  entries: RpcMemoryEntry[];
}

/** Task context summary auto-injected into LLM context */
export interface RpcTaskContextInfo {
  summary: string;
  tokens: number;
}

export interface ContextGetDetailedSnapshotResult extends ContextGetSnapshotResult {
  messages: ContextDetailedMessageInfo[];
  systemPromptContent: string;
  toolsContent: string[];
  /** Skills explicitly added to this session's context */
  addedSkills: RpcAddedSkillInfo[];
  /** Rules files loaded for this session (if any) */
  rules?: RpcRulesInfo;
  /** Memory loaded for this session (if auto-inject enabled) */
  memory?: RpcMemoryInfo;
  /** Task context summary (if tasks exist) */
  taskContext?: RpcTaskContextInfo;
}

/** Check if compaction is needed */
export interface ContextShouldCompactParams {
  sessionId: string;
}

export interface ContextShouldCompactResult {
  shouldCompact: boolean;
}

/** Preview compaction without executing */
export interface ContextPreviewCompactionParams {
  sessionId: string;
}

export interface ContextPreviewCompactionResult {
  tokensBefore: number;
  tokensAfter: number;
  compressionRatio: number;
  preservedTurns: number;
  summarizedTurns: number;
  summary: string;
}

/** Confirm and execute compaction */
export interface ContextConfirmCompactionParams {
  sessionId: string;
  /** Optional user-edited summary to use instead of generated one */
  editedSummary?: string;
}

export interface ContextConfirmCompactionResult {
  success: boolean;
  tokensBefore: number;
  tokensAfter: number;
  compressionRatio: number;
  summary: string;
}

/** Pre-turn validation to check if turn can proceed */
export interface ContextCanAcceptTurnParams {
  sessionId: string;
  estimatedResponseTokens: number;
}

export interface ContextCanAcceptTurnResult {
  canProceed: boolean;
  needsCompaction: boolean;
  wouldExceedLimit: boolean;
  currentTokens: number;
  estimatedAfterTurn: number;
  contextLimit: number;
}

/** Clear all messages from context */
export interface ContextClearParams {
  sessionId: string;
}

export interface ContextClearResult {
  success: boolean;
  tokensBefore: number;
  tokensAfter: number;
}

/** Compact context */
export interface ContextCompactParams {
  sessionId: string;
}

export interface ContextCompactResult {
  success: boolean;
  tokensBefore: number;
  tokensAfter: number;
  compressionRatio: number;
}
