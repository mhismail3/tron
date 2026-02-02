/**
 * @fileoverview Health Check HTTP Server
 *
 * Simple HTTP server for health checks, metrics, and API endpoints.
 */
import * as http from 'http';
import { createLogger, categorizeError, LogErrorCategory } from '@infrastructure/logging/index.js';
import {
  getProviderAuthSync,
  saveProviderAuthSync,
  loadAuthStorageSync,
  saveAuthStorageSync,
} from '@infrastructure/auth/unified.js';
import type { EventStoreOrchestrator } from '@runtime/orchestrator/persistence/event-store-orchestrator.js';

const logger = createLogger('health');

// =============================================================================
// Types
// =============================================================================

export interface HealthServerConfig {
  /** Port to listen on */
  port: number;
  /** Host to bind to */
  host?: string;
}

export interface HealthResponse {
  status: 'healthy' | 'degraded' | 'unhealthy';
  version: string;
  uptime: number;
  timestamp: string;
  components: {
    orchestrator: {
      status: 'healthy' | 'degraded' | 'unhealthy';
      activeSessions: number;
      processingSessions: number;
    };
    websocket: {
      status: 'healthy' | 'degraded' | 'unhealthy';
      connectedClients: number;
    };
  };
}

export interface CodexTokens {
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
}

// =============================================================================
// Health Server
// =============================================================================

export class HealthServer {
  private config: HealthServerConfig;
  private server: http.Server | null = null;
  private orchestrator: EventStoreOrchestrator | null = null;
  private wsClientCount: () => number = () => 0;

  constructor(config: HealthServerConfig) {
    this.config = config;
  }

  /**
   * Set orchestrator reference for health checks
   */
  setEventStoreOrchestrator(orchestrator: EventStoreOrchestrator): void {
    this.orchestrator = orchestrator;
  }

  /**
   * Set WebSocket client count function
   */
  setWsClientCount(fn: () => number): void {
    this.wsClientCount = fn;
  }

