/**
 * @fileoverview Tron Server Entry Point
 *
 * Main entry point for the Tron WebSocket server.
 * Uses event-sourced session management via EventStoreOrchestrator.
 */
import { createLogger, initializeLogTransport, closeLogTransport, flushLogs } from './logging/index.js';
import { resolveTronPath, getTronDataDir } from './settings/index.js';
import type { RpcContext } from './rpc/context-types.js';
import { TronWebSocketServer, type WebSocketServerConfig } from './gateway/websocket.js';
import { EventStoreOrchestrator, type EventStoreOrchestratorConfig } from './orchestrator/persistence/event-store-orchestrator.js';
import { HealthServer, type HealthServerConfig } from './gateway/health.js';
import { ensureTranscriptionSidecar, stopTranscriptionSidecar } from './transcription/index.js';
import { createRpcContext } from './gateway/rpc/index.js';

const logger = createLogger('server');

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
    await ensureTranscriptionSidecar();

    // Resolve paths to canonical ~/.tron directory
    const tronDir = getTronDataDir();
    const eventStoreDbPath = resolveTronPath(this.config.eventStoreDbPath ?? 'db/prod.db', tronDir);

    // Initialize EventStore orchestrator
    const orchestratorConfig: EventStoreOrchestratorConfig = {
      eventStoreDbPath,
      defaultModel: this.config.defaultModel ?? 'claude-sonnet-4-20250514',
      defaultProvider: this.config.defaultProvider ?? 'anthropic',
      maxConcurrentSessions: this.config.maxConcurrentSessions,
    };

    this.orchestrator = new EventStoreOrchestrator(orchestratorConfig);
    await this.orchestrator.initialize();

    // Initialize SQLite log transport for database-backed logging
    // Persist ALL log levels (trace=10 and above) for comprehensive debugging
    const db = this.orchestrator.getEventStore().getDatabase();
    initializeLogTransport(db, {
      minLevel: 10, // trace and above - persist EVERYTHING
      batchSize: 200, // Larger batches for trace/debug volume
      flushIntervalMs: 2000, // Longer interval for non-critical logs
    });
    logger.info('SQLite log transport initialized (all levels)');

    // Create RpcContext from modular adapter factory
    const rpcContext: RpcContext = createRpcContext({
      orchestrator: this.orchestrator,
    });

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
    this.setupEventForwarding();

    this.isRunning = true;

    logger.info('Tron server started', {
      wsPort: this.config.wsPort,
      healthPort: this.config.healthPort,
      host: this.config.host ?? '0.0.0.0',
      eventStoreDb: eventStoreDbPath,
    });
  }

  private setupEventForwarding(): void {
    if (!this.orchestrator || !this.wsServer) return;

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

      // Also broadcast message.deleted events with specific type for iOS
      if (data.event.type === 'message.deleted') {
        const payload = data.event.payload as { targetEventId: string; targetType: string; targetTurn?: number; reason?: string };
        this.wsServer?.broadcastEvent({
          type: 'agent.message_deleted',
          sessionId: data.sessionId,
          timestamp: new Date().toISOString(),
          data: {
            targetEventId: payload.targetEventId,
            targetType: payload.targetType,
            targetTurn: payload.targetTurn,
            reason: payload.reason,
          },
        });
      }
    });

    this.orchestrator.on('context_cleared', (data) => {
      this.wsServer?.broadcastEvent({
        type: 'agent.context_cleared',
        sessionId: data.sessionId,
        timestamp: new Date().toISOString(),
        data: {
          tokensBefore: data.tokensBefore,
          tokensAfter: data.tokensAfter,
        },
      });
    });

    this.orchestrator.on('compaction_completed', (data) => {
      this.wsServer?.broadcastEvent({
        type: 'agent.compaction',
        sessionId: data.sessionId,
        timestamp: new Date().toISOString(),
        data: {
          tokensBefore: data.tokensBefore,
          tokensAfter: data.tokensAfter,
          reason: 'manual',
          summary: data.summary,
        },
      });
    });

    this.orchestrator.on('skill_removed', (data) => {
      this.wsServer?.broadcastEvent({
        type: 'agent.skill_removed',
        sessionId: data.sessionId,
        timestamp: new Date().toISOString(),
        data: {
          skillName: data.skillName,
        },
      });
    });

    // Forward browser frame events for live streaming
    this.orchestrator.on('browser.frame', (data) => {
      this.wsServer?.broadcastEvent({
        type: 'browser.frame',
        sessionId: data.sessionId,
        timestamp: new Date().toISOString(),
        data: {
          sessionId: data.sessionId,
          data: data.data,
          frameId: data.frameId,
          timestamp: data.timestamp,
          metadata: data.metadata,
        },
      });
    });

    // Forward browser closed events
    this.orchestrator.on('browser.closed', (data) => {
      this.wsServer?.broadcastEvent({
        type: 'browser.closed',
        sessionId: data.sessionId,
        timestamp: new Date().toISOString(),
        data: {},
      });
    });

    // Forward todo update events
    this.orchestrator.on('todos_updated', (data) => {
      this.wsServer?.broadcastEvent({
        type: 'agent.todos_updated',
        sessionId: data.sessionId,
        timestamp: new Date().toISOString(),
        data: {
          todos: data.todos,
          restoredCount: data.restoredCount,
        },
      });
    });
  }

  async stop(): Promise<void> {
    if (!this.isRunning) {
      return;
    }

    logger.info('Stopping Tron server...');
    await stopTranscriptionSidecar();

    if (this.healthServer) {
      await this.healthServer.stop();
      this.healthServer = null;
    }

    if (this.wsServer) {
      await this.wsServer.stop();
      this.wsServer = null;
    }

    // Flush and close log transport before shutting down orchestrator
    await flushLogs();
    closeLogTransport();

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

import { getSettings } from './settings/loader.js';
import type { ServerSettings } from './settings/types.js';

/**
 * Get default server settings from global settings.
 * Exported for dependency injection - consumers can pass custom settings.
 */
export function getDefaultServerSettings(): ServerSettings {
  return getSettings().server;
}

// Internal helper - uses the exported getter
function getServerSettings() {
  return getDefaultServerSettings();
}

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

const isMain = process.argv[1]?.endsWith('server.js') || process.argv[1]?.endsWith('server.ts');
if (isMain) {
  main().catch((error) => {
    logger.error('Failed to start server', error);
    process.exit(1);
  });
}
