/**
 * @fileoverview Sub-Agent Query Handler
 *
 * Handles querying sub-agent status, events, logs, and output.
 */
import { createLogger } from '../../../logging/logger.js';
import type { EventStore } from '../../../events/event-store.js';
import type {
  SessionId,
  SessionEvent as TronSessionEvent,
} from '../../../events/types.js';
import type { SubagentQueryType } from '../../../tools/subagent/query-subagent.js';
import type { ActiveSession } from '../../types.js';
import type { QuerySubagentResult } from './types.js';

const logger = createLogger('subagent-query');

// =============================================================================
// Types
// =============================================================================

/**
 * Dependencies for QueryHandler
 */
export interface QueryHandlerDeps {
  /** EventStore for querying session data */
  eventStore: EventStore;
  /** Get active session by ID */
  getActiveSession: (sessionId: string) => ActiveSession | undefined;
}

// =============================================================================
// QueryHandler Class
// =============================================================================

/**
 * Handles querying sub-agent status, events, logs, and output.
 */
export class QueryHandler {
  private deps: QueryHandlerDeps;

  constructor(deps: QueryHandlerDeps) {
    this.deps = deps;
  }

  /**
   * Query a sub-agent's status, events, logs, or output.
   */
  async querySubagent(
    sessionId: string,
    queryType: SubagentQueryType,
    limit?: number
  ): Promise<QuerySubagentResult> {
    try {
      // Get session info from event store
      const session = await this.deps.eventStore.getSession(
        sessionId as SessionId
      );
      if (!session) {
        return { success: false, error: 'Session not found' };
      }

      switch (queryType) {
        case 'status': {
          const isEnded = session.endedAt !== null;
          let status: 'running' | 'completed' | 'failed' | 'unknown' =
            'unknown';
          if (this.deps.getActiveSession(sessionId)) {
            status = 'running';
          } else if (isEnded) {
            // Check if there's a failure event
            const allEvents = session.headEventId
              ? await this.deps.eventStore.getAncestors(session.headEventId)
              : [];
            // Take last 20 events to check for errors
            const events = allEvents.slice(-20);
            const hasFailed = events.some((e) => e.type === 'error.agent');
            status = hasFailed ? 'failed' : 'completed';
          }

          return {
            success: true,
            status: {
              sessionId,
              status,
              spawnType: session.spawnType as
                | 'subsession'
                | 'tmux'
                | 'fork'
                | null,
              task: session.spawnTask,
              turnCount: session.turnCount,
              inputTokens: session.totalInputTokens,
              outputTokens: session.totalOutputTokens,
              cost: session.totalCost,
              createdAt: session.createdAt,
              lastActivityAt: session.lastActivityAt,
              endedAt: session.endedAt,
              model: session.latestModel,
              workingDirectory: session.workingDirectory,
            },
          };
        }

        case 'events': {
          const allEvents = session.headEventId
            ? await this.deps.eventStore.getAncestors(session.headEventId)
            : [];
          // Take last N events
          const events = allEvents.slice(-(limit ?? 20));

          return {
            success: true,
            events: events.reverse().map((e) => ({
              id: e.id,
              type: e.type,
              timestamp: e.timestamp,
              summary: this.summarizeEvent(e),
            })),
          };
        }

        case 'logs': {
          // Query logs table for this session
          const logs = await this.deps.eventStore.getLogsForSession(
            sessionId as SessionId,
            limit ?? 20
          );
          return {
            success: true,
            logs: logs.map(
              (l: {
                timestamp: string;
                level: string;
                component: string;
                message: string;
              }) => ({
                timestamp: l.timestamp,
                level: l.level,
                component: l.component,
                message: l.message,
              })
            ),
          };
        }

        case 'output': {
          // Get the last assistant message from the session
          const allEvents = session.headEventId
            ? await this.deps.eventStore.getAncestors(session.headEventId)
            : [];
          // Take last 50 events to find assistant message
          const events = allEvents.slice(-50);

          const lastAssistantMsg = events
            .reverse()
            .find((e) => e.type === 'message.assistant');

          if (!lastAssistantMsg) {
            return { success: true, output: undefined };
          }

          // Extract text from content blocks
          const payload = lastAssistantMsg.payload as {
            content: Array<{ type: string; text?: string }>;
          };
          const text = payload.content
            ?.filter((b: { type: string }) => b.type === 'text')
            .map((b: { text?: string }) => b.text)
            .join('\n');

          return { success: true, output: text };
        }

        default:
          return { success: false, error: `Unknown query type: ${queryType}` };
      }
    } catch (error) {
      const err = error as Error;
      logger.error('Failed to query subagent', {
        sessionId,
        queryType,
        error: err.message,
      });
      return { success: false, error: err.message };
    }
  }

  /**
   * Summarize an event for display.
   */
  private summarizeEvent(event: TronSessionEvent): string {
    const payload = event.payload as Record<string, unknown>;
    switch (event.type) {
      case 'message.user':
        return `User: ${String(payload.content ?? '').slice(0, 50)}...`;
      case 'message.assistant':
        return `Assistant response (turn ${payload.turn ?? '?'})`;
      case 'tool.call':
        return `Tool call: ${payload.name ?? 'unknown'}`;
      case 'tool.result':
        return `Tool result: ${payload.isError ? 'error' : 'success'}`;
      case 'session.start':
        return 'Session started';
      case 'session.end':
        return `Session ended: ${payload.reason ?? 'unknown'}`;
      default:
        return event.type;
    }
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create a QueryHandler instance
 */
export function createQueryHandler(deps: QueryHandlerDeps): QueryHandler {
  return new QueryHandler(deps);
}
