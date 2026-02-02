/**
 * @fileoverview Error categorization system for structured logging
 *
 * Provides standardized error codes and categories for consistent
 * error reporting and analysis across the codebase.
 */

// =============================================================================
// Error Categories
// =============================================================================

/**
 * High-level error categories for classification
 */
export enum LogErrorCategory {
  // Infrastructure
  DATABASE = 'DB',
  FILESYSTEM = 'FS',
  NETWORK = 'NET',

  // Provider/API
  PROVIDER_AUTH = 'PAUTH',
  PROVIDER_RATE_LIMIT = 'PRATE',
  PROVIDER_API = 'PAPI',
  PROVIDER_STREAM = 'PSTRM',

  // Agent/Tool
  TOOL_EXECUTION = 'TOOL',
  TOOL_VALIDATION = 'TVAL',
  GUARDRAIL = 'GUARD',

  // Session
  SESSION_STATE = 'SESS',
  EVENT_PERSIST = 'EVNT',

  // Context/Memory
  COMPACTION = 'COMP',
  TOKEN_LIMIT = 'TLIM',

  // Skill/Hook
  SKILL_LOAD = 'SKILL',
  HOOK_EXECUTION = 'HOOK',

  // Subagent
  SUBAGENT = 'SUB',

  // Unknown/Uncategorized
  UNKNOWN = 'UNK',
}

// =============================================================================
// Structured Error Interface
// =============================================================================

/**
 * Structured error with category, code, and metadata
 */
export interface StructuredError {
  /** Error category for high-level classification */
  category: LogErrorCategory;
  /** Specific error code (e.g., 'FS_NOT_FOUND', 'PRATE_429') */
  code: string;
  /** Human-readable error message */
  message: string;
  /** Additional context for debugging */
  context: Record<string, unknown>;
  /** Whether the operation can continue in degraded mode */
  recoverable: boolean;
  /** Whether retrying may succeed */
  retryable: boolean;
  /** Original error if wrapped */
  cause?: Error;
}

// =============================================================================
// Error Code Definitions
// =============================================================================

/**
 * Common error codes by category
 */
export const LogErrorCodes = {
  // Database errors
  DB_CONNECTION: 'DB_CONNECTION',
  DB_QUERY: 'DB_QUERY',
  DB_CONSTRAINT: 'DB_CONSTRAINT',
  DB_CORRUPTION: 'DB_CORRUPTION',

  // Filesystem errors
  FS_NOT_FOUND: 'FS_NOT_FOUND',
  FS_PERMISSION: 'FS_PERMISSION',
  FS_DISK_FULL: 'FS_DISK_FULL',
  FS_READ: 'FS_READ',
  FS_WRITE: 'FS_WRITE',
  FS_DELETE: 'FS_DELETE',

  // Network errors
  NET_TIMEOUT: 'NET_TIMEOUT',
  NET_DNS: 'NET_DNS',
  NET_REFUSED: 'NET_REFUSED',
  NET_RESET: 'NET_RESET',

  // Provider authentication
  PAUTH_INVALID: 'PAUTH_INVALID',
  PAUTH_EXPIRED: 'PAUTH_EXPIRED',
  PAUTH_MISSING: 'PAUTH_MISSING',

  // Provider rate limiting
  PRATE_429: 'PRATE_429',
  PRATE_QUOTA: 'PRATE_QUOTA',
  PRATE_CONCURRENT: 'PRATE_CONCURRENT',

  // Provider API errors
  PAPI_REQUEST: 'PAPI_REQUEST',
  PAPI_RESPONSE: 'PAPI_RESPONSE',
  PAPI_OVERLOADED: 'PAPI_OVERLOADED',
  PAPI_MODEL: 'PAPI_MODEL',

  // Provider streaming
  PSTRM_INTERRUPTED: 'PSTRM_INTERRUPTED',
  PSTRM_MALFORMED: 'PSTRM_MALFORMED',
  PSTRM_TIMEOUT: 'PSTRM_TIMEOUT',

  // Tool execution
  TOOL_NOT_FOUND: 'TOOL_NOT_FOUND',
  TOOL_TIMEOUT: 'TOOL_TIMEOUT',
  TOOL_ERROR: 'TOOL_ERROR',

  // Tool validation
  TVAL_SCHEMA: 'TVAL_SCHEMA',
  TVAL_PARAMS: 'TVAL_PARAMS',
  TVAL_OUTPUT: 'TVAL_OUTPUT',

  // Guardrail
  GUARD_BLOCKED: 'GUARD_BLOCKED',
  GUARD_LIMIT: 'GUARD_LIMIT',

  // Session state
  SESS_NOT_FOUND: 'SESS_NOT_FOUND',
  SESS_INVALID: 'SESS_INVALID',
  SESS_CONFLICT: 'SESS_CONFLICT',
  SESS_MAX_REACHED: 'SESS_MAX_REACHED',

  // Event persistence
  EVNT_PERSIST: 'EVNT_PERSIST',
  EVNT_CORRUPT: 'EVNT_CORRUPT',
  EVNT_ORDER: 'EVNT_ORDER',

  // Compaction
  COMP_FAILED: 'COMP_FAILED',
  COMP_SUMMARIZE: 'COMP_SUMMARIZE',

  // Token limits
  TLIM_OVERFLOW: 'TLIM_OVERFLOW',
  TLIM_CONTEXT: 'TLIM_CONTEXT',

  // Skill loading
  SKILL_NOT_FOUND: 'SKILL_NOT_FOUND',
  SKILL_PARSE: 'SKILL_PARSE',
  SKILL_ACCESS: 'SKILL_ACCESS',

  // Hook execution
  HOOK_TIMEOUT: 'HOOK_TIMEOUT',
  HOOK_ERROR: 'HOOK_ERROR',
  HOOK_ACCESS: 'HOOK_ACCESS',

  // Subagent
  SUB_SPAWN: 'SUB_SPAWN',
  SUB_NOT_FOUND: 'SUB_NOT_FOUND',
  SUB_TIMEOUT: 'SUB_TIMEOUT',
  SUB_ERROR: 'SUB_ERROR',

  // Unknown
  UNKNOWN: 'UNKNOWN',
} as const;

