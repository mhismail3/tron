/**
 * @fileoverview Compaction Events
 *
 * Events for context compaction and summarization.
 */

import type { EventId } from './branded.js';
import type { BaseEvent } from './base.js';

// =============================================================================
// Compaction Events
// =============================================================================

/**
 * Compaction boundary - marks where context was summarized
 */
export interface CompactBoundaryEvent extends BaseEvent {
  type: 'compact.boundary';
  payload: {
    /** Events being summarized (from, to) */
    range: { from: EventId; to: EventId };
    /** Token count before compaction */
    originalTokens: number;
    /** Token count after compaction */
    compactedTokens: number;
  };
}

/**
 * Compaction summary - the actual summarized content
 */
export interface CompactSummaryEvent extends BaseEvent {
  type: 'compact.summary';
  payload: {
    summary: string;
    keyDecisions?: string[];
    filesModified?: string[];
    /** Link to boundary event */
    boundaryEventId: EventId;
  };
}
