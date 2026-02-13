/**
 * @fileoverview Session type definitions for the dashboard
 *
 * These types extend the base session types with computed display properties
 * optimized for the dashboard UI.
 */

import type { SessionId, WorkspaceId, EventId } from '@tron/agent';

/**
 * Session summary for list display
 */
export interface DashboardSessionSummary {
  id: SessionId;
  workspaceId: WorkspaceId;
  title: string | null;
  workingDirectory: string;
  model: string;
  createdAt: string;
  lastActivityAt: string;
  archivedAt: string | null;
  isArchived: boolean;

  // Counters
  eventCount: number;
  messageCount: number;
  turnCount: number;

  // Token usage
  totalInputTokens: number;
  totalOutputTokens: number;
  lastTurnInputTokens: number;
  totalCost: number;
  totalCacheReadTokens: number;
  totalCacheCreationTokens: number;

  // Preview
  lastUserPrompt?: string;
  lastAssistantResponse?: string;

  // Subagent info
  spawningSessionId: SessionId | null;
  spawnType: 'subsession' | 'tmux' | 'fork' | null;
  spawnTask: string | null;

  // Tags
  tags: string[];
}

/**
 * Token usage summary
 */
export interface TokenUsageSummary {
  inputTokens: number;
  outputTokens: number;
  totalTokens: number;
  cacheReadTokens: number;
  cacheCreationTokens: number;
  estimatedCost: number;
}

/**
 * Pagination options for queries
 */
export interface PaginationOptions {
  limit: number;
  offset: number;
}

/**
 * Paginated result wrapper
 */
export interface PaginatedResult<T> {
  items: T[];
  total: number;
  limit: number;
  offset: number;
  hasMore: boolean;
}

/**
 * Options for listing sessions
 */
export interface ListSessionsOptions extends Partial<PaginationOptions> {
  /** Filter by workspace */
  workspaceId?: WorkspaceId;
  /** Filter by archived state */
  archived?: boolean;
  /** Sort field */
  orderBy?: 'createdAt' | 'lastActivityAt';
  /** Sort direction */
  order?: 'asc' | 'desc';
  /** Include message previews */
  includePreview?: boolean;
}

/**
 * Dashboard statistics
 */
export interface DashboardStats {
  totalSessions: number;
  activeSessions: number;
  totalEvents: number;
  totalTokensUsed: number;
  totalCost: number;
}

/**
 * Format relative time string
 */
export function formatRelativeTime(date: string | Date): string {
  const now = Date.now();
  const then = typeof date === 'string' ? new Date(date).getTime() : date.getTime();
  const diffMs = now - then;
  const diffSeconds = Math.floor(diffMs / 1000);
  const diffMinutes = Math.floor(diffSeconds / 60);
  const diffHours = Math.floor(diffMinutes / 60);
  const diffDays = Math.floor(diffHours / 24);

  if (diffSeconds < 60) return 'just now';
  if (diffMinutes < 60) return `${diffMinutes}m ago`;
  if (diffHours < 24) return `${diffHours}h ago`;
  if (diffDays < 7) return `${diffDays}d ago`;

  return new Date(date).toLocaleDateString();
}

/**
 * Format token count with K/M suffixes
 */
export function formatTokenCount(count: number): string {
  if (count < 1000) return count.toString();
  if (count < 1000000) return `${(count / 1000).toFixed(1)}K`;
  return `${(count / 1000000).toFixed(2)}M`;
}

/**
 * Format cost in dollars
 */
export function formatCost(cost: number): string {
  if (cost < 0.01) return '< $0.01';
  return `$${cost.toFixed(2)}`;
}

/**
 * Truncate text with ellipsis
 */
export function truncateText(text: string, maxLength: number): string {
  if (text.length <= maxLength) return text;
  return text.slice(0, maxLength - 3) + '...';
}
