/**
 * @fileoverview Tool Events
 *
 * Events for tool calls and results.
 */

import type { BaseEvent } from './base.js';

// =============================================================================
// Tool Events
// =============================================================================

/**
 * Tool call event
 */
export interface ToolCallEvent extends BaseEvent {
  type: 'tool.call';
  payload: {
    toolCallId: string;
    name: string;
    arguments: Record<string, unknown>;
    turn: number;
  };
}

/**
 * Tool result event
 */
export interface ToolResultEvent extends BaseEvent {
  type: 'tool.result';
  payload: {
    toolCallId: string;
    content: string;
    isError: boolean;
    duration: number; // milliseconds
    /** Files affected (for change tracking) */
    affectedFiles?: string[];
    /** Whether result was truncated */
    truncated?: boolean;
    /** Blob ID containing full content (if truncated) */
    blobId?: string;
  };
}
