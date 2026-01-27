/**
 * @fileoverview Error Utilities
 *
 * Provides error classification and user-friendly error messages.
 * Handles common API errors, auth failures, and network issues.
 */

// =============================================================================
// Error Types
// =============================================================================

export type ErrorCategory =
  | 'authentication'
  | 'authorization'
  | 'rate_limit'
  | 'network'
  | 'server'
  | 'invalid_request'
  | 'quota'
  | 'unknown';

export interface ParsedError {
  category: ErrorCategory;
  message: string;
  details?: string;
  isRetryable: boolean;
  suggestion?: string;
}

// =============================================================================
// Error Patterns
// =============================================================================

interface ErrorPattern {
  pattern: RegExp | string;
  category: ErrorCategory;
  message: string;
  suggestion?: string;
  isRetryable: boolean;
}

const ERROR_PATTERNS: ErrorPattern[] = [
  // Authentication errors
  {
    pattern: /invalid.*x-api-key/i,
    category: 'authentication',
    message: 'Invalid API key',
    suggestion: 'Run "tron login" to re-authenticate or check your ANTHROPIC_API_KEY',
    isRetryable: false,
  },
  {
    pattern: /authentication_error/i,
    category: 'authentication',
    message: 'Authentication failed',
    suggestion: 'Run "tron login" to re-authenticate',
    isRetryable: false,
  },
  {
    pattern: /401/,
    category: 'authentication',
    message: 'Authentication required',
    suggestion: 'Run "tron login" or set ANTHROPIC_API_KEY environment variable',
    isRetryable: false,
  },
  {
    pattern: /invalid.*token/i,
    category: 'authentication',
    message: 'Invalid or expired token',
    suggestion: 'Run "tron login" to get a new token',
    isRetryable: false,
  },

  // Authorization errors
  {
    pattern: /403/,
    category: 'authorization',
    message: 'Access denied',
    suggestion: 'Check your account permissions',
    isRetryable: false,
  },
  {
    pattern: /permission_denied/i,
    category: 'authorization',
    message: 'Permission denied',
    suggestion: 'Your account may not have access to this feature',
    isRetryable: false,
  },

  // Rate limiting
  {
    pattern: /429/,
    category: 'rate_limit',
    message: 'Rate limit exceeded',
    suggestion: 'Wait a moment and try again',
    isRetryable: true,
  },
  {
    pattern: /rate.?limit/i,
    category: 'rate_limit',
    message: 'Rate limit exceeded',
    suggestion: 'Wait a moment and try again',
    isRetryable: true,
  },
  {
    pattern: /too.?many.?requests/i,
    category: 'rate_limit',
    message: 'Too many requests',
    suggestion: 'Wait a moment and try again',
    isRetryable: true,
  },

  // Quota errors
  {
    pattern: /quota/i,
    category: 'quota',
    message: 'Usage quota exceeded',
    suggestion: 'Check your account billing or upgrade your plan',
    isRetryable: false,
  },
  {
    pattern: /insufficient.?credits/i,
    category: 'quota',
    message: 'Insufficient credits',
    suggestion: 'Add credits to your account',
    isRetryable: false,
  },

  // Network errors
  {
    pattern: /ECONNREFUSED/i,
    category: 'network',
    message: 'Connection refused',
    suggestion: 'Check your internet connection',
    isRetryable: true,
  },
  {
    pattern: /ETIMEDOUT/i,
    category: 'network',
    message: 'Connection timed out',
    suggestion: 'Check your internet connection and try again',
    isRetryable: true,
  },
  {
    pattern: /ENOTFOUND/i,
    category: 'network',
    message: 'Could not reach server',
    suggestion: 'Check your internet connection',
    isRetryable: true,
  },
  {
    pattern: /network/i,
    category: 'network',
    message: 'Network error',
    suggestion: 'Check your internet connection',
    isRetryable: true,
  },

  // Server errors
  {
    pattern: /500/,
    category: 'server',
    message: 'Server error',
    suggestion: 'Try again in a moment',
    isRetryable: true,
  },
  {
    pattern: /502/,
    category: 'server',
    message: 'Server temporarily unavailable',
    suggestion: 'Try again in a moment',
    isRetryable: true,
  },
  {
    pattern: /503/,
    category: 'server',
    message: 'Service temporarily unavailable',
    suggestion: 'Try again in a moment',
    isRetryable: true,
  },
  {
    pattern: /overloaded/i,
    category: 'server',
    message: 'API is overloaded',
    suggestion: 'Try again in a moment',
    isRetryable: true,
  },

  // Invalid request
  {
    pattern: /400/,
    category: 'invalid_request',
    message: 'Invalid request',
    isRetryable: false,
  },
  {
    pattern: /invalid.*request/i,
    category: 'invalid_request',
    message: 'Invalid request',
    isRetryable: false,
  },
];

