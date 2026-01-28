/**
 * @fileoverview Type-safe mock factories for EventStore
 *
 * Provides properly typed mocks for EventStore and related types
 * to eliminate unsafe `as any` casts in test files.
 *
 * @example
 * ```typescript
 * import { createMockEventStore, createMockSessionEvent } from '../__fixtures__/mocks/event-store.js';
 *
 * const mockStore = createMockEventStore();
 * vi.mocked(mockStore.getSession).mockResolvedValue(createMockSessionRow());
 * ```
 */

import { vi, type Mock } from 'vitest';
import type { EventStore, CreateSessionOptions, CreateSessionResult, AppendEventOptions, ForkResult } from '../../events/event-store.js';
import type { SessionRow, ListSessionsOptions } from '../../events/sqlite/facade.js';
import type {
  SessionEvent,
  SessionId,
  EventId,
  WorkspaceId,
  EventType,
  Message,
  SessionState,
  SearchResult,
  Workspace,
  MessageWithEventId,
} from '../../events/types.js';

// =============================================================================
// Helper Types
// =============================================================================

/**
 * Options for creating a mock EventStore
 */
export interface MockEventStoreOptions {
  /** Custom database path */
  dbPath?: string;
  /** Whether the store is initialized */
  initialized?: boolean;
  /** Whether to track appended events in an accessible array */
  trackEvents?: boolean;
  /** Override specific methods */
  getSession?: Mock;
  getEvent?: Mock;
  getEventsBySession?: Mock;
  listSessions?: Mock;
  append?: Mock;
  createSession?: Mock;
  // Add more overrides as needed
}

/**
 * Extended EventStore mock with event tracking capabilities
 */
export interface MockEventStoreWithTracking extends EventStore {
  /** Array of all appended events (only available when trackEvents: true) */
  events: Array<{ sessionId: string; type: string; payload: unknown }>;
  /** Clear the tracked events array */
  clearEvents: () => void;
}

/**
 * Options for creating a mock SessionEvent
 */
export interface MockSessionEventOptions {
  id?: EventId;
  parentId?: EventId | null;
  sessionId?: SessionId;
  workspaceId?: WorkspaceId;
  timestamp?: string;
  type?: EventType;
  sequence?: number;
  payload?: Record<string, unknown>;
}

/**
 * Options for creating a mock SessionRow
 */
export interface MockSessionRowOptions {
  id?: SessionId;
  workspaceId?: WorkspaceId;
  workingDirectory?: string;
  latestModel?: string;
  title?: string | null;
  status?: 'active' | 'ended';
  rootEventId?: EventId | null;
  headEventId?: EventId | null;
  eventCount?: number;
  messageCount?: number;
  inputTokens?: number;
  outputTokens?: number;
  lastTurnInputTokens?: number;
  cacheReadTokens?: number;
  cacheCreationTokens?: number;
  cost?: number;
  parentSessionId?: SessionId | null;
  forkFromEventId?: EventId | null;
  createdAt?: string;
  updatedAt?: string;
  endedAt?: string | null;
  spawningSessionId?: SessionId | null;
  spawnType?: 'subsession' | 'tmux' | 'fork' | null;
  spawnTask?: string | null;
  tags?: string[] | null;
}

/**
 * Options for creating a mock CreateSessionResult
 */
export interface MockCreateSessionResultOptions {
  session?: Partial<MockSessionRowOptions>;
  rootEvent?: Partial<MockSessionEventOptions>;
}

// =============================================================================
// ID Generators
// =============================================================================

let idCounter = 0;

function generateId(prefix: string): string {
  idCounter++;
  return `${prefix}_mock_${idCounter}_${Date.now()}`;
}

function generateEventId(): EventId {
  return generateId('evt') as EventId;
}

function generateSessionId(): SessionId {
  return generateId('sess') as SessionId;
}

function generateWorkspaceId(): WorkspaceId {
  return generateId('ws') as WorkspaceId;
}