export type LogErrorCode = (typeof LogErrorCodes)[keyof typeof LogErrorCodes];

// =============================================================================
// Error Classification Helpers
// =============================================================================

/**
 * HTTP status code to category mapping
 */
const HTTP_STATUS_CATEGORIES: Record<number, { category: LogErrorCategory; code: LogErrorCode; retryable: boolean }> = {
  400: { category: LogErrorCategory.PROVIDER_API, code: LogErrorCodes.PAPI_REQUEST, retryable: false },
  401: { category: LogErrorCategory.PROVIDER_AUTH, code: LogErrorCodes.PAUTH_INVALID, retryable: false },
  403: { category: LogErrorCategory.PROVIDER_AUTH, code: LogErrorCodes.PAUTH_INVALID, retryable: false },
  404: { category: LogErrorCategory.PROVIDER_API, code: LogErrorCodes.PAPI_REQUEST, retryable: false },
  408: { category: LogErrorCategory.NETWORK, code: LogErrorCodes.NET_TIMEOUT, retryable: true },
  429: { category: LogErrorCategory.PROVIDER_RATE_LIMIT, code: LogErrorCodes.PRATE_429, retryable: true },
  500: { category: LogErrorCategory.PROVIDER_API, code: LogErrorCodes.PAPI_RESPONSE, retryable: true },
  502: { category: LogErrorCategory.PROVIDER_API, code: LogErrorCodes.PAPI_RESPONSE, retryable: true },
  503: { category: LogErrorCategory.PROVIDER_API, code: LogErrorCodes.PAPI_OVERLOADED, retryable: true },
  504: { category: LogErrorCategory.NETWORK, code: LogErrorCodes.NET_TIMEOUT, retryable: true },
};

/**
 * Node.js error code to category mapping
 */
const NODE_ERROR_CATEGORIES: Record<string, { category: LogErrorCategory; code: LogErrorCode; retryable: boolean }> = {
  ENOENT: { category: LogErrorCategory.FILESYSTEM, code: LogErrorCodes.FS_NOT_FOUND, retryable: false },
  EACCES: { category: LogErrorCategory.FILESYSTEM, code: LogErrorCodes.FS_PERMISSION, retryable: false },
  EPERM: { category: LogErrorCategory.FILESYSTEM, code: LogErrorCodes.FS_PERMISSION, retryable: false },
  ENOSPC: { category: LogErrorCategory.FILESYSTEM, code: LogErrorCodes.FS_DISK_FULL, retryable: false },
  EEXIST: { category: LogErrorCategory.FILESYSTEM, code: LogErrorCodes.FS_WRITE, retryable: false },
  EISDIR: { category: LogErrorCategory.FILESYSTEM, code: LogErrorCodes.FS_READ, retryable: false },
  ENOTDIR: { category: LogErrorCategory.FILESYSTEM, code: LogErrorCodes.FS_NOT_FOUND, retryable: false },
  ETIMEDOUT: { category: LogErrorCategory.NETWORK, code: LogErrorCodes.NET_TIMEOUT, retryable: true },
  ECONNREFUSED: { category: LogErrorCategory.NETWORK, code: LogErrorCodes.NET_REFUSED, retryable: true },
  ECONNRESET: { category: LogErrorCategory.NETWORK, code: LogErrorCodes.NET_RESET, retryable: true },
  ENOTFOUND: { category: LogErrorCategory.NETWORK, code: LogErrorCodes.NET_DNS, retryable: true },
  SQLITE_CONSTRAINT: { category: LogErrorCategory.DATABASE, code: LogErrorCodes.DB_CONSTRAINT, retryable: false },
  SQLITE_CORRUPT: { category: LogErrorCategory.DATABASE, code: LogErrorCodes.DB_CORRUPTION, retryable: false },
};

