/**
 * @fileoverview HTTP API implementation
 *
 * Provides REST API endpoints for the Tron server.
 */

import type {
  HttpApiConfig,
  HttpApiContext,
  HttpRequestOptions,
  HttpResponse,
  Route,
} from './types.js';
import { DEFAULT_HTTP_API_CONFIG } from './types.js';
import { createLogger } from '../../../logging/index.js';

const logger = createLogger('http-api');

// Re-export types
export type { HttpApiConfig, HttpApiContext, HttpRequestOptions, HttpResponse };

/**
 * Create a route pattern from a path string
 */
function createRoutePattern(path: string): { pattern: RegExp; params: string[] } {
  const params: string[] = [];
  const patternStr = path.replace(/:(\w+)/g, (_, name) => {
    params.push(name);
    return '([^/]+)';
  });
  return {
    pattern: new RegExp(`^${patternStr}/?$`),
    params,
  };
}

/**
 * HTTP API class
 */
export class HttpApi {
  private config: Required<Omit<HttpApiConfig, 'authToken'>> & { authToken?: string };
  private context: HttpApiContext;
  private routes: Route[] = [];

  constructor(config: HttpApiConfig, context: HttpApiContext) {
    this.config = {
      ...DEFAULT_HTTP_API_CONFIG,
      ...config,
    };
    this.context = context;
    this.setupRoutes();
  }

  /**
   * Handle an HTTP request
   */
  async handleRequest(
    method: string,
    path: string,
    options: HttpRequestOptions
  ): Promise<HttpResponse> {
    // Handle CORS preflight
    if (method === 'OPTIONS') {
      return this.handleCorsPrelight();
    }

    // Check authentication if required
    if (this.config.requireAuth) {
      const authError = this.checkAuth(options.headers);
      if (authError) {
        return this.addCorsHeaders(authError);
      }
    }

    // Normalize path
    const normalizedPath = path.endsWith('/') && path.length > 1
      ? path.slice(0, -1)
      : path;

    // Find matching route
    for (const route of this.routes) {
      if (route.method !== method) continue;

      const match = normalizedPath.match(route.pattern);
      if (match) {
        // Extract path parameters
        const params: Record<string, string> = {};
        route.params.forEach((name, i) => {
          // The match group is guaranteed to exist since the pattern was matched
          params[name] = match[i + 1] ?? '';
        });

        try {
          const response = await route.handler(this.context, params, options);
          return this.addCorsHeaders(response);
        } catch (error) {
          return this.addCorsHeaders(this.handleError(error));
        }
      }
    }

    // Check if path matches but method doesn't
    const pathMatches = this.routes.some((r) => normalizedPath.match(r.pattern));
    if (pathMatches) {
      return this.addCorsHeaders({
        status: 405,
        body: {
          error: {
            code: 'METHOD_NOT_ALLOWED',
            message: `Method ${method} not allowed for ${path}`,
          },
        },
      });
    }

    // Not found
    return this.addCorsHeaders({
      status: 404,
      body: {
        error: {
          code: 'NOT_FOUND',
          message: `No route found for ${method} ${path}`,
        },
      },
    });
  }

  // Private methods

  private setupRoutes(): void {
    const base = this.config.basePath;

    // POST /api/sessions - Create session
    this.addRoute('POST', `${base}/sessions`, async (ctx, _, opts) => {
      const body = opts.body as Record<string, unknown> | undefined;

      if (!body?.workingDirectory) {
        return {
          status: 400,
          body: {
            error: {
              code: 'INVALID_PARAMS',
              message: 'workingDirectory is required',
            },
          },
        };
      }

      const result = await ctx.createSession({
        workingDirectory: body.workingDirectory as string,
        model: body.model as string | undefined,
        provider: body.provider as string | undefined,
      });

      return {
        status: 201,
        body: result,
      };
    });

    // GET /api/sessions - List sessions
    this.addRoute('GET', `${base}/sessions`, async (ctx, _, opts) => {
      const query = opts.query ?? {};
      const result = await ctx.listSessions({
        limit: query.limit ? parseInt(query.limit, 10) : undefined,
        workspaceId: query.workspaceId,
      });

      return {
        status: 200,
        body: result,
      };
    });

    // GET /api/sessions/:id/status - Get session status
    this.addRoute('GET', `${base}/sessions/:sessionId/status`, async (ctx, params) => {
      const sessionId = params.sessionId!;
      try {
        const state = await ctx.getSessionState(sessionId);
        return {
          status: 200,
          body: state,
        };
      } catch (error) {
        if (error instanceof Error && error.message.includes('not found')) {
          return {
            status: 404,
            body: {
              error: {
                code: 'NOT_FOUND',
                message: `Session ${sessionId} not found`,
              },
            },
          };
        }
        throw error;
      }
    });

    // POST /api/sessions/:id/prompt - Send prompt
    this.addRoute('POST', `${base}/sessions/:sessionId/prompt`, async (ctx, params, opts) => {
      const sessionId = params.sessionId!;
      const body = opts.body as Record<string, unknown> | undefined;

      if (!body?.prompt) {
        return {
          status: 400,
          body: {
            error: {
              code: 'INVALID_PARAMS',
              message: 'prompt is required',
            },
          },
        };
      }

      const result = await ctx.sendPrompt(sessionId, {
        prompt: body.prompt as string,
        reasoningLevel: body.reasoningLevel as string | undefined,
        idempotencyKey: body.idempotencyKey as string | undefined,
      });

      return {
        status: 202,
        body: result,
      };
    });

    // POST /api/sessions/:id/abort - Abort session
    this.addRoute('POST', `${base}/sessions/:sessionId/abort`, async (ctx, params) => {
      const sessionId = params.sessionId!;
      const result = await ctx.abortSession(sessionId);
      return {
        status: 200,
        body: result,
      };
    });

    // GET /api/sessions/:id/events - SSE event stream
    this.addRoute('GET', `${base}/sessions/:sessionId/events`, async (ctx, params) => {
      const sessionId = params.sessionId!;

      // Check if SSE is supported
      if (!ctx.subscribeToEvents) {
        return {
          status: 501,
          body: {
            error: {
              code: 'NOT_IMPLEMENTED',
              message: 'SSE events not supported by this server',
            },
          },
        };
      }

      // Create SSE stream generator
      const sseStream = this.createSSEStream(ctx, sessionId);

      return {
        status: 200,
        body: null,
        headers: {
          'Content-Type': 'text/event-stream',
          'Cache-Control': 'no-cache',
          'Connection': 'keep-alive',
        },
        sseStream,
      };
    });
  }