// =============================================================================
// Mock Factories
// =============================================================================

/**
 * Create a mock SessionEvent with defaults
 */
export function createMockSessionEvent(options: MockSessionEventOptions = {}): SessionEvent {
  const sessionId = options.sessionId ?? generateSessionId();
  const workspaceId = options.workspaceId ?? generateWorkspaceId();

  return {
    id: options.id ?? generateEventId(),
    parentId: options.parentId ?? null,
    sessionId,
    workspaceId,
    timestamp: options.timestamp ?? new Date().toISOString(),
    type: options.type ?? 'message.user',
    sequence: options.sequence ?? 0,
    payload: options.payload ?? { content: 'mock content' },
  } as SessionEvent;
}

/**
 * Create a mock SessionRow with defaults
 */
export function createMockSessionRow(options: MockSessionRowOptions = {}): SessionRow {
  const now = new Date().toISOString();
  const id = options.id ?? generateSessionId();
  const workspaceId = options.workspaceId ?? generateWorkspaceId();

  return {
    id,
    workspaceId,
    workingDirectory: options.workingDirectory ?? '/mock/working/directory',
    latestModel: options.latestModel ?? 'claude-sonnet-4-20250514',
    title: options.title ?? null,
    status: options.status ?? 'active',
    rootEventId: options.rootEventId ?? null,
    headEventId: options.headEventId ?? null,
    eventCount: options.eventCount ?? 0,
    messageCount: options.messageCount ?? 0,
    inputTokens: options.inputTokens ?? 0,
    outputTokens: options.outputTokens ?? 0,
    lastTurnInputTokens: options.lastTurnInputTokens ?? 0,
    cacheReadTokens: options.cacheReadTokens ?? 0,
    cacheCreationTokens: options.cacheCreationTokens ?? 0,
    cost: options.cost ?? 0,
    parentSessionId: options.parentSessionId ?? null,
    forkFromEventId: options.forkFromEventId ?? null,
    createdAt: options.createdAt ?? now,
    updatedAt: options.updatedAt ?? now,
    endedAt: options.endedAt ?? null,
    spawningSessionId: options.spawningSessionId ?? null,
    spawnType: options.spawnType ?? null,
    spawnTask: options.spawnTask ?? null,
    tags: options.tags ?? null,
  };
}

/**
 * Create a mock CreateSessionResult
 */
export function createMockCreateSessionResult(options: MockCreateSessionResultOptions = {}): CreateSessionResult {
  const sessionId = (options.session?.id ?? generateSessionId()) as SessionId;
  const workspaceId = (options.session?.workspaceId ?? generateWorkspaceId()) as WorkspaceId;
  const rootEventId = (options.rootEvent?.id ?? generateEventId()) as EventId;

  const session = createMockSessionRow({
    id: sessionId,
    workspaceId,
    rootEventId,
    headEventId: rootEventId,
    eventCount: 1,
    ...options.session,
  });

  const rootEvent = createMockSessionEvent({
    id: rootEventId,
    sessionId,
    workspaceId,
    type: 'session.start',
    sequence: 0,
    payload: {
      workingDirectory: session.workingDirectory,
      model: session.latestModel,
    },
    ...options.rootEvent,
  });

  return { session, rootEvent };
}

/**
 * Create a mock ForkResult
 */
