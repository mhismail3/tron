/**
 * @fileoverview Tron Server Entry Point
 *
 * Main entry point for the Tron WebSocket server.
 * Uses event-sourced session management via EventStoreOrchestrator.
 */
import { createLogger, getSettings, resolveTronPath, getTronDataDir, type RpcContext, type EventStoreManager, type WorktreeRpcManager } from '@tron/core';
import { TronWebSocketServer, type WebSocketServerConfig } from './websocket.js';
import { EventStoreOrchestrator, type EventStoreOrchestratorConfig } from './event-store-orchestrator.js';
import { HealthServer, type HealthServerConfig } from './health.js';

// Get server settings (loaded lazily on first access)
function getServerSettings() {
  return getSettings().server;
}

const logger = createLogger('server');

// =============================================================================
// RpcContext Adapter
// =============================================================================

/**
 * Creates an RpcContext adapter from EventStoreOrchestrator
 */
function createRpcContext(orchestrator: EventStoreOrchestrator): RpcContext {
  return {
    sessionManager: {
      async createSession(params) {
        const session = await orchestrator.createSession({
          workingDirectory: params.workingDirectory,
          model: params.model,
        });
        return {
          sessionId: session.sessionId,
          model: session.model,
          createdAt: session.createdAt,
        };
      },
      async getSession(sessionId) {
        const session = await orchestrator.getSession(sessionId);
        if (!session) return null;

        // Get messages from event store
        const messages = await orchestrator.getSessionMessages(sessionId);

        return {
          sessionId: session.sessionId,
          workingDirectory: session.workingDirectory,
          model: session.model,
          messageCount: session.messageCount,
          createdAt: session.createdAt,
          lastActivity: session.lastActivity,
          isActive: session.isActive,
          messages: messages.map(m => ({
            role: m.role,
            content: m.content,
          })),
        };
      },
      async resumeSession(sessionId) {
        // Resume the session - this activates it in the orchestrator
        const session = await orchestrator.resumeSession(sessionId);

        // Get messages from event store
        const messages = await orchestrator.getSessionMessages(sessionId);

        return {
          sessionId: session.sessionId,
          workingDirectory: session.workingDirectory,
          model: session.model,
          messageCount: session.messageCount,
          createdAt: session.createdAt,
          lastActivity: session.lastActivity,
          isActive: session.isActive,
          messages: messages.map(m => ({
            role: m.role,
            content: m.content,
          })),
        };
      },
      async listSessions(params) {
        const sessions = await orchestrator.listSessions({
          workingDirectory: params.workingDirectory,
          limit: params.limit,
        });
        return sessions.map(s => ({
          sessionId: s.sessionId,
          workingDirectory: s.workingDirectory,
          model: s.model,
          messageCount: s.messageCount,
          createdAt: s.createdAt,
          lastActivity: s.lastActivity,
          isActive: s.isActive,
          messages: [],
        }));
      },
      async deleteSession(sessionId) {
        await orchestrator.endSession(sessionId);
        return true;
      },
      async forkSession(sessionId, fromEventId) {
        const result = await orchestrator.forkSession(sessionId, fromEventId);
        return {
          newSessionId: result.newSessionId,
          rootEventId: result.rootEventId,
          forkedFromEventId: result.forkedFromEventId,
          forkedFromSessionId: result.forkedFromSessionId,
        };
      },
      async rewindSession(sessionId, toEventId) {
        const result = await orchestrator.rewindSession(sessionId, toEventId);
        return {
          sessionId: result.sessionId,
          newHeadEventId: result.newHeadEventId,
          previousHeadEventId: result.previousHeadEventId,
        };
      },
      async switchModel(sessionId, model) {
        return orchestrator.switchModel(sessionId, model);
      },
    },
    agentManager: {
      async prompt(params) {
        // Start the agent run asynchronously - response will be streamed via events
        orchestrator.runAgent({
          sessionId: params.sessionId,
          prompt: params.prompt,
        }).catch(err => {
          console.error('Agent run error:', err);
        });
        // Return acknowledgement immediately
        return { acknowledged: true };
      },
      async abort(sessionId) {
        const cancelled = await orchestrator.cancelAgent(sessionId);
        return { aborted: cancelled };
      },
      async getState(sessionId) {
        const active = orchestrator.getActiveSession(sessionId);
        const session = await orchestrator.getSession(sessionId);
        // Get ACTUAL agent message count (not just DB count) for debugging
        const agentState = active?.agent.getState();

        // Check if session was interrupted (from active session flag or from persisted events)
        let wasInterrupted = active?.wasInterrupted ?? false;
        if (!wasInterrupted && session) {
          // Check if the last assistant message was interrupted
          wasInterrupted = await orchestrator.wasSessionInterrupted(sessionId);
        }

        return {
          isRunning: active?.isProcessing ?? false,
          currentTurn: agentState?.currentTurn ?? 0,
          messageCount: agentState?.messages.length ?? session?.messageCount ?? 0,
          tokenUsage: {
            input: agentState?.tokenUsage?.inputTokens ?? 0,
            output: agentState?.tokenUsage?.outputTokens ?? 0,
          },
          model: session?.model ?? 'unknown',
          tools: [],
          // Include current turn content for resume support (only when agent is running)
          currentTurnText: active?.isProcessing ? active.currentTurnAccumulatedText : undefined,
          currentTurnToolCalls: active?.isProcessing ? active.currentTurnToolCalls : undefined,
          // Flag indicating session was interrupted
          wasInterrupted,
        };
      },
    },
    // Memory operations are deprecated - use event store search instead
    memoryStore: {
      async searchEntries(_params) {
        return { entries: [], totalCount: 0 };
      },
      async addEntry(_params) {
        return { id: '' };
      },
      async listHandoffs(_workingDirectory, _limit) {
        return [];
      },
    },
  };
}

