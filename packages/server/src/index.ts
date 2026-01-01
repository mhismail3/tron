/**
 * @fileoverview Tron Server Entry Point
 *
 * Main entry point for the Tron WebSocket server.
 */
import * as path from 'path';
import * as os from 'os';
import { createLogger, type RpcContext } from '@tron/core';
import { TronWebSocketServer, type WebSocketServerConfig } from './websocket.js';
import { SessionOrchestrator, type OrchestratorConfig } from './orchestrator.js';
import { HealthServer, type HealthServerConfig } from './health.js';

const logger = createLogger('server');

// =============================================================================
// RpcContext Adapter
// =============================================================================

/**
 * Creates an RpcContext adapter from SessionOrchestrator
 * This adapts the orchestrator's interfaces to what RpcHandler expects
 */
function createRpcContext(orchestrator: SessionOrchestrator): RpcContext {
  return {
    sessionManager: {
      async createSession(params) {
        const session = await orchestrator.createSession({
          workingDirectory: params.workingDirectory,
          model: params.model,
        });
        return {
          sessionId: session.id,
          model: session.model,
          createdAt: session.createdAt,
        };
      },
      async getSession(sessionId) {
        const session = await orchestrator.getSession(sessionId);
        if (!session) return null;
        return {
          sessionId: session.id,
          workingDirectory: session.workingDirectory,
          model: session.model,
          messageCount: session.messages?.length ?? 0,
          createdAt: session.createdAt,
          lastActivity: session.lastActivityAt ?? session.createdAt,
          isActive: session.isActive ?? true,
          messages: session.messages ?? [],
        };
      },
      async listSessions(params) {
        const sessions = await orchestrator.listSessions({
          workingDirectory: params.workingDirectory,
          limit: params.limit,
        });
        return sessions.map(s => ({
          sessionId: s.id,
          workingDirectory: s.workingDirectory,
          model: s.model,
          messageCount: s.messages?.length ?? 0,
          createdAt: s.createdAt,
          lastActivity: s.lastActivityAt ?? s.createdAt,
          isActive: s.isActive ?? true,
          messages: s.messages ?? [],
        }));
      },
      async deleteSession(sessionId) {
        await orchestrator.endSession(sessionId, 'completed');
        return true;
      },
      async forkSession(_sessionId, _fromIndex) {
        // Not implemented in orchestrator yet
        throw new Error('Fork not implemented');
      },
      async rewindSession(_sessionId, _toIndex) {
        // Not implemented in orchestrator yet
        throw new Error('Rewind not implemented');
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
        return {
          isRunning: active?.isProcessing ?? false,
          currentTurn: 0,
          messageCount: active?.session.messages?.length ?? session?.messages?.length ?? 0,
          tokenUsage: {
            input: session?.tokenUsage?.inputTokens ?? 0,
            output: session?.tokenUsage?.outputTokens ?? 0,
          },
          model: session?.model ?? 'unknown',
          tools: [], // Tools list would come from agent config
        };
      },
    },
    memoryStore: {
      async searchEntries(params) {
        const results = await orchestrator.searchMemory({
          query: params.searchText ?? '',
          type: params.type as 'pattern' | 'decision' | 'lesson' | 'context' | 'preference' | undefined,
          limit: params.limit,
        });
        return {
          entries: results.map(r => ({
            id: r.id,
            content: r.content,
            type: 'pattern' as const,
            source: 'project' as const,
            relevance: r.score,
            timestamp: new Date().toISOString(),
          })),
          totalCount: results.length,
        };
      },
      async addEntry(params) {
        // Map 'error' to 'lesson' since orchestrator doesn't support 'error' type
        const validType = params.type === 'error' ? 'lesson' : params.type;
        const id = await orchestrator.storeMemory({
          workingDirectory: process.cwd(),
          content: params.content,
          type: validType as 'pattern' | 'decision' | 'lesson' | 'context' | 'preference',
        });
        return { id };
      },
      async listHandoffs(_workingDirectory, _limit) {
        // Not directly supported by orchestrator
        return [];
      },
    },
  };
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
  /** Sessions directory */
  sessionsDir?: string;
  /** Memory database path */
  memoryDbPath?: string;
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
  private orchestrator: SessionOrchestrator | null = null;
  private wsServer: TronWebSocketServer | null = null;
  private healthServer: HealthServer | null = null;
  private isRunning = false;

  constructor(config: TronServerConfig) {
    this.config = config;
  }

  /**
   * Start the server
   */
  async start(): Promise<void> {
    if (this.isRunning) {
      throw new Error('Server is already running');
    }

    logger.info('Starting Tron server...');

    // Resolve paths
    const homeDir = os.homedir();
    const tronDir = path.join(homeDir, '.tron');
    const sessionsDir = this.config.sessionsDir ?? path.join(tronDir, 'sessions');
    const memoryDbPath = this.config.memoryDbPath ?? path.join(tronDir, 'memory.db');

    // Initialize orchestrator
    const orchestratorConfig: OrchestratorConfig = {
      sessionsDir,
      memoryDbPath,
      defaultModel: this.config.defaultModel ?? 'claude-sonnet-4-20250514',
      defaultProvider: this.config.defaultProvider ?? 'anthropic',
      maxConcurrentSessions: this.config.maxConcurrentSessions,
    };

    this.orchestrator = new SessionOrchestrator(orchestratorConfig);
    await this.orchestrator.initialize();

    // Create RpcContext adapter
    const rpcContext = createRpcContext(this.orchestrator);

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
    this.healthServer.setOrchestrator(this.orchestrator);
    this.healthServer.setWsClientCount(() => this.wsServer?.getClientCount() ?? 0);
    await this.healthServer.start();

    // Forward orchestrator events to WebSocket clients
    this.orchestrator.on('session_created', (session) => {
      this.wsServer?.broadcastEvent({
        type: 'session.created',
        timestamp: new Date().toISOString(),
        data: { session },
      });
    });

    this.orchestrator.on('session_ended', (data) => {
      this.wsServer?.broadcastEvent({
        type: 'session.ended',
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

    this.isRunning = true;

    logger.info('Tron server started', {
      wsPort: this.config.wsPort,
      healthPort: this.config.healthPort,
      host: this.config.host ?? '0.0.0.0',
    });
  }

  /**
   * Stop the server
   */
  async stop(): Promise<void> {
    if (!this.isRunning) {
      return;
    }

    logger.info('Stopping Tron server...');

    // Stop in reverse order
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

  /**
   * Check if server is running
   */
  getIsRunning(): boolean {
    return this.isRunning;
  }

  /**
   * Get orchestrator (for direct access in tests)
   */
  getOrchestrator(): SessionOrchestrator | null {
    return this.orchestrator;
  }
}

// =============================================================================
// CLI Entry Point
// =============================================================================

async function main(): Promise<void> {
  const config: TronServerConfig = {
    wsPort: parseInt(process.env.TRON_WS_PORT ?? '8080', 10),
    healthPort: parseInt(process.env.TRON_HEALTH_PORT ?? '8081', 10),
    host: process.env.TRON_HOST,
    sessionsDir: process.env.TRON_SESSIONS_DIR,
    memoryDbPath: process.env.TRON_MEMORY_DB,
    defaultModel: process.env.TRON_DEFAULT_MODEL,
    defaultProvider: process.env.TRON_DEFAULT_PROVIDER,
    maxConcurrentSessions: process.env.TRON_MAX_SESSIONS
      ? parseInt(process.env.TRON_MAX_SESSIONS, 10)
      : undefined,
    heartbeatInterval: process.env.TRON_HEARTBEAT_INTERVAL
      ? parseInt(process.env.TRON_HEARTBEAT_INTERVAL, 10)
      : undefined,
  };

  const server = new TronServer(config);

  // Handle shutdown signals
  const shutdown = async (signal: string) => {
    logger.info(`Received ${signal}, shutting down...`);
    await server.stop();
    process.exit(0);
  };

  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));

  // Handle uncaught errors
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

// Run if this is the main module
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
export { SessionOrchestrator } from './orchestrator.js';
export type { OrchestratorConfig, ActiveSession, AgentRunOptions, AgentEvent } from './orchestrator.js';
export { HealthServer } from './health.js';
export type { HealthServerConfig, HealthResponse } from './health.js';
