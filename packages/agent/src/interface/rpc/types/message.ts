/**
 * @fileoverview Message RPC Types
 *
 * Types for message operations methods.
 */

// =============================================================================
// Message Methods
// =============================================================================

/** Delete a message from a session */
export interface MessageDeleteParams {
  /** Session ID containing the message */
  sessionId: string;
  /** Event ID of the message to delete (must be message.user or message.assistant) */
  targetEventId: string;
  /** Reason for deletion (optional) */
  reason?: 'user_request' | 'content_policy' | 'context_management';
}

export interface MessageDeleteResult {
  /** Whether the deletion was successful */
  success: boolean;
  /** The event ID of the message.deleted event */
  deletionEventId: string;
  /** Type of event that was deleted */
  targetType: 'message.user' | 'message.assistant' | 'tool.result';
}
