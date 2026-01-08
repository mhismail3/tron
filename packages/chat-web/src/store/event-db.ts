/**
 * @fileoverview IndexedDB Event Store for Web Client
 *
 * Local event cache using IndexedDB for:
 * - Offline support (events cached locally)
 * - Fast state reconstruction
 * - Sync with server via RPC
 *
 * Schema matches the EventStore in core package.
 */

// =============================================================================
// Types
// =============================================================================

/**
 * Event stored in IndexedDB
 * Matches TronSessionEvent from core
 */
export interface CachedEvent {
  id: string;
  parentId: string | null;
  sessionId: string;
  workspaceId: string;
  type: string;
  timestamp: string;
  sequence: number;
  payload: Record<string, unknown>;
}

/**
 * Session stored in IndexedDB
 */
export interface CachedSession {
  id: string;
  workspaceId: string;
  rootEventId: string | null;
  headEventId: string | null;
  title: string | null;
  latestModel: string;
  workingDirectory: string;
  createdAt: string;
  lastActivityAt: string;
  endedAt: string | null;
  eventCount: number;
  messageCount: number;
}

/**
 * Helper to check if a session has ended
 */
export function isSessionEnded(session: CachedSession): boolean {
  return session.endedAt !== null;
}

/**
 * Backward compatibility: get model from session
 */
export function getSessionModel(session: CachedSession): string {
  return session.latestModel;
}

/**
 * Sync state for tracking server sync
 */
export interface SyncState {
  key: string;
  lastSyncedEventId: string | null;
  lastSyncTimestamp: string | null;
  pendingEventIds: string[];
}

/**
 * Tree node for visualization
 */
export interface EventTreeNode {
  id: string;
  parentId: string | null;
  type: string;
  timestamp: string;
  summary: string;
  hasChildren: boolean;
  childCount: number;
  depth: number;
  isBranchPoint: boolean;
  isHead: boolean;
}

// =============================================================================
// Database Configuration
// =============================================================================

const DB_NAME = 'tron_events';
const DB_VERSION = 1;

const STORES = {
  events: 'events',
  sessions: 'sessions',
  syncState: 'syncState',
} as const;

// =============================================================================
// IndexedDB Wrapper
// =============================================================================

export class EventDB {
  private db: IDBDatabase | null = null;
  private dbPromise: Promise<IDBDatabase> | null = null;

  /**
   * Initialize the database
   */
  async init(): Promise<void> {
    if (this.db) return;
    if (this.dbPromise) {
      await this.dbPromise;
      return;
    }

    this.dbPromise = new Promise((resolve, reject) => {
      const request = indexedDB.open(DB_NAME, DB_VERSION);

      request.onerror = () => {
        reject(new Error(`Failed to open database: ${request.error?.message}`));
      };

      request.onsuccess = () => {
        this.db = request.result;
        resolve(request.result);
      };

      request.onupgradeneeded = (event) => {
        const db = (event.target as IDBOpenDBRequest).result;
        this.createStores(db);
      };
    });

    await this.dbPromise;
  }

  /**
   * Create object stores during database upgrade
   */
  private createStores(db: IDBDatabase): void {
    // Events store
    if (!db.objectStoreNames.contains(STORES.events)) {
      const eventsStore = db.createObjectStore(STORES.events, { keyPath: 'id' });
      eventsStore.createIndex('sessionId', 'sessionId', { unique: false });
      eventsStore.createIndex('timestamp', 'timestamp', { unique: false });
      eventsStore.createIndex('type', 'type', { unique: false });
      eventsStore.createIndex('parentId', 'parentId', { unique: false });
    }

    // Sessions store
    if (!db.objectStoreNames.contains(STORES.sessions)) {
      const sessionsStore = db.createObjectStore(STORES.sessions, { keyPath: 'id' });
      sessionsStore.createIndex('workspaceId', 'workspaceId', { unique: false });
      sessionsStore.createIndex('lastActivityAt', 'lastActivityAt', { unique: false });
      sessionsStore.createIndex('endedAt', 'endedAt', { unique: false });
    }

    // Sync state store
    if (!db.objectStoreNames.contains(STORES.syncState)) {
      db.createObjectStore(STORES.syncState, { keyPath: 'key' });
    }
  }

