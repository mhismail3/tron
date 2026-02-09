/**
 * @fileoverview Tron Server Entry Point
 *
 * Main entry point for the Tron WebSocket server.
 * Uses event-sourced session management via EventStoreOrchestrator.
 */
import { createLogger, initializeLogTransport, closeLogTransport, flushLogs, LOG_LEVEL_NUM } from '@infrastructure/logging/index.js';
import { resolveTronPath, getTronDataDir } from '@infrastructure/settings/index.js';
import { DEFAULT_SERVER_MODEL } from '@llm/providers/model-ids.js';
import type { RpcContext } from './rpc/context-types.js';
import { TronWebSocketServer, type WebSocketServerConfig } from './gateway/websocket.js';
import { EventStoreOrchestrator, type EventStoreOrchestratorConfig } from '@runtime/orchestrator/persistence/event-store-orchestrator.js';
import { HealthServer, type HealthServerConfig } from './gateway/health.js';
import { ensureTranscriptionSidecar, stopTranscriptionSidecar } from '@platform/transcription/index.js';
import { createRpcContext } from './gateway/rpc/index.js';
import { createEventEnvelope, BroadcastEventType } from './events/index.js';

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
    const eventStoreDbPath = resolveTronPath(this.config.eventStoreDbPath ?? 'database/prod.db', tronDir);

    // Initialize EventStore orchestrator
    const orchestratorConfig: EventStoreOrchestratorConfig = {
      eventStoreDbPath,
      defaultModel: this.config.defaultModel ?? DEFAULT_SERVER_MODEL,
      defaultProvider: this.config.defaultProvider ?? 'anthropic',
      maxConcurrentSessions: this.config.maxConcurrentSessions,
    };

    this.orchestrator = new EventStoreOrchestrator(orchestratorConfig);
    await this.orchestrator.initialize();

    // Initialize SQLite log transport for database-backed logging
    const db = this.orchestrator.getEventStore().getDatabase();
    const dbLogLevel = getSettings().logging.dbLogLevel;
    const minLevel = LOG_LEVEL_NUM[dbLogLevel];
    initializeLogTransport(db, {
      minLevel,
      batchSize: 200,
      flushIntervalMs: 2000,
    });
    logger.info(`SQLite log transport initialized (minLevel: ${dbLogLevel}/${minLevel})`);

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
      this.wsServer?.broadcastEvent(createEventEnvelope(BroadcastEventType.SESSION_CREATED, data as Record<string, unknown>));
    });

    this.orchestrator.on('session_ended', (data) => {
      this.wsServer?.broadcastEvent(createEventEnvelope(BroadcastEventType.SESSION_ENDED, data as Record<string, unknown>));
    });

    this.orchestrator.on('session_forked', (data) => {
      this.wsServer?.broadcastEvent(createEventEnvelope(BroadcastEventType.SESSION_FORKED, data as Record<string, unknown>));
    });

    this.orchestrator.on('session_rewound', (data) => {
      this.wsServer?.broadcastEvent(createEventEnvelope(BroadcastEventType.SESSION_REWOUND, data as Record<string, unknown>));
    });

    this.orchestrator.on('agent_turn', (event) => {
      this.wsServer?.broadcastEvent(createEventEnvelope(
        BroadcastEventType.AGENT_TURN,
        { ...event.data, timestamp: event.timestamp } as Record<string, unknown>,
        event.sessionId
      ));
    });

    this.orchestrator.on('agent_event', (event) => {
      this.wsServer?.broadcastEvent(createEventEnvelope(
        event.type,
        { ...event.data, timestamp: event.timestamp } as Record<string, unknown>,
        event.sessionId
      ));
    });

    this.orchestrator.on('event_new', (data) => {
      this.wsServer?.broadcastEvent(createEventEnvelope(
        BroadcastEventType.EVENT_NEW,
        { event: data.event },
        data.sessionId
      ));

      // Also broadcast message.deleted events with specific type for iOS
      if (data.event.type === 'message.deleted') {
        const payload = data.event.payload as { targetEventId: string; targetType: string; targetTurn?: number; reason?: string };
        this.wsServer?.broadcastEvent(createEventEnvelope(
          BroadcastEventType.AGENT_MESSAGE_DELETED,
          {
            targetEventId: payload.targetEventId,
            targetType: payload.targetType,
            targetTurn: payload.targetTurn,
            reason: payload.reason,
          },
          data.sessionId
        ));
      }
    });

    this.orchestrator.on('context_cleared', (data) => {
      this.wsServer?.broadcastEvent(createEventEnvelope(
        BroadcastEventType.AGENT_CONTEXT_CLEARED,
        {
          tokensBefore: data.tokensBefore,
          tokensAfter: data.tokensAfter,
        },
        data.sessionId
      ));
    });

    this.orchestrator.on('compaction_completed', (data) => {
      this.wsServer?.broadcastEvent(createEventEnvelope(
        BroadcastEventType.AGENT_COMPACTION,
        {
          tokensBefore: data.tokensBefore,
          tokensAfter: data.tokensAfter,
          reason: 'manual',
          summary: data.summary,
        },
        data.sessionId
      ));
    });

    this.orchestrator.on('skill_removed', (data) => {
      this.wsServer?.broadcastEvent(createEventEnvelope(
        BroadcastEventType.AGENT_SKILL_REMOVED,
        { skillName: data.skillName },
        data.sessionId
      ));
    });

    this.orchestrator.on('memory_updated', (data) => {
      this.wsServer?.broadcastEvent(createEventEnvelope(
        BroadcastEventType.AGENT_MEMORY_UPDATED,
        { title: data.title, entryType: data.entryType },
        data.sessionId
      ));
    });

    // Forward browser frame events for live streaming
    this.orchestrator.on('browser.frame', (data) => {
      this.wsServer?.broadcastEvent(createEventEnvelope(
        BroadcastEventType.BROWSER_FRAME,
        {
          sessionId: data.sessionId,
          data: data.data,
          frameId: data.frameId,
          timestamp: data.timestamp,
          metadata: data.metadata,
        },
        data.sessionId
      ));
    });

    // Forward browser closed events
    this.orchestrator.on('browser.closed', (data) => {
      this.wsServer?.broadcastEvent(createEventEnvelope(BroadcastEventType.BROWSER_CLOSED, {}, data.sessionId));
    });

    // Forward todo update events
    this.orchestrator.on('todos_updated', (data) => {
      this.wsServer?.broadcastEvent(createEventEnvelope(
        BroadcastEventType.AGENT_TODOS_UPDATED,
        {
          todos: data.todos,
          restoredCount: data.restoredCount,
        },
        data.sessionId
      ));
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

import { getSettings } from '@infrastructure/settings/index.js';
import { parseEnvInteger } from '@infrastructure/settings/env-parsing.js';
import type { ServerSettings } from '@infrastructure/settings/types.js';

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
    wsPort: parseEnvInteger(process.env.TRON_WS_PORT, {
      name: 'TRON_WS_PORT',
      fallback: settings.wsPort,
      min: 1,
      max: 65535,
      logger,
    }),
    healthPort: parseEnvInteger(process.env.TRON_HEALTH_PORT, {
      name: 'TRON_HEALTH_PORT',
      fallback: settings.healthPort,
      min: 1,
      max: 65535,
      logger,
    }),
    host: process.env.TRON_HOST ?? settings.host,
    eventStoreDbPath: process.env.TRON_EVENT_STORE_DB,
    defaultModel: process.env.TRON_DEFAULT_MODEL ?? settings.defaultModel,
    defaultProvider: process.env.TRON_DEFAULT_PROVIDER ?? settings.defaultProvider,
    maxConcurrentSessions: parseEnvInteger(process.env.TRON_MAX_SESSIONS, {
      name: 'TRON_MAX_SESSIONS',
      fallback: settings.maxConcurrentSessions,
      min: 1,
      max: 10000,
      logger,
    }),
    heartbeatInterval: parseEnvInteger(process.env.TRON_HEARTBEAT_INTERVAL, {
      name: 'TRON_HEARTBEAT_INTERVAL',
      fallback: settings.heartbeatIntervalMs,
      min: 1000,
      max: 600000,
      logger,
    }),
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

const isMain =
  process.argv[1]?.endsWith('server.js') ||
  process.argv[1]?.endsWith('server.ts') ||
  process.argv[1]?.endsWith('index.js');
if (isMain) {
  main().catch((error) => {
    logger.error('Failed to start server', error);
    process.exit(1);
  });
}
