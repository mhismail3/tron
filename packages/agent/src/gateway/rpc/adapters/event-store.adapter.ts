/**
 * @fileoverview Event Store Adapter
 *
 * Adapts EventStoreOrchestrator event methods to the EventStoreManager
 * interface expected by RpcContext. Handles event history, tree operations,
 * search, and message deletion.
 */

import type { AdapterDependencies, EventStoreManagerAdapter } from '../types.js';
import type { SessionEvent } from '../../../events/types/index.js';

// =============================================================================
// Types
// =============================================================================

/**
 * Event store interface for recursive operations
 */
interface EventStoreWithChildren {
  getChildren(eventId: string): Promise<SessionEvent[]>;
}

/**
 * Helper to safely get payload property from event
 */
function getPayloadProp<T>(event: SessionEvent, key: string): T | undefined {
  const payload = (event as { payload?: Record<string, unknown> }).payload;
  return payload?.[key] as T | undefined;
}

// =============================================================================
// Helper Functions
// =============================================================================

/**
 * Get a human-readable summary of an event for tree visualization
 */
export function getEventSummary(event: SessionEvent): string {
  switch (event.type) {
    case 'session.start':
      return 'Session started';
    case 'session.end':
      return 'Session ended';
    case 'session.fork':
      return `Forked: ${getPayloadProp<string>(event, 'name') ?? 'unnamed'}`;
    case 'message.user': {
      const content = getPayloadProp<unknown>(event, 'content');
      return content ? String(content).slice(0, 50) : 'User message';
    }
    case 'message.assistant':
      return 'Assistant response';
    case 'tool.call':
      return `Tool: ${getPayloadProp<string>(event, 'name') ?? 'unknown'}`;
    case 'tool.result':
      return `Tool result (${getPayloadProp<boolean>(event, 'isError') ? 'error' : 'success'})`;
    default:
      return event.type;
  }
}

/**
 * Calculate the depth of an event in the tree
 */
export function getEventDepth(event: SessionEvent, allEvents: SessionEvent[]): number {
  let depth = 0;
  let current: SessionEvent | undefined = event;
  while (current?.parentId) {
    depth++;
    current = allEvents.find(e => e.id === current!.parentId);
  }
  return depth;
}

/**
 * Count descendants of an event recursively
 */
function getDescendantCount(eventId: string, allEvents: SessionEvent[]): number {
  const children = allEvents.filter(e => e.parentId === eventId);
  return children.length + children.reduce((sum, child) =>
    sum + getDescendantCount(child.id, allEvents), 0);
}

/**
 * Get all descendants of an event recursively
 */
async function getDescendantsRecursive(eventId: string, eventStore: EventStoreWithChildren): Promise<SessionEvent[]> {
  const children = await eventStore.getChildren(eventId);
  const descendants = [...children];
  for (const child of children) {
    const childDescendants = await getDescendantsRecursive(child.id, eventStore);
    descendants.push(...childDescendants);
  }
  return descendants;
}

// =============================================================================
// Adapter Factory
// =============================================================================

/**
 * Creates an EventStoreManager adapter from EventStoreOrchestrator
 */
