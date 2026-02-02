/**
 * @fileoverview System RPC Types
 *
 * Types for system methods.
 */

// =============================================================================
// System Methods
// =============================================================================

/** Ping */
export interface SystemPingParams {}

export interface SystemPingResult {
  pong: true;
  timestamp: string;
}

/** Get system info */
export interface SystemGetInfoParams {}

export interface SystemGetInfoResult {
  version: string;
  uptime: number;
  activeSessions: number;
  memoryUsage: {
    heapUsed: number;
    heapTotal: number;
  };
}

/** Shutdown */
export interface SystemShutdownParams {
  /** Grace period in ms before force shutdown */
  gracePeriod?: number;
}

export interface SystemShutdownResult {
  acknowledged: boolean;
}
