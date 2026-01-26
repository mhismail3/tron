/**
 * @fileoverview Memory RPC Types
 *
 * Types for memory operations methods.
 */

// =============================================================================
// Memory Methods
// =============================================================================

/** Search memory */
export interface MemorySearchParams {
  searchText?: string;
  type?: 'pattern' | 'decision' | 'preference' | 'lesson' | 'error';
  source?: 'immediate' | 'session' | 'project' | 'global';
  limit?: number;
}

export interface RpcMemorySearchResult {
  entries: Array<{
    id: string;
    type: string;
    content: string;
    source: string;
    relevance: number;
    timestamp: string;
  }>;
  totalCount: number;
}

/** Alias for backward compatibility */
export type MemorySearchResultRpc = RpcMemorySearchResult;

/** Add memory entry */
export interface MemoryAddEntryParams {
  type: 'pattern' | 'decision' | 'preference' | 'lesson' | 'error';
  content: string;
  source?: 'project' | 'global';
  metadata?: Record<string, unknown>;
}

export interface MemoryAddEntryResult {
  id: string;
  created: boolean;
}

/** Get handoffs */
export interface MemoryGetHandoffsParams {
  workingDirectory?: string;
  limit?: number;
}

export interface MemoryGetHandoffsResult {
  handoffs: Array<{
    id: string;
    sessionId: string;
    summary: string;
    createdAt: string;
  }>;
}
