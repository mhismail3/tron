/**
 * @fileoverview Tron Server Entry Point
 *
 * Main entry point for the Tron WebSocket server.
 * Uses event-sourced session management via EventStoreOrchestrator.
 */
import { createLogger, getSettings, resolveTronPath, getTronDataDir, initializeLogTransport, closeLogTransport, flushLogs, type RpcContext } from '@tron/core';
import { TronWebSocketServer, type WebSocketServerConfig } from './websocket.js';
import { EventStoreOrchestrator, type EventStoreOrchestratorConfig } from './event-store-orchestrator.js';
import { HealthServer, type HealthServerConfig } from './health.js';
import { ensureTranscriptionSidecar, stopTranscriptionSidecar } from './transcription-sidecar.js';
import { createRpcContext } from './rpc/index.js';

// Get server settings (loaded lazily on first access)
function getServerSettings() {
  return getSettings().server;
}

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

    // Initialize SQLite log transport for database-backed logging
    // This enables queryable log history in the same events.db
    // Settings optimized for reliability:
    // - minLevel 30 (info+) to avoid verbose debug logs
    // - batchSize 50, flushInterval 500ms for quick persistence
    // - warn/error/fatal flush immediately (built into transport)
    const db = this.orchestrator.getEventStore().getDatabase();
    initializeLogTransport(db, {
      minLevel: 30, // info and above
    });
    logger.info('SQLite log transport initialized');

    // Create RpcContext from modular adapter factory
    // All adapters are composed in ./rpc/context-factory.ts
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
} from './event-store-orchestrator.js';
export { HealthServer } from './health.js';
export type { HealthServerConfig, HealthResponse } from './health.js';
