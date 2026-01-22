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
