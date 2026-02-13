/**
 * @fileoverview Dashboard Session Repository
 *
 * Repository for session-related queries optimized for dashboard display.
 * Extends the base session repository with dashboard-specific aggregations.
 */

import type { SQLiteEventStore, SessionId, WorkspaceId } from '@tron/agent';
import type {
  IDashboardSessionRepository,
} from './types.js';
import type {
  DashboardSessionSummary,
  TokenUsageSummary,
  ListSessionsOptions,
  DashboardStats,
  PaginationOptions,
} from '../../types/session.js';
import type { TimelineEntry } from '../../types/display.js';
import {
  getEventTypeLabel,
  getEventIcon,
  getEventSeverity,
} from '../../types/display.js';
import { formatRelativeTime } from '../../types/session.js';

/**
 * Repository for session queries optimized for dashboard UI
 */
export class DashboardSessionRepository implements IDashboardSessionRepository {
  constructor(private readonly store: SQLiteEventStore) {}

  /**
   * List sessions with stats and optional preview
   */
  async listWithStats(options: ListSessionsOptions = {}): Promise<DashboardSessionSummary[]> {
    const {
      workspaceId,
      archived,
      limit = 100,
      offset = 0,
      orderBy = 'lastActivityAt',
      order = 'desc',
      includePreview = false,
    } = options;

    const sessions = await this.store.listSessions({
      workspaceId,
      archived,
      limit,
      offset,
      orderBy,
      order,
    });

    // Fetch message previews if requested
    let previews = new Map<SessionId, { lastUserPrompt?: string; lastAssistantResponse?: string }>();
    if (includePreview && sessions.length > 0) {
      const sessionIds = sessions.map((s) => s.id);
      previews = await this.store.getSessionMessagePreviews(sessionIds);
    }

    return sessions.map((session) => {
      const preview = previews.get(session.id) || {};
      return this.toSummary(session, preview);
    });
  }

  /**
   * Get a single session by ID with full details
   */
  async getById(sessionId: SessionId): Promise<DashboardSessionSummary | null> {
    const session = await this.store.getSession(sessionId);
    if (!session) return null;

    // Get preview for this session
    const previews = await this.store.getSessionMessagePreviews([sessionId]);
    const preview = previews.get(sessionId) || {};

    return this.toSummary(session, preview);
  }

  /**
   * Get session timeline as display-ready entries
   */
  async getSessionTimeline(
    sessionId: SessionId,
    options?: PaginationOptions
  ): Promise<TimelineEntry[]> {
    const events = await this.store.getEventsBySession(sessionId, options);

    return events.map((event) => ({
      event,
      typeLabel: getEventTypeLabel(event.type),
      displayTime: formatRelativeTime(event.timestamp),
      collapsible: this.isCollapsible(event.type),
      icon: getEventIcon(event.type),
      severity: getEventSeverity(event.type),
    }));
  }

  /**
   * Get token usage summary for a session
   */
  async getTokenUsageBySession(sessionId: SessionId): Promise<TokenUsageSummary> {
    const session = await this.store.getSession(sessionId);
    if (!session) {
      return {
        inputTokens: 0,
        outputTokens: 0,
        totalTokens: 0,
        cacheReadTokens: 0,
        cacheCreationTokens: 0,
        estimatedCost: 0,
      };
    }

    return {
      inputTokens: session.totalInputTokens,
      outputTokens: session.totalOutputTokens,
      totalTokens: session.totalInputTokens + session.totalOutputTokens,
      cacheReadTokens: session.totalCacheReadTokens,
      cacheCreationTokens: session.totalCacheCreationTokens,
      estimatedCost: session.totalCost,
    };
  }

  /**
   * Get dashboard-wide statistics
   */
  async getStats(): Promise<DashboardStats> {
    const storeStats = await this.store.getStats();

    // Calculate aggregates from all sessions
    const allSessions = await this.store.listSessions({ limit: 10000 });

    let totalTokensUsed = 0;
    let totalCost = 0;
    let activeSessions = 0;

    for (const session of allSessions) {
      totalTokensUsed += session.totalInputTokens + session.totalOutputTokens;
      totalCost += session.totalCost;
      if (!session.isArchived) activeSessions++;
    }

    return {
      totalSessions: storeStats.totalSessions,
      activeSessions,
      totalEvents: storeStats.totalEvents,
      totalTokensUsed,
      totalCost,
    };
  }

  /**
   * Count total sessions matching filters
   */
  async count(options?: Pick<ListSessionsOptions, 'workspaceId' | 'archived'>): Promise<number> {
    const sessions = await this.store.listSessions({
      ...options,
      limit: 100000, // Large limit to count all
    });
    return sessions.length;
  }

  /**
   * Convert session row to dashboard summary
   */
  private toSummary(
    session: Awaited<ReturnType<SQLiteEventStore['getSession']>> & {},
    preview: { lastUserPrompt?: string; lastAssistantResponse?: string }
  ): DashboardSessionSummary {
    return {
      id: session.id,
      workspaceId: session.workspaceId,
      title: session.title,
      workingDirectory: session.workingDirectory,
      model: session.latestModel,
      createdAt: session.createdAt,
      lastActivityAt: session.lastActivityAt,
      archivedAt: session.archivedAt,
      isArchived: session.isArchived,
      eventCount: session.eventCount,
      messageCount: session.messageCount,
      turnCount: session.turnCount,
      totalInputTokens: session.totalInputTokens,
      totalOutputTokens: session.totalOutputTokens,
      lastTurnInputTokens: session.lastTurnInputTokens,
      totalCost: session.totalCost,
      totalCacheReadTokens: session.totalCacheReadTokens,
      totalCacheCreationTokens: session.totalCacheCreationTokens,
      lastUserPrompt: preview.lastUserPrompt,
      lastAssistantResponse: preview.lastAssistantResponse,
      spawningSessionId: session.spawningSessionId,
      spawnType: session.spawnType,
      spawnTask: session.spawnTask,
      tags: session.tags,
    };
  }

  /**
   * Determine if an event type should be collapsible in the timeline
   */
  private isCollapsible(type: string): boolean {
    // System events and streaming events are collapsible
    return (
      type.startsWith('stream.') ||
      type.startsWith('config.') ||
      type.startsWith('compact.') ||
      type.startsWith('hook.') ||
      type === 'rules.loaded' ||
      type === 'context.cleared'
    );
  }
}
