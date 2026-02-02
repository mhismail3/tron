/**
 * @fileoverview Message Operation Events
 *
 * Events for message modifications like deletion.
 */

import type { EventId } from './branded.js';
import type { BaseEvent } from './base.js';

// =============================================================================
// Message Operations Events
// =============================================================================

/**
 * Message deleted event - soft-deletes a message from context reconstruction
 * The original message event is preserved; this event marks it as deleted.
 * Two-pass reconstruction filters out deleted messages.
 */
export interface MessageDeletedEvent extends BaseEvent {
  type: 'message.deleted';
  payload: {
    /** Event ID of the message being deleted */
    targetEventId: EventId;
    /** Original event type (for validation) */
    targetType: 'message.user' | 'message.assistant' | 'tool.result';
    /** Turn number of deleted message */
    targetTurn?: number;
    /** Reason for deletion */
    reason?: 'user_request' | 'content_policy' | 'context_management';
  };
}
