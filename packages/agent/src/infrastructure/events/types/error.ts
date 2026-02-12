/**
 * @fileoverview Error Events
 *
 * Events for agent, tool, and provider errors.
 */

import type { BaseEvent } from './base.js';

// =============================================================================
// Error Events
// =============================================================================

/**
 * Agent error event
 */
export interface ErrorAgentEvent extends BaseEvent {
  type: 'error.agent';
  payload: {
    error: string;
    code?: string;
    recoverable: boolean;
  };
}

/**
 * Tool error event
 */
export interface ErrorToolEvent extends BaseEvent {
  type: 'error.tool';
  payload: {
    toolName: string;
    toolCallId: string;
    error: string;
    code?: string;
  };
}

/**
 * Provider error event
 */
export interface ErrorProviderEvent extends BaseEvent {
  type: 'error.provider';
  payload: {
    provider: string;
    error: string;
    code?: string;
    category?: string;
    suggestion?: string;
    retryable: boolean;
    retryAfter?: number;
  };
}
