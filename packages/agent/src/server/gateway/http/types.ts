/**
 * @fileoverview HTTP API types
 */

/**
 * HTTP API configuration
 */
export interface HttpApiConfig {
  /** Base path for API routes (default: '/api') */
  basePath?: string;
  /** Enable CORS headers */
  enableCors?: boolean;
  /** Allowed CORS origins (default: '*') */
  corsOrigins?: string | string[];
  /** Require authentication */
  requireAuth?: boolean;
  /** Bearer token for authentication */
  authToken?: string;
}

/**
 * Default configuration
 */
export const DEFAULT_HTTP_API_CONFIG: Required<Omit<HttpApiConfig, 'authToken'>> & { authToken?: string } = {
  basePath: '/api',
  enableCors: true,
  corsOrigins: '*',
  requireAuth: false,
  authToken: undefined,
};

/**
 * HTTP request options
 */
export interface HttpRequestOptions {
  /** Request headers */
  headers?: Record<string, string>;
  /** Query parameters */
  query?: Record<string, string>;
  /** Request body (parsed JSON) */
  body?: unknown;
}

/**
 * HTTP response
 */
export interface HttpResponse {
  /** HTTP status code */
  status: number;
  /** Response body */
  body: unknown;
  /** Response headers */
  headers?: Record<string, string>;
  /** SSE stream generator (if this is an SSE response) */
  sseStream?: AsyncGenerator<string, void, unknown>;
}

/**
 * Context interface for the HTTP API
 * This allows the API to interact with the orchestrator
 */
export interface HttpApiContext {
  /** Create a new session */
  createSession(params: {
    workingDirectory: string;
    model?: string;
    provider?: string;
  }): Promise<{ sessionId: string; workspaceId: string }>;

  /** Get session state */
  getSessionState(sessionId: string): Promise<{
    isRunning: boolean;
    currentTurn: number;
    messageCount: number;
    tokenUsage: { input: number; output: number };
    model: string;
    tools: string[];
    wasInterrupted: boolean;
  }>;

  /** Send a prompt to a session */
  sendPrompt(
    sessionId: string,
    params: {
      prompt: string;
      reasoningLevel?: string;
      idempotencyKey?: string;
    }
  ): Promise<{ acknowledged: boolean; runId?: string }>;

  /** Abort a session */
  abortSession(sessionId: string): Promise<{ aborted: boolean }>;

  /** List sessions */
  listSessions(params?: {
    limit?: number;
    workspaceId?: string;
  }): Promise<{ sessions: Array<{ sessionId: string; status: string }> }>;

  /** Subscribe to session events (for SSE) */
  subscribeToEvents?(
    sessionId: string,
    callback: (event: unknown) => void
  ): () => void;
}

/**
 * Route definition
 */
export interface Route {
  /** HTTP method */
  method: 'GET' | 'POST' | 'PUT' | 'DELETE' | 'OPTIONS';
  /** Path pattern (supports :param) */
  pattern: RegExp;
  /** Parameter names in order */
  params: string[];
  /** Handler function */
  handler: (
    context: HttpApiContext,
    params: Record<string, string>,
    options: HttpRequestOptions
  ) => Promise<HttpResponse>;
}