export function createEventStoreAdapter(deps: AdapterDependencies): EventStoreManagerAdapter {
  const { orchestrator } = deps;
  const eventStore = orchestrator.getEventStore();

  return {
    async getEventHistory(sessionId, options) {
      const events = await orchestrator.events.getEvents(sessionId);

      let filtered = events;
      if (options?.types?.length) {
        filtered = events.filter(e => options.types!.includes(e.type));
      }

      const reversed = [...filtered].reverse();
      const limit = options?.limit ?? 100;
      const sliced = reversed.slice(0, limit);

      return {
        events: sliced,
        hasMore: filtered.length > limit,
        oldestEventId: sliced.at(-1)?.id,
      };
    },

    async getEventsSince(options) {
      const events = options.sessionId
        ? await orchestrator.events.getEvents(options.sessionId)
        : [];

      let filtered = events;
      if (options.afterEventId) {
        const idx = events.findIndex(e => e.id === options.afterEventId);
        if (idx >= 0) {
          filtered = events.slice(idx + 1);
        }
      } else if (options.afterTimestamp) {
        filtered = events.filter(e => e.timestamp > options.afterTimestamp!);
      }

      const limit = options.limit ?? 100;
      const sliced = filtered.slice(0, limit);

      return {
        events: sliced,
        nextCursor: sliced.at(-1)?.id,
        hasMore: filtered.length > limit,
      };
    },

    async appendEvent(sessionId, type, payload, parentId) {
      const event = await orchestrator.events.append({
        sessionId: sessionId as any,
        type: type as any,
        payload,
        parentId: parentId as any,
      });

      const session = await eventStore.getSession(sessionId as any);

      return {
        event,
        newHeadEventId: session?.headEventId ?? event.id,
      };
    },

    async getTreeVisualization(sessionId, options) {
      const session = await eventStore.getSession(sessionId as any);
      if (!session) {
        throw new Error(`Session not found: ${sessionId}`);
      }

      const events = await orchestrator.events.getEvents(sessionId);

      const nodes = events.map(e => ({
        id: e.id,
        parentId: e.parentId,
        type: e.type,
        timestamp: e.timestamp,
        summary: getEventSummary(e),
        hasChildren: events.some(other => other.parentId === e.id),
        childCount: events.filter(other => other.parentId === e.id).length,
        depth: getEventDepth(e, events),
        isBranchPoint: events.filter(other => other.parentId === e.id).length > 1,
        isHead: e.id === session.headEventId,
      }));

      const filtered = options?.messagesOnly
        ? nodes.filter(n => n.type.startsWith('message.'))
        : nodes;

      return {
        sessionId,
        rootEventId: session.rootEventId ?? '',
        headEventId: session.headEventId ?? '',
        nodes: filtered,
        totalEvents: events.length,
      };
    },

    async getBranches(sessionId) {
      const events = await orchestrator.events.getEvents(sessionId);
      const session = await eventStore.getSession(sessionId as any);

      const branchPoints = events.filter(e =>
        events.filter(other => other.parentId === e.id).length > 1
      );

      const branches = branchPoints.flatMap(bp => {
        const children = events.filter(e => e.parentId === bp.id);
        return children.map((child, idx) => ({
          branchPointEventId: bp.id,
          firstEventId: child.id,
          isMain: child.id === session?.headEventId || idx === 0,
          eventCount: getDescendantCount(child.id, events),
        }));
      });

      if (branches.length === 0 && events.length > 0) {
        const mainBranch = {
          branchPointEventId: null,
          firstEventId: events[0]?.id,
          isMain: true,
          eventCount: events.length,
        };
        return { mainBranch, forks: [] };
      }

      return {
        mainBranch: branches.find(b => b.isMain) ?? branches[0],
        forks: branches.filter(b => !b.isMain),
      };
    },

    async getSubtree(eventId, options) {
      if (options?.direction === 'ancestors') {
        const ancestors = await orchestrator.events.getAncestors(eventId);
        return { nodes: ancestors };
      }

      const descendants = await getDescendantsRecursive(eventId, eventStore);
      return { nodes: descendants };
    },

    async getAncestors(eventId) {
      const ancestors = await orchestrator.events.getAncestors(eventId);
      return { events: ancestors };
    },

    async searchContent(query, options) {
      const results = await orchestrator.events.search(query, {
        sessionId: options?.sessionId,
        workspaceId: options?.workspaceId,
        types: options?.types,
        limit: options?.limit,
      });

      return {
        results,
        totalCount: results.length,
      };
    },

    async deleteMessage(sessionId, targetEventId, reason) {
      const event = await orchestrator.events.deleteMessage(sessionId, targetEventId, reason);
      return { id: event.id, payload: event.payload };
    },
  };
}
