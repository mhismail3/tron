/**
 * @fileoverview RPC Error Types
 *
 * Provides a typed error hierarchy for RPC handlers, eliminating
 * string-based error detection (e.g., `error.message.includes('not found')`).
 */

/**
 * Centralized RPC error codes
 */
export const RpcErrorCode = {
  // Core
  INVALID_PARAMS: 'INVALID_PARAMS',
  INTERNAL_ERROR: 'INTERNAL_ERROR',
  METHOD_NOT_FOUND: 'METHOD_NOT_FOUND',
  NOT_AVAILABLE: 'NOT_AVAILABLE',
  NOT_FOUND: 'NOT_FOUND',
  INVALID_OPERATION: 'INVALID_OPERATION',
  // Session
  SESSION_NOT_FOUND: 'SESSION_NOT_FOUND',
  SESSION_NOT_ACTIVE: 'SESSION_NOT_ACTIVE',
  MAX_SESSIONS_REACHED: 'MAX_SESSIONS_REACHED',
  // Filesystem
  FILE_NOT_FOUND: 'FILE_NOT_FOUND',
  FILE_ERROR: 'FILE_ERROR',
  FILESYSTEM_ERROR: 'FILESYSTEM_ERROR',
  ALREADY_EXISTS: 'ALREADY_EXISTS',
  INVALID_PATH: 'INVALID_PATH',
  PERMISSION_DENIED: 'PERMISSION_DENIED',
  // Tools & Services
  BROWSER_ERROR: 'BROWSER_ERROR',
  SKILL_ERROR: 'SKILL_ERROR',
  CANVAS_ERROR: 'CANVAS_ERROR',
  TOOL_RESULT_FAILED: 'TOOL_RESULT_FAILED',
  // Media & Communication
  TRANSCRIPTION_ERROR: 'TRANSCRIPTION_ERROR',
  VOICE_NOTE_ERROR: 'VOICE_NOTE_ERROR',
  MESSAGE_ERROR: 'MESSAGE_ERROR',
  // Git
  GIT_ERROR: 'GIT_ERROR',
  // Device
  REGISTRATION_ERROR: 'REGISTRATION_ERROR',
} as const;

export type RpcErrorCodeType = (typeof RpcErrorCode)[keyof typeof RpcErrorCode];

/**
 * Base RPC error class
 */
export class RpcError extends Error {
  readonly name = 'RpcError';

  constructor(
    public readonly code: RpcErrorCodeType,
    message: string
  ) {
    super(message);
  }
}

/**
 * Session not found error
 */
export class SessionNotFoundError extends RpcError {
  constructor(sessionId: string) {
    super(RpcErrorCode.SESSION_NOT_FOUND, `Session not found: ${sessionId}`);
  }
}

/**
 * Session not active error
 */
export class SessionNotActiveError extends RpcError {
  constructor(sessionId: string) {
    super(RpcErrorCode.SESSION_NOT_ACTIVE, `Session is not active: ${sessionId}`);
  }
}

/**
 * Max sessions reached error
 */
export class MaxSessionsReachedError extends RpcError {
  constructor(maxSessions: number) {
    super(RpcErrorCode.MAX_SESSIONS_REACHED,
      `Maximum concurrent sessions (${maxSessions}) reached. Close an existing session or increase the limit in Settings.`);
  }
}

/**
 * Manager not available error
 */
export class ManagerNotAvailableError extends RpcError {
  constructor(managerName: string) {
    super(RpcErrorCode.NOT_AVAILABLE, `${managerName} is not available`);
  }
}

/**
 * Invalid parameters error
 */
export class InvalidParamsError extends RpcError {
  constructor(message: string) {
    super(RpcErrorCode.INVALID_PARAMS, message);
  }
}

/**
 * File not found error
 */
export class FileNotFoundError extends RpcError {
  constructor(path: string) {
    super(RpcErrorCode.FILE_NOT_FOUND, `File not found: ${path}`);
  }
}

/**
 * Internal error
 */
export class InternalError extends RpcError {
  constructor(message: string) {
    super(RpcErrorCode.INTERNAL_ERROR, message);
  }
}

/**
 * Browser error
 */
export class BrowserError extends RpcError {
  constructor(message: string) {
    super(RpcErrorCode.BROWSER_ERROR, message);
  }
}

/**
 * Skill error
 */
export class SkillError extends RpcError {
  constructor(message: string) {
    super(RpcErrorCode.SKILL_ERROR, message);
  }
}

/**
 * File error
 */
export class FileError extends RpcError {
  constructor(message: string) {
    super(RpcErrorCode.FILE_ERROR, message);
  }
}

/**
 * Permission denied error
 */
export class PermissionDeniedError extends RpcError {
  constructor(message: string) {
    super(RpcErrorCode.PERMISSION_DENIED, message);
  }
}

/**
 * Type guard for RpcError
 */
export function isRpcError(error: unknown): error is RpcError {
  return error instanceof RpcError;
}

/**
 * RPC response format
 */
export interface RpcErrorResponse {
  id: string | number;
  success: false;
  error: {
    code: RpcErrorCodeType;
    message: string;
  };
}

/**
 * Convert RpcError to response format
 */
export function toRpcErrorResponse(
  requestId: string | number,
  error: RpcError
): RpcErrorResponse {
  return {
    id: requestId,
    success: false,
    error: {
      code: error.code,
      message: error.message,
    },
  };
}