/**
 * Creates an EventStoreManager adapter from EventStoreOrchestrator
 */
function createEventStoreManager(orchestrator: EventStoreOrchestrator): EventStoreManager {
  const eventStore = orchestrator.getEventStore();

  return {
    async getEventHistory(sessionId, options) {
      const events = await orchestrator.getSessionEvents(sessionId);

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
        ? await orchestrator.getSessionEvents(options.sessionId)
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
      const event = await orchestrator.appendEvent({
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

      const events = await orchestrator.getSessionEvents(sessionId);

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
      const events = await orchestrator.getSessionEvents(sessionId);
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
        const ancestors = await orchestrator.getAncestors(eventId);
        return { nodes: ancestors };
      }

      const descendants = await getDescendantsRecursive(eventId, eventStore);
      return { nodes: descendants };
    },

    async getAncestors(eventId) {
      const ancestors = await orchestrator.getAncestors(eventId);
      return { events: ancestors };
    },

    async searchContent(query, options) {
      const results = await orchestrator.searchEvents(query, {
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
  };
}

/**
 * Creates a WorktreeRpcManager adapter from EventStoreOrchestrator
 */
function createWorktreeManager(orchestrator: EventStoreOrchestrator): WorktreeRpcManager {
  return {
    async getWorktreeStatus(sessionId) {
      return orchestrator.getWorktreeStatus(sessionId);
    },
    async commitWorktree(sessionId, message) {
      return orchestrator.commitWorktree(sessionId, message);
    },
    async mergeWorktree(sessionId, targetBranch, strategy) {
      return orchestrator.mergeWorktree(sessionId, targetBranch, strategy);
    },
    async listWorktrees() {
      return orchestrator.listWorktrees();
    },
  };
}

// Helper functions for tree visualization
function getDescendantCount(eventId: string, allEvents: any[]): number {
  const children = allEvents.filter(e => e.parentId === eventId);
  return children.length + children.reduce((sum, child) =>
    sum + getDescendantCount(child.id, allEvents), 0);
}

async function getDescendantsRecursive(eventId: string, eventStore: any): Promise<any[]> {
  const children = await eventStore.getChildren(eventId);
  const descendants = [...children];
  for (const child of children) {
    const childDescendants = await getDescendantsRecursive(child.id, eventStore);
    descendants.push(...childDescendants);
  }
  return descendants;
}

function getEventSummary(event: any): string {
  switch (event.type) {
    case 'session.start':
      return 'Session started';
    case 'session.end':
      return 'Session ended';
    case 'session.fork':
      return `Forked: ${event.payload?.name ?? 'unnamed'}`;
    case 'message.user':
      return event.payload?.content ? String(event.payload.content).slice(0, 50) : 'User message';
    case 'message.assistant':
      return 'Assistant response';
    case 'tool.call':
      return `Tool: ${event.payload?.name ?? 'unknown'}`;
    case 'tool.result':
      return `Tool result (${event.payload?.isError ? 'error' : 'success'})`;
    default:
      return event.type;
  }
}

function getEventDepth(event: any, allEvents: any[]): number {
  let depth = 0;
  let current = event;
  while (current?.parentId) {
    depth++;
    current = allEvents.find(e => e.id === current.parentId);
  }
  return depth;
}

// =============================================================================
// Types
// =============================================================================

export interface TronServerConfig {
  /** WebSocket port */
  wsPort: number;
  /** Health check port */
  healthPort: number;
  /** Host to bind to */
  host?: string;
  /** Event store database path */
  eventStoreDbPath?: string;
  /** Default model */
  defaultModel?: string;
  /** Default provider */
  defaultProvider?: string;
  /** Max concurrent sessions */
  maxConcurrentSessions?: number;
  /** Heartbeat interval in ms */
  heartbeatInterval?: number;
}

// =============================================================================
// Server
// =============================================================================

export class TronServer {
  private config: TronServerConfig;
  private orchestrator: EventStoreOrchestrator | null = null;
  private wsServer: TronWebSocketServer | null = null;
  private healthServer: HealthServer | null = null;
  private isRunning = false;

  constructor(config: TronServerConfig) {
    this.config = config;
  }

  async start(): Promise<void> {
    if (this.isRunning) {
      throw new Error('Server is already running');
    }

    logger.info('Starting Tron server...');

    // Resolve paths to canonical ~/.tron directory
    const tronDir = getTronDataDir();
    const eventStoreDbPath = resolveTronPath(this.config.eventStoreDbPath ?? 'events.db', tronDir);

    // Initialize EventStore orchestrator
    const orchestratorConfig: EventStoreOrchestratorConfig = {
      eventStoreDbPath,
      defaultModel: this.config.defaultModel ?? 'claude-sonnet-4-20250514',
      defaultProvider: this.config.defaultProvider ?? 'anthropic',
      maxConcurrentSessions: this.config.maxConcurrentSessions,
    };

    this.orchestrator = new EventStoreOrchestrator(orchestratorConfig);
    await this.orchestrator.initialize();

    // Create RpcContext adapter
    const rpcContext: RpcContext = {
      ...createRpcContext(this.orchestrator),
      eventStore: createEventStoreManager(this.orchestrator),
      worktreeManager: createWorktreeManager(this.orchestrator),
    };

    // Initialize WebSocket server
    const wsConfig: WebSocketServerConfig = {
      port: this.config.wsPort,
      host: this.config.host,
      heartbeatInterval: this.config.heartbeatInterval,
    };

    this.wsServer = new TronWebSocketServer(wsConfig, rpcContext);
    await this.wsServer.start();

    // Initialize health server
    const healthConfig: HealthServerConfig = {
      port: this.config.healthPort,
      host: this.config.host,
    };

    this.healthServer = new HealthServer(healthConfig);
    this.healthServer.setEventStoreOrchestrator(this.orchestrator);
    this.healthServer.setWsClientCount(() => this.wsServer?.getClientCount() ?? 0);
    await this.healthServer.start();

    // Forward orchestrator events to WebSocket clients
    this.orchestrator.on('session_created', (data) => {
      this.wsServer?.broadcastEvent({
        type: 'session.created',
        timestamp: new Date().toISOString(),
        data,
      });
    });

    this.orchestrator.on('session_ended', (data) => {
      this.wsServer?.broadcastEvent({
        type: 'session.ended',
        timestamp: new Date().toISOString(),
        data,
      });
    });

    this.orchestrator.on('session_forked', (data) => {
      this.wsServer?.broadcastEvent({
        type: 'session.forked',
        timestamp: new Date().toISOString(),
        data,
      });
    });

    this.orchestrator.on('session_rewound', (data) => {
      this.wsServer?.broadcastEvent({
        type: 'session.rewound',
        timestamp: new Date().toISOString(),
        data,
      });
    });

    this.orchestrator.on('agent_turn', (event) => {
      this.wsServer?.broadcastEvent({
        type: 'agent.turn',
        sessionId: event.sessionId,
        timestamp: event.timestamp,
        data: event.data,
      });
    });

    this.orchestrator.on('agent_event', (event) => {
      this.wsServer?.broadcastEvent({
        type: event.type,
        sessionId: event.sessionId,
        timestamp: event.timestamp,
        data: event.data,
      });
    });

    this.orchestrator.on('event_new', (data) => {
      this.wsServer?.broadcastEvent({
        type: 'event.new',
        sessionId: data.sessionId,
        timestamp: new Date().toISOString(),
        data: { event: data.event },
      });
    });

    this.isRunning = true;

    logger.info('Tron server started', {
      wsPort: this.config.wsPort,
      healthPort: this.config.healthPort,
      host: this.config.host ?? '0.0.0.0',
      eventStoreDb: eventStoreDbPath,
    });
  }

  async stop(): Promise<void> {
    if (!this.isRunning) {
      return;
    }

    logger.info('Stopping Tron server...');

    if (this.healthServer) {
      await this.healthServer.stop();
      this.healthServer = null;
    }

    if (this.wsServer) {
      await this.wsServer.stop();
      this.wsServer = null;
    }

    if (this.orchestrator) {
      await this.orchestrator.shutdown();
      this.orchestrator = null;
    }

    this.isRunning = false;
    logger.info('Tron server stopped');
  }

  getIsRunning(): boolean {
    return this.isRunning;
  }

  getOrchestrator(): EventStoreOrchestrator | null {
    return this.orchestrator;
  }
}

// =============================================================================
// CLI Entry Point
// =============================================================================

async function main(): Promise<void> {
  const settings = getServerSettings();

  const config: TronServerConfig = {
    wsPort: parseInt(process.env.TRON_WS_PORT ?? String(settings.wsPort), 10),
    healthPort: parseInt(process.env.TRON_HEALTH_PORT ?? String(settings.healthPort), 10),
    host: process.env.TRON_HOST ?? settings.host,
    eventStoreDbPath: process.env.TRON_EVENT_STORE_DB,
    defaultModel: process.env.TRON_DEFAULT_MODEL ?? settings.defaultModel,
    defaultProvider: process.env.TRON_DEFAULT_PROVIDER ?? settings.defaultProvider,
    maxConcurrentSessions: process.env.TRON_MAX_SESSIONS
      ? parseInt(process.env.TRON_MAX_SESSIONS, 10)
      : settings.maxConcurrentSessions,
    heartbeatInterval: process.env.TRON_HEARTBEAT_INTERVAL
      ? parseInt(process.env.TRON_HEARTBEAT_INTERVAL, 10)
      : settings.heartbeatIntervalMs,
  };

  const server = new TronServer(config);

  const shutdown = async (signal: string) => {
    logger.info(`Received ${signal}, shutting down...`);
    await server.stop();
    process.exit(0);
  };

  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));

  process.on('uncaughtException', (error) => {
    logger.error('Uncaught exception', error);
    process.exit(1);
  });

  process.on('unhandledRejection', (reason) => {
    logger.error('Unhandled rejection', { reason });
    process.exit(1);
  });

  await server.start();

  logger.info('Server ready. Press Ctrl+C to stop.');
}

const isMain = process.argv[1]?.endsWith('index.js') || process.argv[1]?.endsWith('index.ts');
if (isMain) {
  main().catch((error) => {
    logger.error('Failed to start server', error);
    process.exit(1);
  });
}

// =============================================================================
// Exports
// =============================================================================

export { TronWebSocketServer } from './websocket.js';
export type { WebSocketServerConfig, ClientConnection } from './websocket.js';
export { EventStoreOrchestrator } from './event-store-orchestrator.js';
export type {
  EventStoreOrchestratorConfig,
  ActiveSession,
  AgentRunOptions,
  AgentEvent,
  CreateSessionOptions,
  SessionInfo,
  ForkResult,
  RewindResult,
} from './event-store-orchestrator.js';
export { HealthServer } from './health.js';
export type { HealthServerConfig, HealthResponse } from './health.js';