export function createMockForkResult(options: {
  session?: Partial<MockSessionRowOptions>;
  rootEvent?: Partial<MockSessionEventOptions>;
  sourceSessionId?: SessionId;
  sourceEventId?: EventId;
} = {}): ForkResult {
  const sessionId = (options.session?.id ?? generateSessionId()) as SessionId;
  const workspaceId = (options.session?.workspaceId ?? generateWorkspaceId()) as WorkspaceId;
  const forkEventId = (options.rootEvent?.id ?? generateEventId()) as EventId;
  const sourceEventId = options.sourceEventId ?? generateEventId();
  const sourceSessionId = options.sourceSessionId ?? generateSessionId();

  const session = createMockSessionRow({
    id: sessionId,
    workspaceId,
    rootEventId: forkEventId,
    headEventId: forkEventId,
    eventCount: 1,
    parentSessionId: sourceSessionId,
    forkFromEventId: sourceEventId,
    ...options.session,
  });

  const rootEvent = createMockSessionEvent({
    id: forkEventId,
    parentId: sourceEventId,
    sessionId,
    workspaceId,
    type: 'session.fork',
    sequence: 0,
    payload: {
      sourceSessionId,
      sourceEventId,
    },
    ...options.rootEvent,
  });

  return { session, rootEvent };
}

/**
 * Create a properly typed mock EventStore
 *
 * Returns a mock that implements all EventStore methods with sensible defaults.
 * All methods are vitest mock functions that can be overridden or spied on.
 *
 * When `trackEvents: true` is passed, the returned mock includes an `events` array
 * that tracks all appended events for test assertions.
 *
 * @example
 * ```typescript
 * const mockStore = createMockEventStore();
 *
 * // Use with createWorktreeCoordinator without `as any`
 * const coordinator = createWorktreeCoordinator(mockStore, config);
 *
 * // Override specific behavior
 * vi.mocked(mockStore.getSession).mockResolvedValue(createMockSessionRow());
 * ```
 *
 * @example
 * ```typescript
 * // With event tracking enabled
 * const mockStore = createMockEventStore({ trackEvents: true });
 * await someOperation();
 *
 * // Access tracked events
 * const acquiredEvent = mockStore.events.find(e => e.type === 'worktree.acquired');
 * expect(acquiredEvent).toBeDefined();
 * ```
 */
