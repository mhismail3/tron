/**
 * @fileoverview Active Session Store
 *
 * Typed interface + Map-backed implementation for in-memory active session storage.
 * Replaces the 5 individual closure callbacks (get/set/delete/count/entries)
 * that were previously threaded through module configs.
 */
import type { ActiveSession } from '../types.js';

// =============================================================================
// Interface
// =============================================================================

export interface ActiveSessionStore {
  get(sessionId: string): ActiveSession | undefined;
  set(sessionId: string, session: ActiveSession): void;
  delete(sessionId: string): void;
  clear(): void;
  get size(): number;
  entries(): IterableIterator<[string, ActiveSession]>;
  values(): IterableIterator<ActiveSession>;
}

// =============================================================================
// Implementation
// =============================================================================

export class MapActiveSessionStore implements ActiveSessionStore {
  private sessions = new Map<string, ActiveSession>();

  get(sessionId: string): ActiveSession | undefined {
    return this.sessions.get(sessionId);
  }

  set(sessionId: string, session: ActiveSession): void {
    this.sessions.set(sessionId, session);
  }

  delete(sessionId: string): void {
    this.sessions.delete(sessionId);
  }

  clear(): void {
    this.sessions.clear();
  }

  get size(): number {
    return this.sessions.size;
  }

  entries(): IterableIterator<[string, ActiveSession]> {
    return this.sessions.entries();
  }

  values(): IterableIterator<ActiveSession> {
    return this.sessions.values();
  }
}
