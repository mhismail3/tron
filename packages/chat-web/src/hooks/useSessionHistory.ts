/**
 * @fileoverview Session History Hook
 *
 * Loads session events from server and provides tree visualization
 * and fork functionality for the session history panel.
 */

import { useCallback, useEffect, useMemo, useState } from 'react';
import type { CachedEvent } from '../store/event-db.js';
import type { TreeNode } from '../components/tree/index.js';

// =============================================================================
// Types
// =============================================================================

export interface TreeBranchInfo {
  sessionId: string;
  name?: string;
  forkEventId: string;
  headEventId: string;
  messageCount: number;
  createdAt: string;
  lastActivity: string;
}

export interface BranchesResult {
  mainBranch: TreeBranchInfo;
  forks: TreeBranchInfo[];
}

export interface UseSessionHistoryOptions {
  /** Current session ID */
  sessionId: string | null;
  /** RPC call function */
  rpcCall: <T>(method: string, params?: unknown) => Promise<T>;
  /** Current head event ID (optional - will be fetched if not provided) */
  headEventId?: string | null;
  /** Whether to also fetch branches */
  includeBranches?: boolean;
}

export interface UseSessionHistoryReturn {
  /** Raw events from the session */
  events: CachedEvent[];
  /** Events converted to tree nodes for visualization */
  treeNodes: TreeNode[];
  /** Whether currently loading */
  isLoading: boolean;
  /** Error message if any */
  error: string | null;
  /** Current head event ID */
  headEventId: string | null;
  /** Branch information (if includeBranches is true) */
  branches: BranchesResult | null;
  /** Number of branch points in the tree */
  branchCount: number;
  /** Refresh events from server */
  refresh: () => Promise<void>;
  /** Fork session from an event */
  fork: (eventId: string) => Promise<{ newSessionId: string; rootEventId: string } | null>;
}

// =============================================================================
// Hook
// =============================================================================

export function useSessionHistory({
  sessionId,
  rpcCall,
  headEventId: providedHeadEventId,
  includeBranches = false,
}: UseSessionHistoryOptions): UseSessionHistoryReturn {
  const [events, setEvents] = useState<CachedEvent[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [headEventId, setHeadEventId] = useState<string | null>(providedHeadEventId ?? null);
  const [branches, setBranches] = useState<BranchesResult | null>(null);

  // Keep headEventId in sync with prop
  useEffect(() => {
    if (providedHeadEventId !== undefined) {
      setHeadEventId(providedHeadEventId ?? null);
    }
  }, [providedHeadEventId]);

  // Fetch events from server
  const fetchEvents = useCallback(async () => {
    if (!sessionId) {
      setEvents([]);
      return;
    }

    setIsLoading(true);
    setError(null);

    try {
      const response = await rpcCall<{
        events: CachedEvent[];
        hasMore: boolean;
        headEventId?: string;
      }>('events.getHistory', {
        sessionId,
      });

      setEvents(response.events || []);
      if (response.headEventId && !providedHeadEventId) {
        setHeadEventId(response.headEventId);
      }
    } catch (err) {
      const errorMessage = err instanceof Error ? err.message : 'Failed to fetch events';
      setError(errorMessage);
      setEvents([]);
    } finally {
      setIsLoading(false);
    }
  }, [sessionId, rpcCall, providedHeadEventId]);

  // Fetch branches if requested
  const fetchBranches = useCallback(async () => {
    if (!sessionId || !includeBranches) return;

    try {
      const response = await rpcCall<BranchesResult>('tree.getBranches', {
        sessionId,
      });
      setBranches(response);
    } catch (err) {
      console.error('[useSessionHistory] Failed to fetch branches:', err);
    }
  }, [sessionId, rpcCall, includeBranches]);

  // Load events when sessionId changes
  useEffect(() => {
    fetchEvents();
    fetchBranches();
  }, [fetchEvents, fetchBranches]);

  // Convert events to tree nodes
  const treeNodes: TreeNode[] = useMemo(() => {
    if (events.length === 0) return [];

    // Count children for each event
    const childCounts = new Map<string | null, number>();
    for (const event of events) {
      const count = childCounts.get(event.parentId) || 0;
      childCounts.set(event.parentId, count + 1);
    }

    // Find children for each event
    const eventChildren = new Map<string | null, CachedEvent[]>();
    for (const event of events) {
      const siblings = eventChildren.get(event.parentId) || [];
      siblings.push(event);
      eventChildren.set(event.parentId, siblings);
    }

    return events.map((event) => {
      const childCount = childCounts.get(event.id) || 0;
      const parentChildCount = childCounts.get(event.parentId) || 1;

      return {
        id: event.id,
        parentId: event.parentId,
        type: event.type,
        timestamp: event.timestamp,
        summary: getEventSummary(event),
        hasChildren: childCount > 0,
        childCount,
        depth: 0, // Will be calculated by tree component
        isBranchPoint: parentChildCount > 1 && event.parentId !== null
          ? false // Current event is not a branch point, but its parent might be
          : childCount > 1, // This event has multiple children = branch point
        isHead: event.id === headEventId,
      };
    });
  }, [events, headEventId]);

  // Count branch points
  const branchCount = useMemo(() => {
    return treeNodes.filter((n) => n.isBranchPoint).length;
  }, [treeNodes]);

  // Fork operation
  const fork = useCallback(
    async (eventId: string): Promise<{ newSessionId: string; rootEventId: string } | null> => {
      if (!sessionId) return null;

      setError(null);

      try {
        const response = await rpcCall<{
          newSessionId: string;
          rootEventId: string;
          forkedFromEventId: string;
          forkedFromSessionId: string;
        }>('session.fork', {
          sessionId,
          fromEventId: eventId,
        });

        return {
          newSessionId: response.newSessionId,
          rootEventId: response.rootEventId,
        };
      } catch (err) {
        const errorMessage = err instanceof Error ? err.message : 'Fork failed';
        setError(errorMessage);
        return null;
      }
    },
    [sessionId, rpcCall]
  );

  // Refresh function
  const refresh = useCallback(async () => {
    await fetchEvents();
    await fetchBranches();
  }, [fetchEvents, fetchBranches]);

  return {
    events,
    treeNodes,
    isLoading,
    error,
    headEventId,
    branches,
    branchCount,
    refresh,
    fork,
  };
}

// =============================================================================
// Helpers
// =============================================================================

function getEventSummary(event: CachedEvent): string {
  const payload = event.payload || {};

  switch (event.type) {
    case 'session.start':
      return `Session started: ${(payload as { title?: string }).title || 'New Session'}`;
    case 'session.end':
      return 'Session ended';
    case 'session.fork':
      return `Forked from ${(payload as { sourceEventId?: string }).sourceEventId || 'unknown'}`;
    case 'message.user':
      return truncate(String((payload as { content?: string }).content || 'User message'), 80);
    case 'message.assistant':
      return truncate(String((payload as { content?: string }).content || 'Assistant response'), 80);
    case 'tool.call':
      return `Tool: ${(payload as { toolName?: string }).toolName || 'unknown'}`;
    case 'tool.result':
      return `Result: ${(payload as { success?: boolean }).success ? 'success' : 'error'}`;
    case 'config.model_switch':
      return `Model: ${(payload as { previousModel?: string }).previousModel || '?'} → ${(payload as { newModel?: string }).newModel || '?'}`;
    case 'compact.boundary':
      return 'Context compacted';
    default:
      return event.type;
  }
}

function truncate(text: string, maxLength: number): string {
  if (text.length <= maxLength) return text;
  return text.slice(0, maxLength - 3) + '...';
}
