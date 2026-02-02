/**
 * @fileoverview Metadata Events
 *
 * Events for metadata and tag updates.
 */

import type { BaseEvent } from './base.js';

// =============================================================================
// Metadata Events
// =============================================================================

/**
 * Metadata update event
 */
export interface MetadataUpdateEvent extends BaseEvent {
  type: 'metadata.update';
  payload: {
    key: string;
    previousValue?: unknown;
    newValue: unknown;
  };
}

/**
 * Tag event
 */
export interface MetadataTagEvent extends BaseEvent {
  type: 'metadata.tag';
  payload: {
    action: 'add' | 'remove';
    tag: string;
  };
}