  /**
   * Start the health server
   */
  async start(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.server = http.createServer((req, res) => {
        this.handleRequest(req, res);
      });

      this.server.on('error', (error) => {
        const structured = categorizeError(error, { operation: 'health_server_start' });
        logger.error('Health server error', {
          code: structured.code,
          category: LogErrorCategory.NETWORK,
          error: structured.message,
          retryable: structured.retryable,
        });
        reject(error);
      });

      this.server.listen(this.config.port, this.config.host ?? '0.0.0.0', () => {
        logger.info('Health server started', {
          port: this.config.port,
          host: this.config.host ?? '0.0.0.0',
        });
        resolve();
      });
    });
  }

  /**
   * Stop the health server
   */
  async stop(): Promise<void> {
    return new Promise((resolve) => {
      if (this.server) {
        this.server.close(() => {
          this.server = null;
          resolve();
        });
      } else {
        resolve();
      }
    });
  }

  // ===========================================================================
  // Private Methods
  // ===========================================================================

  private handleRequest(req: http.IncomingMessage, res: http.ServerResponse): void {
    // CORS headers
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

    if (req.method === 'OPTIONS') {
      res.writeHead(204);
      res.end();
      return;
    }

    const url = new URL(req.url ?? '/', `http://${req.headers.host}`);

    switch (url.pathname) {
      case '/health':
      case '/healthz':
        this.handleHealthCheck(req, res);
        break;
      case '/ready':
      case '/readyz':
        this.handleReadyCheck(req, res);
        break;
      case '/metrics':
        this.handleMetrics(req, res);
        break;
      case '/api/codex/tokens':
        this.handleCodexTokens(req, res);
        break;
      default:
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Not found' }));
    }
  }

  private handleHealthCheck(_req: http.IncomingMessage, res: http.ServerResponse): void {
    const health = this.getHealthResponse();

    const statusCode = health.status === 'healthy' ? 200 :
                       health.status === 'degraded' ? 200 : 503;

    res.writeHead(statusCode, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(health));
  }

  private handleReadyCheck(_req: http.IncomingMessage, res: http.ServerResponse): void {
    // Ready if orchestrator is available
    const isReady = this.orchestrator !== null;

    if (isReady) {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ready: true }));
    } else {
      res.writeHead(503, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ready: false, reason: 'Orchestrator not initialized' }));
    }
  }

  private handleMetrics(_req: http.IncomingMessage, res: http.ServerResponse): void {
    const health = this.orchestrator?.getHealth();
    const metrics = [
      `# HELP tron_uptime_seconds Server uptime in seconds`,
      `# TYPE tron_uptime_seconds gauge`,
      `tron_uptime_seconds ${process.uptime()}`,
      ``,
      `# HELP tron_active_sessions Number of active sessions`,
      `# TYPE tron_active_sessions gauge`,
      `tron_active_sessions ${health?.activeSessions ?? 0}`,
      ``,
      `# HELP tron_processing_sessions Number of sessions currently processing`,
      `# TYPE tron_processing_sessions gauge`,
      `tron_processing_sessions ${health?.processingSessions ?? 0}`,
      ``,
      `# HELP tron_websocket_clients Number of connected WebSocket clients`,
      `# TYPE tron_websocket_clients gauge`,
      `tron_websocket_clients ${this.wsClientCount()}`,
      ``,
      `# HELP tron_memory_heap_bytes Node.js heap memory usage`,
      `# TYPE tron_memory_heap_bytes gauge`,
      `tron_memory_heap_bytes ${process.memoryUsage().heapUsed}`,
    ].join('\n');

    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end(metrics);
  }

  private getHealthResponse(): HealthResponse {
    const orchestratorHealth = this.orchestrator?.getHealth() ?? {
      status: 'unhealthy' as const,
      activeSessions: 0,
      processingSessions: 0,
    };

    const wsClients = this.wsClientCount();

    // Determine overall status
    let overallStatus: 'healthy' | 'degraded' | 'unhealthy' = 'healthy';
    if (orchestratorHealth.status === 'unhealthy') {
      overallStatus = 'unhealthy';
    } else if (orchestratorHealth.status === 'degraded') {
      overallStatus = 'degraded';
    }

    return {
      status: overallStatus,
      version: '0.1.0',
      uptime: process.uptime(),
      timestamp: new Date().toISOString(),
      components: {
        orchestrator: {
          status: orchestratorHealth.status,
          activeSessions: orchestratorHealth.activeSessions,
          processingSessions: orchestratorHealth.processingSessions,
        },
        websocket: {
          status: 'healthy',
          connectedClients: wsClients,
        },
      },
    };
  }

  // ===========================================================================
  // Codex Token Management
  // ===========================================================================

  private handleCodexTokens(req: http.IncomingMessage, res: http.ServerResponse): void {
    if (req.method === 'GET') {
      this.handleGetCodexTokens(res);
    } else if (req.method === 'POST') {
      this.handleSaveCodexTokens(req, res);
    } else if (req.method === 'DELETE') {
      this.handleDeleteCodexTokens(res);
    } else {
      res.writeHead(405, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Method not allowed' }));
    }
  }

  private handleGetCodexTokens(res: http.ServerResponse): void {
    const tokens = this.getCodexTokens();
    if (tokens) {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        authenticated: true,
        expiresAt: tokens.expiresAt,
      }));
    } else {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ authenticated: false }));
    }
  }

  private handleSaveCodexTokens(req: http.IncomingMessage, res: http.ServerResponse): void {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      try {
        const tokens = JSON.parse(body) as CodexTokens;

        if (!tokens.accessToken || !tokens.refreshToken || !tokens.expiresAt) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Missing required fields' }));
          return;
        }

        this.saveCodexTokens(tokens);
        logger.info('Codex tokens saved');

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ success: true }));
      } catch (error) {
        const structured = categorizeError(error, { operation: 'save_codex_tokens' });
        logger.error('Failed to save Codex tokens', {
          code: structured.code,
          category: LogErrorCategory.PROVIDER_AUTH,
          error: structured.message,
          retryable: structured.retryable,
        });
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Invalid JSON' }));
      }
    });
  }

  private handleDeleteCodexTokens(res: http.ServerResponse): void {
    this.deleteCodexTokens();
    logger.info('Codex tokens deleted');
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ success: true }));
  }

  /**
   * Get stored Codex tokens from unified auth
   */
  getCodexTokens(): CodexTokens | null {
    try {
      const codexAuth = getProviderAuthSync('openai-codex');
      if (codexAuth?.oauth) {
        return {
          accessToken: codexAuth.oauth.accessToken,
          refreshToken: codexAuth.oauth.refreshToken,
          expiresAt: codexAuth.oauth.expiresAt,
        };
      }
    } catch (error) {
      const structured = categorizeError(error, { operation: 'read_codex_tokens' });
      logger.warn('Failed to read Codex tokens', {
        code: structured.code,
        category: LogErrorCategory.PROVIDER_AUTH,
        error: structured.message,
        retryable: structured.retryable,
      });
    }
    return null;
  }

  /**
   * Save Codex tokens to unified auth
   */
  saveCodexTokens(tokens: CodexTokens): void {
    try {
      saveProviderAuthSync('openai-codex', {
        oauth: {
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
          expiresAt: tokens.expiresAt,
        },
      });
    } catch (error) {
      const structured = categorizeError(error, { operation: 'persist_codex_tokens' });
      logger.warn('Failed to save Codex tokens', {
        code: structured.code,
        category: LogErrorCategory.PROVIDER_AUTH,
        error: structured.message,
        retryable: structured.retryable,
      });
    }
  }

  /**
   * Delete Codex tokens from unified auth
   */
  deleteCodexTokens(): void {
    try {
      const auth = loadAuthStorageSync();
      if (auth && auth.providers['openai-codex']) {
        delete auth.providers['openai-codex'];
        saveAuthStorageSync(auth);
      }
    } catch (error) {
      const structured = categorizeError(error, { operation: 'delete_codex_tokens' });
      logger.warn('Failed to delete Codex tokens', {
        code: structured.code,
        category: LogErrorCategory.PROVIDER_AUTH,
        error: structured.message,
        retryable: structured.retryable,
      });
    }
  }
}