// =============================================================================
// Error Parsing
// =============================================================================

/**
 * Parse an error into a user-friendly format
 */
export function parseError(error: unknown): ParsedError {
  const errorString = extractErrorString(error);

  // Try to match against known patterns
  for (const pattern of ERROR_PATTERNS) {
    const matches = typeof pattern.pattern === 'string'
      ? errorString.includes(pattern.pattern)
      : pattern.pattern.test(errorString);

    if (matches) {
      return {
        category: pattern.category,
        message: pattern.message,
        details: extractDetails(errorString),
        isRetryable: pattern.isRetryable,
        suggestion: pattern.suggestion,
      };
    }
  }

  // Unknown error
  return {
    category: 'unknown',
    message: 'An unexpected error occurred',
    details: errorString.slice(0, 200),
    isRetryable: false,
  };
}

/**
 * Format an error for display
 */
export function formatError(error: unknown): string {
  const parsed = parseError(error);

  let result = parsed.message;
  if (parsed.suggestion) {
    result += `. ${parsed.suggestion}`;
  }

  return result;
}

/**
 * Format an error for display with full details
 */
export function formatErrorVerbose(error: unknown): string {
  const parsed = parseError(error);

  const parts = [parsed.message];
  if (parsed.details) {
    parts.push(`Details: ${parsed.details}`);
  }
  if (parsed.suggestion) {
    parts.push(`Suggestion: ${parsed.suggestion}`);
  }

  return parts.join('\n');
}

/**
 * Check if an error is an authentication error
 */
export function isAuthError(error: unknown): boolean {
  const parsed = parseError(error);
  return parsed.category === 'authentication' || parsed.category === 'authorization';
}

/**
 * Check if an error is retryable
 */
export function isRetryableError(error: unknown): boolean {
  const parsed = parseError(error);
  return parsed.isRetryable;
}

// =============================================================================
// Helpers
// =============================================================================

/**
 * Extract a string representation from any error type
 */
function extractErrorString(error: unknown): string {
  if (error === null || error === undefined) {
    return 'Unknown error';
  }

  if (typeof error === 'string') {
    return error;
  }

  if (error instanceof Error) {
    // Check for API error properties
    const apiError = error as Error & {
      status?: number;
      message?: string;
      error?: { type?: string; message?: string };
    };

    const parts: string[] = [];

    if (apiError.status) {
      parts.push(String(apiError.status));
    }
    if (apiError.message) {
      parts.push(apiError.message);
    }
    if (apiError.error?.type) {
      parts.push(apiError.error.type);
    }
    if (apiError.error?.message) {
      parts.push(apiError.error.message);
    }

    return parts.join(' ');
  }

  if (typeof error === 'object') {
    try {
      return JSON.stringify(error);
    } catch {
      return String(error);
    }
  }

  return String(error);
}

/**
 * Extract meaningful details from an error string
 */
function extractDetails(errorString: string): string | undefined {
  // Try to extract JSON error details
  const jsonMatch = errorString.match(/\{[^}]+\}/);
  if (jsonMatch) {
    try {
      const parsed = JSON.parse(jsonMatch[0]);
      if (parsed.error?.message) {
        return parsed.error.message;
      }
      if (parsed.message) {
        return parsed.message;
      }
    } catch {
      // Ignore parse errors
    }
  }

  // If the error string is reasonably short, return it
  if (errorString.length < 200) {
    return undefined; // The message is already informative
  }

  return undefined;
}

// =============================================================================
// Error Class Hierarchy
// =============================================================================

/**
 * Error severity levels
 */
export type ErrorSeverity = 'fatal' | 'error' | 'warning' | 'transient';

/**
 * Base error class with structured context for debugging and logging.
 *
 * Features:
 * - Machine-readable error code
 * - Error category for classification
 * - Severity level for prioritization
 * - Structured context for debugging
 * - Error cause chain support
 * - Serialization to structured log format
 */
export class TronError extends Error {
  /** Machine-readable error code (e.g., 'SESSION_NOT_FOUND') */
  readonly code: string;
  /** Error category for classification */
  readonly category: ErrorCategory;
  /** Error severity level */
  readonly severity: ErrorSeverity;
  /** Error timestamp */
  readonly timestamp: Date;
  /** Structured context for debugging */
  readonly context: Record<string, unknown>;

