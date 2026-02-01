/**
 * @fileoverview Webhook handler for external triggers
 *
 * Allows external systems to trigger agent actions via HTTP webhooks.
 */

import { createHmac } from 'crypto';
import { createLogger } from '../../../logging/index.js';

const logger = createLogger('webhook');

/**
 * Webhook configuration
 */
export interface WebhookConfig {
  /** HMAC secret for signature verification */
  secret?: string;
  /** Rate limiting configuration */
  rateLimit?: {
    /** Maximum requests per window */
    maxRequests: number;
    /** Window duration in milliseconds */
    windowMs: number;
  };
}

/**
 * Context interface for webhooks
 */
export interface WebhookContext {
  /** Send a prompt to a session */
  sendPrompt(
    sessionId: string,
    params: { prompt: string; idempotencyKey?: string }
  ): Promise<{ acknowledged: boolean; runId?: string }>;

  /** Get existing session for a workspace */
  getSessionByWorkspace(workspaceId: string): Promise<string | null>;

  /** Create a new session */
  createSession(params: {
    workingDirectory: string;
    workspaceId?: string;
  }): Promise<{ sessionId: string; workspaceId: string }>;
}

/**
 * Webhook trigger payload
 */
export interface WebhookTriggerPayload {
  /** Explicit session ID to target */
  sessionId?: string;
  /** Workspace ID to find or create session */
  workspaceId?: string;
  /** Working directory for new sessions */
  workingDirectory?: string;
  /** Prompt to send */
  prompt: string;
  /** Optional metadata */
  metadata?: Record<string, unknown>;
  /** Idempotency key for deduplication */
  idempotencyKey?: string;
}

/**
 * Webhook request
 */
export interface WebhookRequest {
  /** Raw body string */
  body: string;
  /** Signature header value */
  signature?: string;
}

/**
 * Webhook result
 */
export interface WebhookResult {
  /** Whether the webhook was processed successfully */
  success: boolean;
  /** Session that was triggered */
  sessionId?: string;
  /** Run ID for tracking */
  runId?: string;
  /** Error message if failed */
  error?: string;
}

/**
 * Rate limit entry
 */
interface RateLimitEntry {
  count: number;
  windowStart: number;
}

/**
 * Webhook handler
 */
export class WebhookHandler {
  private config: WebhookConfig;
  private context: WebhookContext;
  private rateLimitMap = new Map<string, RateLimitEntry>();

  constructor(config: WebhookConfig, context: WebhookContext) {
    this.config = config;
    this.context = context;
  }

  /**
   * Handle a raw webhook request
   */
  async handleRequest(request: WebhookRequest): Promise<WebhookResult> {
    // Verify signature if secret is configured
    if (this.config.secret) {
      if (!request.signature) {
        return {
          success: false,
          error: 'Missing signature header',
        };
      }

      const expectedSig = this.computeSignature(request.body);
      if (request.signature !== expectedSig) {
        logger.warn('Invalid webhook signature');
        return {
          success: false,
          error: 'Invalid signature',
        };
      }
    }

    // Parse body
    let payload: WebhookTriggerPayload;
    try {
      payload = JSON.parse(request.body);
    } catch {
      return {
        success: false,
        error: 'Invalid JSON body',
      };
    }

    // Validate required fields
    if (!payload.prompt) {
      return {
        success: false,
        error: 'Missing required field: prompt',
      };
    }

    return this.handleTrigger(payload);
  }

  /**
   * Handle a parsed trigger payload
   */
  async handleTrigger(payload: WebhookTriggerPayload): Promise<WebhookResult> {
    // Check rate limit
    const source = (payload.metadata?.source as string) ?? 'default';
    if (this.config.rateLimit && !this.checkRateLimit(source)) {
      return {
        success: false,
        error: 'Rate limit exceeded',
      };
    }

    try {
      // Determine target session
      let sessionId = payload.sessionId;

      if (!sessionId && payload.workspaceId) {
        // Try to find existing session
        sessionId = await this.context.getSessionByWorkspace(payload.workspaceId) ?? undefined;

        // Create new session if none exists
        if (!sessionId) {
          if (!payload.workingDirectory) {
            return {
              success: false,
              error: 'No existing session found and no workingDirectory provided to create one',
            };
          }

          const newSession = await this.context.createSession({
            workingDirectory: payload.workingDirectory,
            workspaceId: payload.workspaceId,
          });
          sessionId = newSession.sessionId;
        }
      }

      if (!sessionId) {
        return {
          success: false,
          error: 'No sessionId or workspaceId provided',
        };
      }

      // Send the prompt
      const result = await this.context.sendPrompt(sessionId, {
        prompt: payload.prompt,
        idempotencyKey: payload.idempotencyKey,
      });

      logger.info('Webhook triggered', {
        sessionId,
        runId: result.runId,
        source,
      });

      return {
        success: true,
        sessionId,
        runId: result.runId,
      };
    } catch (error) {
      logger.error('Webhook trigger failed', { error });
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Unknown error',
      };
    }
  }

  /**
   * Compute HMAC signature for a payload
   */
  computeSignature(payload: string): string {
    if (!this.config.secret) {
      throw new Error('No secret configured');
    }
    return createHmac('sha256', this.config.secret)
      .update(payload)
      .digest('hex');
  }

  /**
   * Check rate limit for a source
   */
  private checkRateLimit(source: string): boolean {
    if (!this.config.rateLimit) return true;

    const now = Date.now();
    const { maxRequests, windowMs } = this.config.rateLimit;

    let entry = this.rateLimitMap.get(source);

    // Reset if window expired
    if (!entry || now - entry.windowStart >= windowMs) {
      entry = { count: 0, windowStart: now };
      this.rateLimitMap.set(source, entry);
    }

    // Check limit
    if (entry.count >= maxRequests) {
      return false;
    }

    entry.count++;
    return true;
  }
}

/**
 * Create a webhook handler
 */
export function createWebhookHandler(
  config: WebhookConfig,
  context: WebhookContext
): WebhookHandler {
  return new WebhookHandler(config, context);
}
