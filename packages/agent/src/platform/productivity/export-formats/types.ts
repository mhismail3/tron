/**
 * @fileoverview Export Format Types
 *
 * Shared types for transcript export formatters.
 */

// =============================================================================
// Export Options
// =============================================================================

export interface ExportOptions {
  /** Include tool calls in export */
  includeToolCalls?: boolean;
  /** Include thinking blocks in export */
  includeThinking?: boolean;
  /** Include session metadata */
  includeMetadata?: boolean;
  /** Include token/cost information */
  includeStats?: boolean;
  /** Custom title for the export */
  title?: string;
}

// =============================================================================
// Metadata
// =============================================================================

export interface ExportMetadata {
  sessionId?: string;
  model?: string;
  startTime?: string;
  endTime?: string;
  totalTokens?: { input: number; output: number };
  cost?: number;
}

// =============================================================================
// Transcript Entry
// =============================================================================

export interface TranscriptEntry {
  role: 'user' | 'assistant' | 'system' | 'tool';
  content: string;
  timestamp?: string;
  toolName?: string;
  toolArgs?: Record<string, unknown>;
  thinking?: string;
}