  constructor(
    message: string,
    options: {
      code: string;
      category?: ErrorCategory;
      severity?: ErrorSeverity;
      context?: Record<string, unknown>;
      cause?: Error;
    }
  ) {
    super(message, { cause: options.cause });
    this.name = 'TronError';
    this.code = options.code;
    this.category = options.category ?? 'unknown';
    this.severity = options.severity ?? 'error';
    this.timestamp = new Date();
    this.context = options.context ?? {};
  }

  /**
   * Check if this error is retryable based on its category
   */
  get isRetryable(): boolean {
    return ['rate_limit', 'network', 'server'].includes(this.category);
  }

  /**
   * Convert to structured log format for persistence
   */
  toStructuredLog(): Record<string, unknown> {
    return {
      error: {
        name: this.name,
        code: this.code,
        message: this.message,
        category: this.category,
        severity: this.severity,
        stack: this.stack,
        cause: this.cause instanceof Error ? {
          name: this.cause.name,
          message: this.cause.message,
          stack: this.cause.stack,
        } : undefined,
      },
      context: this.context,
      timestamp: this.timestamp.toISOString(),
    };
  }

  /**
   * Create a TronError from an unknown error value
   */
  static from(error: unknown, additionalContext?: Record<string, unknown>): TronError {
    if (error instanceof TronError) {
      if (additionalContext) {
        // Merge additional context
        return new TronError(error.message, {
          code: error.code,
          category: error.category,
          severity: error.severity,
          context: { ...error.context, ...additionalContext },
          cause: error.cause instanceof Error ? error.cause : undefined,
        });
      }
      return error;
    }

    const parsed = parseError(error);
    return new TronError(parsed.message, {
      code: parsed.category.toUpperCase(),
      category: parsed.category,
      severity: parsed.isRetryable ? 'transient' : 'error',
      context: {
        details: parsed.details,
        suggestion: parsed.suggestion,
        ...additionalContext,
      },
      cause: error instanceof Error ? error : undefined,
    });
  }
}

/**
 * Session-related errors with session context
 */
export class SessionError extends TronError {
  /** Session ID this error relates to */
  readonly sessionId: string;
  /** Operation that failed */
  readonly operation: 'create' | 'resume' | 'fork' | 'run' | 'interrupt' | 'close';

  constructor(
    message: string,
    options: {
      sessionId: string;
      operation: SessionError['operation'];
      code?: string;
      severity?: ErrorSeverity;
      context?: Record<string, unknown>;
      cause?: Error;
    }
  ) {
    super(message, {
      code: options.code ?? `SESSION_${options.operation.toUpperCase()}_ERROR`,
      category: 'unknown',
      severity: options.severity ?? 'error',
      context: {
        sessionId: options.sessionId,
        operation: options.operation,
        ...options.context,
      },
      cause: options.cause,
    });
    this.name = 'SessionError';
    this.sessionId = options.sessionId;
    this.operation = options.operation;
  }
}

/**
 * Database/storage persistence errors
 */
export class PersistenceError extends TronError {
  /** Table or store that failed */
  readonly table: string;
  /** Operation that failed */
  readonly operation: 'read' | 'write' | 'delete' | 'query';
  /** Sanitized query for debugging (no sensitive data) */
  readonly query?: string;

  constructor(
    message: string,
    options: {
      table: string;
      operation: PersistenceError['operation'];
      code?: string;
      severity?: ErrorSeverity;
      query?: string;
      context?: Record<string, unknown>;
      cause?: Error;
    }
  ) {
    super(message, {
      code: options.code ?? `PERSISTENCE_${options.operation.toUpperCase()}_ERROR`,
      category: 'unknown',
      severity: options.severity ?? 'error',
      context: {
        table: options.table,
        operation: options.operation,
        query: options.query,
        ...options.context,
      },
      cause: options.cause,
    });
    this.name = 'PersistenceError';
    this.table = options.table;
    this.operation = options.operation;
    this.query = options.query;
  }
}

/**
 * LLM provider errors with provider context
 */
export class ProviderError extends TronError {
  /** Provider name */
  readonly provider: 'anthropic' | 'openai' | 'google' | 'openrouter' | 'unknown';
  /** Model being used */
  readonly model: string;
  /** HTTP status code if applicable */
  readonly statusCode?: number;
  /** Whether this error is retryable */
  readonly retryable: boolean;
  /** Rate limit info if applicable */
  readonly rateLimitInfo?: { retryAfterMs: number; limit?: number };

