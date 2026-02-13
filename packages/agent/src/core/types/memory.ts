/**
 * @fileoverview Memory types - simplified
 *
 * Basic types for session memory and handoff tracking.
 * Complex episodic/pattern/lesson memory has been removed for simplicity.
 */

import type { Message, ToolCall } from './messages.js';

// =============================================================================
// Session Memory (simple, in-memory during session)
// =============================================================================

/**
 * Session memory - active conversation context
 */
export interface SessionMemory {
  sessionId: string;
  startedAt: string;
  completedAt?: string;
  messages: Message[];
  toolCalls: ToolCall[];
  workingDirectory: string;
  activeFiles: string[];
  context: Record<string, unknown>;
  parentHandoffId?: string;  // If continuing from handoff
  tokenUsage?: {
    input: number;
    output: number;
  };
}

// =============================================================================
// Handoff System
// =============================================================================

/**
 * Handoff record for session continuation
 */
export interface HandoffRecord {
  id: string;
  sessionId: string;
  createdAt: string;
  summary: string;
  pendingTasks?: string[];
  context: Record<string, unknown>;
  messageCount: number;
  toolCallCount: number;
  parentHandoffId?: string;
  compressedMessages?: string;  // Summarized conversation
  keyInsights?: string[];
}