export function createMockEventStore(options: MockEventStoreOptions & { trackEvents: true }): MockEventStoreWithTracking;
export function createMockEventStore(options?: MockEventStoreOptions): EventStore;
export function createMockEventStore(options: MockEventStoreOptions = {}): EventStore | MockEventStoreWithTracking {
  const dbPath = options.dbPath ?? ':memory:';
  let initialized = options.initialized ?? true;
  const trackEvents = options.trackEvents ?? false;

  // Event tracking array
  const trackedEvents: Array<{ sessionId: string; type: string; payload: unknown }> = [];

  // Create a counter for sequence numbers
  let sequenceCounter = 0;

  // Default append implementation that returns a valid event
  const defaultAppend = vi.fn().mockImplementation(async (opts: AppendEventOptions) => {
    sequenceCounter++;
    const event = createMockSessionEvent({
      sessionId: opts.sessionId,
      parentId: opts.parentId ?? null,
      type: opts.type,
      sequence: sequenceCounter,
      payload: opts.payload,
    });

    // Track the event if tracking is enabled
    if (trackEvents) {
      trackedEvents.push({
        sessionId: opts.sessionId,
        type: opts.type,
        payload: opts.payload,
      });
    }

    return event;
  });

  // Default createSession implementation
  const defaultCreateSession = vi.fn().mockImplementation(async (opts: CreateSessionOptions) => {
    return createMockCreateSessionResult({
      session: {
        workingDirectory: opts.workingDirectory,
        latestModel: opts.model,
        title: opts.title ?? null,
        tags: opts.tags ?? null,
      },
    });
  });

  // Create the mock object with all methods
  const mockStore: EventStore = {
    // Lifecycle
    initialize: vi.fn().mockImplementation(async () => {
      initialized = true;
    }),
    close: vi.fn().mockResolvedValue(undefined),
    isInitialized: vi.fn().mockImplementation(() => initialized),
    getDatabase: vi.fn().mockReturnValue({
      // Return a minimal database mock - just enough for basic operations
      prepare: vi.fn().mockReturnValue({
        run: vi.fn(),
        get: vi.fn(),
        all: vi.fn().mockReturnValue([]),
      }),
    }),

    // Session Creation
    createSession: options.createSession ?? defaultCreateSession,

    // Event Appending
    append: options.append ?? defaultAppend,

    // Event Retrieval
    getEvent: options.getEvent ?? vi.fn().mockResolvedValue(null),
    getEventsBySession: options.getEventsBySession ?? vi.fn().mockResolvedValue([]),
    getAncestors: vi.fn().mockResolvedValue([]),
    getChildren: vi.fn().mockResolvedValue([]),

    // State Projection
    getMessagesAtHead: vi.fn().mockResolvedValue([]),
    getMessagesAt: vi.fn().mockResolvedValue([]),
    getStateAtHead: vi.fn().mockImplementation(async (sessionId: SessionId) => {
      return {
        sessionId,
        workspaceId: generateWorkspaceId(),
        headEventId: generateEventId(),
        messagesWithEventIds: [] as MessageWithEventId[],
        tokenUsage: { inputTokens: 0, outputTokens: 0 },
        turnCount: 0,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/mock',
      } as SessionState;
    }),
    getStateAt: vi.fn().mockImplementation(async (eventId: EventId) => {
      return {
        sessionId: generateSessionId(),
        workspaceId: generateWorkspaceId(),
        headEventId: eventId,
        messagesWithEventIds: [] as MessageWithEventId[],
        tokenUsage: { inputTokens: 0, outputTokens: 0 },
        turnCount: 0,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/mock',
      } as SessionState;
    }),

    // Fork Operation
    fork: vi.fn().mockImplementation(async (fromEventId: EventId) => {
      return createMockForkResult({ sourceEventId: fromEventId });
    }),

    // Search
    search: vi.fn().mockResolvedValue([]),

    // Session Management
    getSession: options.getSession ?? vi.fn().mockResolvedValue(null),
    getSessionsByIds: vi.fn().mockResolvedValue(new Map()),
    listSessions: options.listSessions ?? vi.fn().mockResolvedValue([]),
    getSessionMessagePreviews: vi.fn().mockResolvedValue(new Map()),
    endSession: vi.fn().mockResolvedValue(undefined),
    clearSessionEnded: vi.fn().mockResolvedValue(undefined),
    updateLatestModel: vi.fn().mockResolvedValue(undefined),

    // Message Deletion
    deleteMessage: vi.fn().mockImplementation(async (sessionId: SessionId, targetEventId: EventId) => {
      return createMockSessionEvent({
        sessionId,
        type: 'message.deleted',
        payload: { targetEventId, targetType: 'message.user', reason: 'user_request' },
      });
    }),

    // Workspace
    getWorkspaceByPath: vi.fn().mockResolvedValue(null),

    // Database Path
    getDbPath: vi.fn().mockReturnValue(dbPath),

    // Subagent Support
    updateSessionSpawnInfo: vi.fn().mockResolvedValue(undefined),
    getLogsForSession: vi.fn().mockResolvedValue([]),
  };

  // Add event tracking if enabled
  if (trackEvents) {
    return Object.assign(mockStore, {
      events: trackedEvents,
      clearEvents: () => {
        trackedEvents.length = 0;
      },
    }) as MockEventStoreWithTracking;
  }

  return mockStore;
}

/**
 * Create a mock Message for testing
 */
export function createMockMessage(options: {
  role?: 'user' | 'assistant';
  content?: string | Array<{ type: string; text?: string }>;
} = {}): Message {
  const role = options.role ?? 'user';
  const content = options.content ?? 'Mock message content';

  return {
    role,
    content: typeof content === 'string'
      ? [{ type: 'text', text: content }]
      : content,
  } as Message;
}

/**
 * Create a mock MessageWithEventId for testing
 */
export function createMockMessageWithEventId(options: {
  eventId?: EventId;
  message?: Partial<Parameters<typeof createMockMessage>[0]>;
} = {}): MessageWithEventId {
  return {
    eventId: options.eventId ?? generateEventId(),
    message: createMockMessage(options.message),
  };
}