  constructor(
    message: string,
    options: {
      provider: ProviderError['provider'];
      model: string;
      statusCode?: number;
      retryable?: boolean;
      rateLimitInfo?: { retryAfterMs: number; limit?: number };
      code?: string;
      severity?: ErrorSeverity;
      context?: Record<string, unknown>;
      cause?: Error;
    }
  ) {
    // Determine category based on status code
    let category: ErrorCategory = 'unknown';
    if (options.statusCode === 401) category = 'authentication';
    else if (options.statusCode === 403) category = 'authorization';
    else if (options.statusCode === 429) category = 'rate_limit';
    else if (options.statusCode && options.statusCode >= 500) category = 'server';
    else if (options.statusCode === 400) category = 'invalid_request';

    super(message, {
      code: options.code ?? `PROVIDER_${options.provider.toUpperCase()}_ERROR`,
      category,
      severity: options.retryable ? 'transient' : 'error',
      context: {
        provider: options.provider,
        model: options.model,
        statusCode: options.statusCode,
        ...options.context,
      },
      cause: options.cause,
    });
    this.name = 'ProviderError';
    this.provider = options.provider;
    this.model = options.model;
    this.statusCode = options.statusCode;
    this.retryable = options.retryable ?? (category === 'rate_limit' || category === 'server');
    this.rateLimitInfo = options.rateLimitInfo;
  }

  /**
   * Create from an Anthropic SDK error
   */
  static fromAnthropicError(error: unknown, model: string): ProviderError {
    const parsed = parseError(error);
    const statusCode = (error as { status?: number }).status;

    return new ProviderError(parsed.message, {
      provider: 'anthropic',
      model,
      statusCode,
      retryable: parsed.isRetryable,
      code: parsed.category.toUpperCase(),
      cause: error instanceof Error ? error : undefined,
    });
  }
}

/**
 * Tool execution errors with tool context
 */
export class ToolError extends TronError {
  /** Tool name */
  readonly toolName: string;
  /** Tool call ID */
  readonly toolCallId: string;
  /** Truncated input for debugging */
  readonly input?: Record<string, unknown>;

  constructor(
    message: string,
    options: {
      toolName: string;
      toolCallId: string;
      input?: Record<string, unknown>;
      code?: string;
      severity?: ErrorSeverity;
      context?: Record<string, unknown>;
      cause?: Error;
    }
  ) {
    super(message, {
      code: options.code ?? `TOOL_${options.toolName.toUpperCase()}_ERROR`,
      category: 'unknown',
      severity: options.severity ?? 'error',
      context: {
        toolName: options.toolName,
        toolCallId: options.toolCallId,
        input: options.input,
        ...options.context,
      },
      cause: options.cause,
    });
    this.name = 'ToolError';
    this.toolName = options.toolName;
    this.toolCallId = options.toolCallId;
    this.input = options.input;
  }
}

/**
 * Collect errors from fire-and-forget operations without losing them.
 *
 * Usage:
 * ```typescript
 * const collector = new ErrorCollector();
 * await Promise.all(tasks.map(t => t.catch(e => collector.collect(e))));
 * if (collector.hasErrors()) {
 *   // Log or handle collected errors
 * }
 * ```
 */
export class ErrorCollector {
  private errors: TronError[] = [];

  /**
   * Collect an error, wrapping it in TronError if needed
   */
  collect(error: unknown, context?: Record<string, unknown>): void {
    const tronError = TronError.from(error, context);
    this.errors.push(tronError);
  }

  /**
   * Check if any errors were collected
   */
  hasErrors(): boolean {
    return this.errors.length > 0;
  }

  /**
   * Get all collected errors
   */
  getErrors(): TronError[] {
    return [...this.errors];
  }

  /**
   * Get and clear all collected errors
   */
  flush(): TronError[] {
    const errors = [...this.errors];
    this.errors = [];
    return errors;
  }

  /**
   * Get count of collected errors
   */
  get count(): number {
    return this.errors.length;
  }
}

/**
 * RPC handler errors with error codes
 *
 * Used by RPC handlers when converting response errors to exceptions.
 * Provides proper typing for the error code property.
 */
export class RpcHandlerError extends TronError {
  constructor(
    message: string,
    options: {
      code?: string;
      context?: Record<string, unknown>;
      cause?: Error;
    } = {}
  ) {
    super(message, {
      code: options.code ?? 'RPC_ERROR',
      category: 'unknown',
      severity: 'error',
      context: options.context,
      cause: options.cause,
    });
    this.name = 'RpcHandlerError';
  }

  /**
   * Create an RpcHandlerError from an RPC response error
   */
  static fromResponse(response: { error?: { message?: string; code?: string } }): RpcHandlerError {
    return new RpcHandlerError(
      response.error?.message ?? 'Unknown error',
      { code: response.error?.code }
    );
  }
}