  /**
   * Create an SSE stream for session events
   */
  private async *createSSEStream(
    ctx: HttpApiContext,
    sessionId: string
  ): AsyncGenerator<string, void, unknown> {
    // Queue for events
    const eventQueue: unknown[] = [];
    let resolveWait: (() => void) | null = null;
    let isActive = true;

    // Subscribe to events
    const unsubscribe = ctx.subscribeToEvents!(sessionId, (event) => {
      eventQueue.push(event);
      if (resolveWait) {
        resolveWait();
        resolveWait = null;
      }
    });

    try {
      // Send initial connection event
      yield `event: connected\ndata: ${JSON.stringify({ sessionId, timestamp: new Date().toISOString() })}\n\n`;

      while (isActive) {
        // Wait for events if queue is empty
        if (eventQueue.length === 0) {
          await new Promise<void>((resolve) => {
            resolveWait = resolve;
            // Timeout after 30 seconds and send a heartbeat
            setTimeout(() => {
              if (resolveWait === resolve) {
                resolveWait = null;
                resolve();
              }
            }, 30000);
          });
        }

        // Process queued events
        while (eventQueue.length > 0) {
          const event = eventQueue.shift();
          const eventType = (event as { type?: string })?.type ?? 'message';
          yield `event: ${eventType}\ndata: ${JSON.stringify(event)}\n\n`;
        }

        // Send heartbeat if no events
        if (eventQueue.length === 0) {
          yield `: heartbeat\n\n`;
        }
      }
    } finally {
      unsubscribe();
    }
  }

  private addRoute(
    method: Route['method'],
    path: string,
    handler: Route['handler']
  ): void {
    const { pattern, params } = createRoutePattern(path);
    this.routes.push({ method, pattern, params, handler });
  }

  private checkAuth(headers?: Record<string, string>): HttpResponse | null {
    if (!this.config.requireAuth) return null;

    const authHeader = headers?.authorization ?? headers?.Authorization;

    if (!authHeader) {
      return {
        status: 401,
        body: {
          error: {
            code: 'UNAUTHORIZED',
            message: 'Authentication required',
          },
        },
      };
    }

    const [scheme, token] = authHeader.split(' ');

    if (scheme !== 'Bearer' || !token) {
      return {
        status: 401,
        body: {
          error: {
            code: 'UNAUTHORIZED',
            message: 'Invalid authorization format. Use: Bearer <token>',
          },
        },
      };
    }

    if (this.config.authToken && token !== this.config.authToken) {
      return {
        status: 401,
        body: {
          error: {
            code: 'UNAUTHORIZED',
            message: 'Invalid token',
          },
        },
      };
    }

    return null;
  }

  private handleCorsPrelight(): HttpResponse {
    return {
      status: 204,
      body: null,
      headers: {
        'Access-Control-Allow-Origin': this.getCorsOrigin(),
        'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization',
        'Access-Control-Max-Age': '86400',
      },
    };
  }

  private addCorsHeaders(response: HttpResponse): HttpResponse {
    if (!this.config.enableCors) return response;

    return {
      ...response,
      headers: {
        ...response.headers,
        'Access-Control-Allow-Origin': this.getCorsOrigin(),
      },
    };
  }

  private getCorsOrigin(): string {
    const origins = this.config.corsOrigins;
    if (Array.isArray(origins)) {
      return origins.join(', ');
    }
    return origins;
  }

  private handleError(error: unknown): HttpResponse {
    logger.error('HTTP API error', { error });

    return {
      status: 500,
      body: {
        error: {
          code: 'INTERNAL_ERROR',
          message: error instanceof Error ? error.message : 'An error occurred',
        },
      },
    };
  }
}

/**
 * Create an HTTP API instance
 */
export function createHttpApi(
  config: HttpApiConfig,
  context: HttpApiContext
): HttpApi {
  return new HttpApi(config, context);
}
