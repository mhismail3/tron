/**
 * @fileoverview Agent RPC Types
 *
 * Types for agent interaction methods.
 */

import type { ContentSequenceItem } from '@runtime/orchestrator/turn/content-block-builder.js';

// =============================================================================
// Agent Methods
// =============================================================================

/**
 * File attachment from client (iOS app or web)
 * Supports images (JPEG, PNG, GIF, WebP) and documents (PDF)
 */
export interface FileAttachment {
  /** Base64 encoded file data */
  data: string;
  /** MIME type (e.g., "image/jpeg", "application/pdf") */
  mimeType: string;
  /** Optional original filename */
  fileName?: string;
}

/**
 * Skill reference sent with a prompt (explicitly selected by user)
 * These are skills the user selected via the skill sheet or @mention
 */
export interface PromptSkillReference {
  /** Skill name */
  name: string;
  /** Where the skill is from */
  source: 'global' | 'project';
}

/** Send prompt to agent */
export interface AgentPromptParams {
  /** Session to send to */
  sessionId: string;
  /** User message */
  prompt: string;
  /** Optional image attachments (base64) - legacy, use attachments instead */
  images?: FileAttachment[];
  /** Optional file attachments (images and PDFs) */
  attachments?: FileAttachment[];
  /** Reasoning effort level for models with reasoning/effort support (Codex, Opus 4.6) */
  reasoningLevel?: 'low' | 'medium' | 'high' | 'xhigh' | 'max';
  /** Skills explicitly selected by user (via skill sheet or @mention in prompt) */
  skills?: PromptSkillReference[];
  /**
   * Spells (ephemeral skills) - injected for one prompt only, not tracked.
   * Spells are automatically "forgotten" after the turn.
   */
  spells?: PromptSkillReference[];
}

export interface AgentPromptResult {
  /** Response will be streamed via events */
  acknowledged: boolean;
  /** Unique run ID for correlating events to this prompt */
  runId?: string;
  /** Client-provided request ID echoed back for correlation */
  clientRequestId?: string;
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

/** Tool call info for in-progress turn */
export interface CurrentTurnToolCall {
  toolCallId: string;
  toolName: string;
  arguments: Record<string, unknown>;
  status: 'pending' | 'running' | 'completed' | 'error';
  result?: string;
  isError?: boolean;
  startedAt: string;
  completedAt?: string;
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
  /** Accumulated text from current in-progress turn (for resume) */
  currentTurnText?: string;
  /** Tool calls from current in-progress turn (for resume) */
  currentTurnToolCalls?: CurrentTurnToolCall[];
  /** Structured content sequence for catch-up (interleaved text/thinking/tool_ref) */
  contentSequence?: ContentSequenceItem[];
  /** Whether the session was interrupted */
  wasInterrupted: boolean;
}