  /**
   * Get database instance
   */
  private getDB(): IDBDatabase {
    if (!this.db) {
      throw new Error('Database not initialized. Call init() first.');
    }
    return this.db;
  }

  // ===========================================================================
  // Event Operations
  // ===========================================================================

  /**
   * Add or update an event
   */
  async putEvent(event: CachedEvent): Promise<void> {
    const db = this.getDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORES.events, 'readwrite');
      const store = tx.objectStore(STORES.events);
      const request = store.put(event);

      request.onsuccess = () => resolve();
      request.onerror = () => reject(request.error);
    });
  }

  /**
   * Add or update multiple events
   */
  async putEvents(events: CachedEvent[]): Promise<void> {
    if (events.length === 0) return;

    const db = this.getDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORES.events, 'readwrite');
      const store = tx.objectStore(STORES.events);

      let completed = 0;
      const total = events.length;

      for (const event of events) {
        const request = store.put(event);
        request.onsuccess = () => {
          completed++;
          if (completed === total) resolve();
        };
        request.onerror = () => reject(request.error);
      }

      tx.onerror = () => reject(tx.error);
    });
  }

  /**
   * Get an event by ID
   */
  async getEvent(id: string): Promise<CachedEvent | null> {
    const db = this.getDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORES.events, 'readonly');
      const store = tx.objectStore(STORES.events);
      const request = store.get(id);

      request.onsuccess = () => resolve(request.result ?? null);
      request.onerror = () => reject(request.error);
    });
  }

  /**
   * Get all events for a session
   */
  async getEventsBySession(sessionId: string): Promise<CachedEvent[]> {
    const db = this.getDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORES.events, 'readonly');
      const store = tx.objectStore(STORES.events);
      const index = store.index('sessionId');
      const request = index.getAll(sessionId);

      request.onsuccess = () => resolve(request.result ?? []);
      request.onerror = () => reject(request.error);
    });
  }

  /**
   * Get ancestors of an event (for state reconstruction)
   * Returns events from root to the specified event
   */
  async getAncestors(eventId: string): Promise<CachedEvent[]> {
    const ancestors: CachedEvent[] = [];
    let currentId: string | null = eventId;

    while (currentId) {
      const event = await this.getEvent(currentId);
      if (!event) break;
      ancestors.unshift(event);
      currentId = event.parentId;
    }

    return ancestors;
  }

  /**
   * Get children of an event (for tree navigation)
   */
  async getChildren(eventId: string): Promise<CachedEvent[]> {
    const db = this.getDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORES.events, 'readonly');
      const store = tx.objectStore(STORES.events);
      const index = store.index('parentId');
      const request = index.getAll(eventId);

      request.onsuccess = () => resolve(request.result ?? []);
      request.onerror = () => reject(request.error);
    });
  }

  /**
   * Delete all events for a session
   */
  async deleteEventsBySession(sessionId: string): Promise<void> {
    const events = await this.getEventsBySession(sessionId);
    if (events.length === 0) return;

    const db = this.getDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORES.events, 'readwrite');
      const store = tx.objectStore(STORES.events);

      let completed = 0;
      const total = events.length;

      for (const event of events) {
        const request = store.delete(event.id);
        request.onsuccess = () => {
          completed++;
          if (completed === total) resolve();
        };
        request.onerror = () => reject(request.error);
      }

      tx.onerror = () => reject(tx.error);
    });
  }

  // ===========================================================================
  // Session Operations
  // ===========================================================================

  /**
   * Add or update a session
   */
  async putSession(session: CachedSession): Promise<void> {
    const db = this.getDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORES.sessions, 'readwrite');
      const store = tx.objectStore(STORES.sessions);
      const request = store.put(session);

      request.onsuccess = () => resolve();
      request.onerror = () => reject(request.error);
    });
  }

  /**
   * Get a session by ID
   */
  async getSession(id: string): Promise<CachedSession | null> {
    const db = this.getDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORES.sessions, 'readonly');
      const store = tx.objectStore(STORES.sessions);
      const request = store.get(id);

      request.onsuccess = () => resolve(request.result ?? null);
      request.onerror = () => reject(request.error);
    });
  }

  /**
   * Get all sessions, ordered by last activity
   */
  async getAllSessions(): Promise<CachedSession[]> {
    const db = this.getDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORES.sessions, 'readonly');
      const store = tx.objectStore(STORES.sessions);
      const index = store.index('lastActivityAt');
      const request = index.openCursor(null, 'prev');

      const sessions: CachedSession[] = [];

      request.onsuccess = () => {
        const cursor = request.result;
        if (cursor) {
          sessions.push(cursor.value);
          cursor.continue();
        } else {
          resolve(sessions);
        }
      };

      request.onerror = () => reject(request.error);
    });
  }

  /**
   * Delete a session
   */
  async deleteSession(id: string): Promise<void> {
    const db = this.getDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORES.sessions, 'readwrite');
      const store = tx.objectStore(STORES.sessions);
      const request = store.delete(id);

      request.onsuccess = () => resolve();
      request.onerror = () => reject(request.error);
    });
  }

  // ===========================================================================
  // Sync State Operations
  // ===========================================================================

  /**
   * Get sync state for a session
   */
  async getSyncState(sessionId: string): Promise<SyncState | null> {
    const db = this.getDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORES.syncState, 'readonly');
      const store = tx.objectStore(STORES.syncState);
      const request = store.get(sessionId);

      request.onsuccess = () => resolve(request.result ?? null);
      request.onerror = () => reject(request.error);
    });
  }

  /**
   * Update sync state for a session
   */
  async putSyncState(state: SyncState): Promise<void> {
    const db = this.getDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORES.syncState, 'readwrite');
      const store = tx.objectStore(STORES.syncState);
      const request = store.put(state);

      request.onsuccess = () => resolve();
      request.onerror = () => reject(request.error);
    });
  }

  // ===========================================================================
  // State Reconstruction
  // ===========================================================================

  /**
   * Reconstruct messages at a specific event (for chat display)
   */
  async getMessagesAt(eventId: string): Promise<Array<{ role: string; content: unknown }>> {
    const ancestors = await this.getAncestors(eventId);
    const messages: Array<{ role: string; content: unknown }> = [];

    for (const event of ancestors) {
      if (event.type === 'message.user') {
        messages.push({
          role: 'user',
          content: (event.payload as { content: unknown }).content,
        });
      } else if (event.type === 'message.assistant') {
        messages.push({
          role: 'assistant',
          content: (event.payload as { content: unknown }).content,
        });
      }
    }

    return messages;
  }

  /**
   * Reconstruct full state at session head
   */
  async getStateAtHead(sessionId: string): Promise<{
    messages: Array<{ role: string; content: unknown }>;
    tokenUsage: { inputTokens: number; outputTokens: number };
    turnCount: number;
  }> {
    const session = await this.getSession(sessionId);
    if (!session?.headEventId) {
      return {
        messages: [],
        tokenUsage: { inputTokens: 0, outputTokens: 0 },
        turnCount: 0,
      };
    }

    const ancestors = await this.getAncestors(session.headEventId);
    const messages: Array<{ role: string; content: unknown }> = [];
    let inputTokens = 0;
    let outputTokens = 0;
    let turnCount = 0;

    for (const event of ancestors) {
      if (event.type === 'message.user') {
        const payload = event.payload as {
          content: unknown;
          tokenUsage?: { inputTokens: number; outputTokens: number };
        };
        messages.push({ role: 'user', content: payload.content });
        if (payload.tokenUsage) {
          inputTokens += payload.tokenUsage.inputTokens;
          outputTokens += payload.tokenUsage.outputTokens;
        }
      } else if (event.type === 'message.assistant') {
        const payload = event.payload as {
          content: unknown;
          turn?: number;
          tokenUsage?: { inputTokens: number; outputTokens: number };
        };
        messages.push({ role: 'assistant', content: payload.content });
        if (payload.tokenUsage) {
          inputTokens += payload.tokenUsage.inputTokens;
          outputTokens += payload.tokenUsage.outputTokens;
        }
        if (payload.turn && payload.turn > turnCount) {
          turnCount = payload.turn;
        }
      }
    }

    return {
      messages,
      tokenUsage: { inputTokens, outputTokens },
      turnCount,
    };
  }

  // ===========================================================================
  // Tree Visualization
  // ===========================================================================

  /**
   * Build tree visualization for a session
   */
  async buildTreeVisualization(sessionId: string): Promise<EventTreeNode[]> {
    const events = await this.getEventsBySession(sessionId);
    const session = await this.getSession(sessionId);

    if (events.length === 0) return [];

    // Build parent-child map
    const childrenMap = new Map<string | null, CachedEvent[]>();
    for (const event of events) {
      const siblings = childrenMap.get(event.parentId) ?? [];
      siblings.push(event);
      childrenMap.set(event.parentId, siblings);
    }

    // Build tree nodes with depth-first traversal
    const nodes: EventTreeNode[] = [];
    const headEventId = session?.headEventId;

    const buildNode = (event: CachedEvent, depth: number): void => {
      const children = childrenMap.get(event.id) ?? [];
      const isBranchPoint = children.length > 1;

      nodes.push({
        id: event.id,
        parentId: event.parentId,
        type: event.type,
        timestamp: event.timestamp,
        summary: this.getEventSummary(event),
        hasChildren: children.length > 0,
        childCount: children.length,
        depth,
        isBranchPoint,
        isHead: event.id === headEventId,
      });

      // Process children
      for (const child of children) {
        buildNode(child, depth + 1);
      }
    };

    // Start from root events (parentId === null)
    const roots = childrenMap.get(null) ?? [];
    for (const root of roots) {
      buildNode(root, 0);
    }

    return nodes;
  }

  /**
   * Get human-readable summary for an event
   */
  private getEventSummary(event: CachedEvent): string {
    const payload = event.payload;

    switch (event.type) {
      case 'session.start':
        return 'Session started';
      case 'session.end':
        return 'Session ended';
      case 'session.fork':
        return `Forked: ${(payload as { name?: string }).name ?? 'unnamed'}`;
      case 'message.user':
        const userContent = (payload as { content?: string }).content;
        return typeof userContent === 'string' ? userContent.slice(0, 50) : 'User message';
      case 'message.assistant':
        return 'Assistant response';
      case 'tool.call':
        return `Tool: ${(payload as { name?: string }).name ?? 'unknown'}`;
      case 'tool.result':
        const isError = (payload as { isError?: boolean }).isError;
        return `Tool result (${isError ? 'error' : 'success'})`;
      case 'ledger.update':
        return 'Ledger updated';
      default:
        return event.type;
    }
  }

  // ===========================================================================
  // Utilities
  // ===========================================================================

  /**
   * Clear all data
   */
  async clear(): Promise<void> {
    const db = this.getDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(
        [STORES.events, STORES.sessions, STORES.syncState],
        'readwrite'
      );

      tx.objectStore(STORES.events).clear();
      tx.objectStore(STORES.sessions).clear();
      tx.objectStore(STORES.syncState).clear();

      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
  }

  /**
   * Close the database connection
   */
  close(): void {
    if (this.db) {
      this.db.close();
      this.db = null;
      this.dbPromise = null;
    }
  }
}

// =============================================================================
// Singleton Instance
// =============================================================================

let eventDBInstance: EventDB | null = null;

/**
 * Get the singleton EventDB instance
 */
export function getEventDB(): EventDB {
  if (!eventDBInstance) {
    eventDBInstance = new EventDB();
  }
  return eventDBInstance;
}