// =============================================================================
// Error Categorization Function
// =============================================================================

/**
 * Categorize an error with structured metadata
 *
 * @param error - The error to categorize
 * @param context - Additional context for the error
 * @returns Structured error with category and metadata
 */
export function categorizeError(
  error: Error | unknown,
  context?: Record<string, unknown>
): StructuredError {
  const err = error instanceof Error ? error : new Error(String(error));
  const baseContext = context ?? {};

  // Check for HTTP status codes (common in API errors)
  const status = extractStatusCode(err);
  if (status && HTTP_STATUS_CATEGORIES[status]) {
    const { category, code, retryable } = HTTP_STATUS_CATEGORIES[status];
    return {
      category,
      code,
      message: err.message,
      context: { ...baseContext, status },
      recoverable: false,
      retryable,
      cause: err,
    };
  }

  // Check for Node.js error codes
  const nodeCode = extractNodeErrorCode(err);
  if (nodeCode && NODE_ERROR_CATEGORIES[nodeCode]) {
    const { category, code, retryable } = NODE_ERROR_CATEGORIES[nodeCode];
    return {
      category,
      code,
      message: err.message,
      context: { ...baseContext, nodeCode },
      recoverable: false,
      retryable,
      cause: err,
    };
  }

  // Check for known error message patterns
  const pattern = matchErrorPattern(err.message);
  if (pattern) {
    return {
      ...pattern,
      message: err.message,
      context: baseContext,
      cause: err,
    };
  }

  // Default to unknown
  return {
    category: LogErrorCategory.UNKNOWN,
    code: LogErrorCodes.UNKNOWN,
    message: err.message,
    context: baseContext,
    recoverable: false,
    retryable: false,
    cause: err,
  };
}

/**
 * Create a structured error with specific category and code
 */
export function createStructuredError(
  category: LogErrorCategory,
  code: LogErrorCode,
  message: string,
  options?: {
    context?: Record<string, unknown>;
    recoverable?: boolean;
    retryable?: boolean;
    cause?: Error;
  }
): StructuredError {
  return {
    category,
    code,
    message,
    context: options?.context ?? {},
    recoverable: options?.recoverable ?? false,
    retryable: options?.retryable ?? false,
    cause: options?.cause,
  };
}

// =============================================================================
// Helper Functions
// =============================================================================

function extractStatusCode(err: Error): number | undefined {
  // Check common error properties for status codes
  const anyErr = err as unknown as Record<string, unknown>;
  if (typeof anyErr.status === 'number') return anyErr.status;
  if (typeof anyErr.statusCode === 'number') return anyErr.statusCode;
  if (typeof anyErr.code === 'number' && anyErr.code >= 100 && anyErr.code < 600) {
    return anyErr.code;
  }
  return undefined;
}

function extractNodeErrorCode(err: Error): string | undefined {
  const anyErr = err as unknown as Record<string, unknown>;
  if (typeof anyErr.code === 'string') return anyErr.code;
  return undefined;
}

function matchErrorPattern(message: string): Omit<StructuredError, 'message' | 'context' | 'cause'> | undefined {
  const lowerMessage = message.toLowerCase();

  // Rate limiting patterns
  if (lowerMessage.includes('rate limit') || lowerMessage.includes('too many requests')) {
    return {
      category: LogErrorCategory.PROVIDER_RATE_LIMIT,
      code: LogErrorCodes.PRATE_429,
      recoverable: false,
      retryable: true,
    };
  }

  // Authentication patterns
  if (lowerMessage.includes('unauthorized') || lowerMessage.includes('invalid api key')) {
    return {
      category: LogErrorCategory.PROVIDER_AUTH,
      code: LogErrorCodes.PAUTH_INVALID,
      recoverable: false,
      retryable: false,
    };
  }

  // Timeout patterns
  if (lowerMessage.includes('timeout') || lowerMessage.includes('timed out')) {
    return {
      category: LogErrorCategory.NETWORK,
      code: LogErrorCodes.NET_TIMEOUT,
      recoverable: false,
      retryable: true,
    };
  }

  // Stream interruption patterns
  if (lowerMessage.includes('stream') && (lowerMessage.includes('error') || lowerMessage.includes('interrupt'))) {
    return {
      category: LogErrorCategory.PROVIDER_STREAM,
      code: LogErrorCodes.PSTRM_INTERRUPTED,
      recoverable: false,
      retryable: true,
    };
  }

  // Overloaded patterns
  if (lowerMessage.includes('overloaded') || lowerMessage.includes('capacity')) {
    return {
      category: LogErrorCategory.PROVIDER_API,
      code: LogErrorCodes.PAPI_OVERLOADED,
      recoverable: false,
      retryable: true,
    };
  }

  return undefined;
}
