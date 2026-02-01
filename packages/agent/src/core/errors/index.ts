/**
 * @fileoverview Error types and handling utilities
 *
 * Provides:
 * - Standardized error codes
 * - Error categorization
 * - Error boundary utilities
 *
 * @migration This consolidates error handling from various modules.
 */

// Re-export logging error utilities during migration
export {
  categorizeError,
  LogErrorCategory,
  type StructuredError,
} from '../../logging/index.js';

// Error codes used across the system
export const ErrorCodes = {
  // General
  INTERNAL_ERROR: 'INTERNAL_ERROR',
  INVALID_PARAMS: 'INVALID_PARAMS',
  NOT_FOUND: 'NOT_FOUND',
  UNAUTHORIZED: 'UNAUTHORIZED',

  // Session
  SESSION_NOT_FOUND: 'SESSION_NOT_FOUND',
  SESSION_BUSY: 'SESSION_BUSY',
  SESSION_ENDED: 'SESSION_ENDED',

  // Agent
  AGENT_NOT_RUNNING: 'AGENT_NOT_RUNNING',
  AGENT_ALREADY_RUNNING: 'AGENT_ALREADY_RUNNING',
  AGENT_ABORTED: 'AGENT_ABORTED',

  // Tool
  TOOL_NOT_FOUND: 'TOOL_NOT_FOUND',
  TOOL_EXECUTION_FAILED: 'TOOL_EXECUTION_FAILED',
  TOOL_TIMEOUT: 'TOOL_TIMEOUT',

  // Provider
  PROVIDER_ERROR: 'PROVIDER_ERROR',
  RATE_LIMITED: 'RATE_LIMITED',
  CONTEXT_LENGTH_EXCEEDED: 'CONTEXT_LENGTH_EXCEEDED',

  // Network
  CONNECTION_FAILED: 'CONNECTION_FAILED',
  TIMEOUT: 'TIMEOUT',
} as const;

export type ErrorCode = (typeof ErrorCodes)[keyof typeof ErrorCodes];
