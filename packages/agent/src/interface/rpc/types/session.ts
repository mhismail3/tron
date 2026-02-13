/**
 * @fileoverview Session RPC Types
 *
 * Types for session management methods.
 */

import type { SessionEvent, Message, TokenUsage } from '@infrastructure/events/types.js';

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
  /** Include archived sessions (default: false) */
  includeArchived?: boolean;
  /** Offset for pagination */
  offset?: number;
}

export interface SessionListResult {
  sessions: Array<{
    sessionId: string;
    workingDirectory: string;
    title?: string;
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
    isArchived: boolean;
    parentSessionId?: string;
    /** Last user prompt text (for preview display) */
    lastUserPrompt?: string;
    /** Last assistant response text (for preview display) */
    lastAssistantResponse?: string;
  }>;
}

/** Delete session */
export interface SessionDeleteParams {
  sessionId: string;
}

export interface SessionDeleteResult {
  deleted: boolean;
}

/** Archive session */
export interface SessionArchiveParams {
  sessionId: string;
}

export interface SessionArchiveResult {
  archived: boolean;
}

/** Unarchive session */
export interface SessionUnarchiveParams {
  sessionId: string;
}

export interface SessionUnarchiveResult {
  unarchived: boolean;
}

/** Fork session from specific event */
export interface SessionForkParams {
  sessionId: string;
  /** Event ID to fork from (uses session head if not specified) */
  fromEventId?: string;
  /** Name for the forked session */
  name?: string;
  /** Model for the forked session (inherits from source if not specified) */
  model?: string;
}

export interface SessionForkResult {
  newSessionId: string;
  rootEventId: string;
  forkedFromEventId: string;
  forkedFromSessionId: string;
}

/** Get session head event */
export interface SessionGetHeadParams {
  sessionId: string;
}

export interface SessionGetHeadResult {
  sessionId: string;
  headEventId: string;
  headEvent: SessionEvent;
}

/** Get full session state at head */
export interface SessionGetStateParams {
  sessionId: string;
  /** Optional: get state at specific event (defaults to head) */
  atEventId?: string;
}

export interface SessionGetStateResult {
  sessionId: string;
  workspaceId: string;
  headEventId: string;
  model: string;
  workingDirectory: string;
  messages: Message[];
  tokenUsage: TokenUsage;
  turnCount: number;
  eventCount: number;
}
