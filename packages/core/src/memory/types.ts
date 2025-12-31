/**
 * @fileoverview Memory types for the four-level memory hierarchy
 *
 * Memory hierarchy:
 * 1. Immediate: Current conversation context (in-memory)
 * 2. Session: Active working session with tool calls
 * 3. Project: Project-specific patterns, decisions, preferences
 * 4. Global: Cross-project learnings and statistics
 */

import type { Message, ToolCall } from '../types/index.js';

// =============================================================================
// Base Types
// =============================================================================

/**
 * Memory entry types
 */
export type MemoryEntryType =
  | 'pattern'      // Code/workflow patterns
  | 'decision'     // Architecture/design decisions
  | 'lesson'       // Learnings from mistakes/successes
  | 'context'      // Contextual information
  | 'preference';  // User preferences

/**
 * Memory source levels
 */
export type MemorySource = 'session' | 'project' | 'global';

/**
 * Base memory entry structure
 */
export interface MemoryEntry {
  id: string;
  type: MemoryEntryType;
  content: string;
  timestamp: string;
  source: MemorySource;
  metadata?: Record<string, unknown>;
  category?: string;
  tags?: string[];
  embedding?: number[];  // For semantic search
}

// =============================================================================
// Session Memory
// =============================================================================

/**
 * Session memory - active conversation context
 */
export interface SessionMemory {
  sessionId: string;
  startedAt: string;
  endedAt?: string;
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
// Project Memory
// =============================================================================

/**
 * Pattern entry with project-specific metadata
 */
export interface PatternEntry extends MemoryEntry {
  type: 'pattern';
  source: 'project';
  category?: string;
  confidence?: number;
  usageCount?: number;
}

/**
 * Decision entry with rationale
 */
export interface DecisionEntry extends MemoryEntry {
  type: 'decision';
  source: 'project';
  rationale?: string;
  alternatives?: string[];
  reversible?: boolean;
}

/**
 * Project-level memory store
 */
export interface ProjectMemory {
  projectPath: string;
  projectName: string;
  claudeMdPath?: string;
  patterns: PatternEntry[];
  decisions: DecisionEntry[];
  preferences: Record<string, unknown>;
  createdAt: string;
  updatedAt: string;
  statistics?: {
    totalSessions: number;
    totalToolCalls: number;
    filesModified: string[];
  };
}

// =============================================================================
// Global Memory
// =============================================================================

/**
 * Lesson learned across projects
 */
export interface LessonEntry extends MemoryEntry {
  type: 'lesson';
  source: 'global';
  projectPath?: string;  // Where it was learned
  applicability?: string[];  // Where it applies
}

/**
 * Global memory - cross-project learnings
 */
export interface GlobalMemory {
  userId?: string;
  lessons: LessonEntry[];
  preferences: Record<string, unknown>;
  statistics: {
    totalSessions: number;
    totalToolCalls: number;
    projectCount?: number;
  };
  createdAt: string;
  updatedAt: string;
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

// =============================================================================
// Ledger System
// =============================================================================

/**
 * Ledger entry for completed work tracking
 */
export interface LedgerEntry {
  id: string;
  timestamp: string;
  sessionId: string;
  action: string;
  description: string;
  filesModified?: string[];
  success: boolean;
  error?: string;
  duration?: number;
  metadata?: Record<string, unknown>;
}

// =============================================================================
// Query Types
// =============================================================================

/**
 * Query parameters for memory search
 */
export interface MemoryQuery {
  source?: MemorySource;
  type?: MemoryEntryType;
  limit?: number;
  offset?: number;
  searchText?: string;
  tags?: string[];
  after?: string;  // ISO timestamp
  before?: string; // ISO timestamp
  projectPath?: string;
}

/**
 * Search result structure
 */
export interface MemorySearchResult {
  entries: MemoryEntry[];
  totalCount: number;
  hasMore: boolean;
}

// =============================================================================
// Store Interface
// =============================================================================

/**
 * Memory store interface
 */
export interface MemoryStore {
  // Session operations
  createSession(session: Omit<SessionMemory, 'sessionId'>): Promise<SessionMemory>;
  getSession(sessionId: string): Promise<SessionMemory | null>;
  updateSession(sessionId: string, updates: Partial<SessionMemory>): Promise<void>;
  endSession(sessionId: string): Promise<HandoffRecord>;

  // Memory operations
  addEntry(entry: Omit<MemoryEntry, 'id' | 'timestamp'>): Promise<MemoryEntry>;
  getEntry(id: string): Promise<MemoryEntry | null>;
  searchEntries(query: MemoryQuery): Promise<MemorySearchResult>;
  deleteEntry(id: string): Promise<void>;

  // Handoff operations
  createHandoff(sessionId: string, summary: string): Promise<HandoffRecord>;
  getHandoff(handoffId: string): Promise<HandoffRecord | null>;
  listHandoffs(projectPath?: string): Promise<HandoffRecord[]>;

  // Ledger operations
  addLedgerEntry(entry: Omit<LedgerEntry, 'id' | 'timestamp'>): Promise<LedgerEntry>;
  getLedgerEntries(sessionId?: string): Promise<LedgerEntry[]>;

  // Project memory
  getProjectMemory(projectPath: string): Promise<ProjectMemory | null>;
  updateProjectMemory(projectPath: string, updates: Partial<ProjectMemory>): Promise<void>;

  // Global memory
  getGlobalMemory(): Promise<GlobalMemory>;
  updateGlobalMemory(updates: Partial<GlobalMemory>): Promise<void>;

  // Maintenance
  compact(): Promise<void>;
  vacuum(): Promise<void>;
  close(): Promise<void>;
}
