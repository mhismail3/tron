/**
 * @fileoverview Context Management Types
 *
 * Shared types for context management components:
 * - ContextManager configuration and state
 * - Snapshot structures for context auditing
 * - Compaction preview and result types
 * - Turn validation types
 */

import type { Message, Tool } from '@core/types/index.js';
import type { ExtractedData } from './summarizer.js';

// =============================================================================
// Threshold Configuration
// =============================================================================

export type ThresholdLevel = 'normal' | 'warning' | 'alert' | 'critical' | 'exceeded';

export const THRESHOLDS = {
  warning: 0.50, // 50% - yellow zone
  alert: 0.70, // 70% - orange zone, suggest compaction
  critical: 0.85, // 85% - red zone, block new turns
  exceeded: 0.95, // 95% - hard limit
} as const;

// =============================================================================
// Configuration
// =============================================================================

export interface ContextManagerConfig {
  model: string;
  /** Custom system prompt - if not provided, loads from .tron/SYSTEM.md or uses TRON_CORE_PROMPT */
  systemPrompt?: string;
  /** Working directory for file operations */
  workingDirectory?: string;
  tools?: Tool[];
  /** Rules content from AGENTS.md / CLAUDE.md hierarchy */
  rulesContent?: string;
  compaction?: {
    /** Threshold ratio (0-1) to trigger compaction suggestion (default: 0.70) */
    threshold?: number;
    /** Number of recent turns to preserve during compaction (default: 5) */
    preserveRecentTurns?: number;
  };
}

// =============================================================================
// Rules Snapshot
// =============================================================================

/** Information about a loaded rules file for context auditing */
export interface RulesFileSnapshot {
  /** Absolute path to the file */
  path: string;
  /** Path relative to working directory */
  relativePath: string;
  /** Level in hierarchy: global, project, or directory */
  level: 'global' | 'project' | 'directory';
  /** Depth from project root (-1 for global) */
  depth: number;
}

/** Rules section for context snapshot */
export interface RulesSnapshot {
  /** List of loaded rules files */
  files: RulesFileSnapshot[];
  /** Total number of rules files */
  totalFiles: number;
  /** Estimated token count for merged rules content */
  tokens: number;
}

// =============================================================================
// Context Snapshot
// =============================================================================

export interface ContextSnapshot {
  currentTokens: number;
  contextLimit: number;
  usagePercent: number;
  thresholdLevel: ThresholdLevel;
  breakdown: {
    systemPrompt: number;
    tools: number;
    rules: number;
    messages: number;
  };
  /** Loaded rules files (if any) */
  rules?: RulesSnapshot;
}

/**
 * Detailed message info for context auditing
 */
export interface DetailedMessageInfo {
  index: number;
  role: 'user' | 'assistant' | 'toolResult';
  tokens: number;
  /** Summary for display (truncated content or tool info) */
  summary: string;
  /** Full content for expansion */
  content: string;
  /** Event ID for this message (for deletion support) - undefined for synthetic messages */
  eventId?: string;
  /** For tool calls within assistant messages */
  toolCalls?: Array<{
    id: string;
    name: string;
    tokens: number;
    arguments: string;
  }>;
  /** For tool result messages */
  toolCallId?: string;
  isError?: boolean;
}

/**
 * Detailed context snapshot with per-message token breakdown
 */
export interface DetailedContextSnapshot extends ContextSnapshot {
  messages: DetailedMessageInfo[];
  /** Effective system-level context sent to the model */
  systemPromptContent: string;
  /** Raw tool clarification content if applicable (for debugging) */
  toolClarificationContent?: string;
  toolsContent: string[];
}

// =============================================================================
// Turn Validation
// =============================================================================

export interface PreTurnValidation {
  canProceed: boolean;
  needsCompaction: boolean;
  wouldExceedLimit: boolean;
  currentTokens: number;
  estimatedAfterTurn: number;
  contextLimit: number;
}

// =============================================================================
// Compaction
// =============================================================================

export interface CompactionPreview {
  tokensBefore: number;
  tokensAfter: number;
  compressionRatio: number;
  preservedTurns: number;
  summarizedTurns: number;
  summary: string;
  extractedData?: ExtractedData;
}

export interface CompactionResult {
  success: boolean;
  tokensBefore: number;
  tokensAfter: number;
  compressionRatio: number;
  summary: string;
  extractedData?: ExtractedData;
}

// =============================================================================
// Tool Result Processing
// =============================================================================

export interface ProcessedToolResult {
  toolCallId: string;
  content: string;
  truncated: boolean;
  originalSize?: number;
}

// =============================================================================
// Session Memory
// =============================================================================

export interface SessionMemoryEntry {
  title: string;
  content: string;
  tokens: number;
}

// =============================================================================
// Serialization
// =============================================================================

export interface ExportedState {
  model: string;
  systemPrompt: string;
  tools: Tool[];
  messages: Message[];
}
