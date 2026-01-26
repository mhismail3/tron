/**
 * @fileoverview Tree RPC Types
 *
 * Types for tree visualization and navigation methods.
 */

import type { EventType, SessionEvent } from '../../events/types.js';

// =============================================================================
// Tree Methods
// =============================================================================

/** Tree node for visualization */
export interface TreeNodeCompact {
  id: string;
  parentId: string | null;
  type: EventType;
  timestamp: string;
  /** Summary of event content (first 100 chars) */
  summary: string;
  hasChildren: boolean;
  childCount: number;
  depth: number;
  isBranchPoint: boolean;
  isHead: boolean;
  /** Branch name if this is a fork point */
  branchName?: string;
}

/** Get tree visualization for a session */
export interface TreeGetVisualizationParams {
  sessionId: string;
  /** Max depth to fetch (for lazy loading) */
  maxDepth?: number;
  /** Only include message events for compact view */
  messagesOnly?: boolean;
}

export interface TreeGetVisualizationResult {
  sessionId: string;
  rootEventId: string;
  headEventId: string;
  nodes: TreeNodeCompact[];
  /** Total event count in session */
  totalEvents: number;
}

/** Get branches for a session */
export interface TreeGetBranchesParams {
  sessionId: string;
}

export interface TreeBranchInfo {
  sessionId: string;
  name?: string;
  forkEventId: string;
  headEventId: string;
  messageCount: number;
  createdAt: string;
  lastActivity: string;
}

export interface TreeGetBranchesResult {
  /** Original session */
  mainBranch: TreeBranchInfo;
  /** Forked sessions */
  forks: TreeBranchInfo[];
}

/** Get subtree starting from an event */
export interface TreeGetSubtreeParams {
  eventId: string;
  /** Max depth to fetch */
  maxDepth?: number;
  /** Direction: 'descendants' (default) or 'ancestors' */
  direction?: 'descendants' | 'ancestors';
}

export interface TreeGetSubtreeResult {
  rootEventId: string;
  nodes: TreeNodeCompact[];
  hasMore: boolean;
}

/** Get ancestors of an event */
export interface TreeGetAncestorsParams {
  eventId: string;
  /** Limit number of ancestors */
  limit?: number;
}

export interface TreeGetAncestorsResult {
  ancestors: SessionEvent[];
  /** The event requested */
  targetEvent: SessionEvent;
}

/** Compare two branches */
export interface TreeCompareBranchesParams {
  /** First session/branch */
  sessionId1: string;
  /** Second session/branch */
  sessionId2: string;
}

export interface TreeCompareBranchesResult {
  /** Common ancestor event */
  commonAncestorEventId: string | null;
  /** Events unique to first branch */
  uniqueToFirst: number;
  /** Events unique to second branch */
  uniqueToSecond: number;
  /** Shared events (before divergence) */
  sharedEvents: number;
  /** Divergence point event */
  divergenceEventId: string | null;
}
