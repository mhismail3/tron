/**
 * @fileoverview File Events
 *
 * Events for file read, write, and edit operations.
 */

import type { BaseEvent } from './base.js';

// =============================================================================
// File Events
// =============================================================================

/**
 * File read event
 */
export interface FileReadEvent extends BaseEvent {
  type: 'file.read';
  payload: {
    path: string;
    lines?: { start: number; end: number };
  };
}

/**
 * File write event
 */
export interface FileWriteEvent extends BaseEvent {
  type: 'file.write';
  payload: {
    path: string;
    size: number;
    /** Content hash for deduplication */
    contentHash: string;
  };
}

/**
 * File edit event
 */
export interface FileEditEvent extends BaseEvent {
  type: 'file.edit';
  payload: {
    path: string;
    oldString: string;
    newString: string;
    /** Patch/diff representation */
    diff?: string;
  };
}
