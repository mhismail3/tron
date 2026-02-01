/**
 * @fileoverview Communication tool types
 *
 * Types for inter-agent communication tools.
 */

/**
 * Parameters for send_message tool
 */
export interface SendMessageParams {
  /** Target session ID to send the message to */
  targetSessionId: string;
  /** Type of message for routing/handling */
  messageType: string;
  /** Message payload */
  payload: unknown;
  /** Whether to wait for a reply */
  waitForReply?: boolean;
  /** Timeout in milliseconds when waiting for reply */
  timeout?: number;
}

/**
 * Result of send_message tool
 */
export interface SendMessageResult {
  /** Whether the message was sent successfully */
  success: boolean;
  /** The message ID */
  messageId: string;
  /** Reply message if waitForReply was true and a reply was received */
  reply?: {
    messageId: string;
    payload: unknown;
  };
  /** Error message if failed */
  error?: string;
}

/**
 * Parameters for receive_messages tool
 */
export interface ReceiveMessagesParams {
  /** Optional filter for message type */
  type?: string;
  /** Optional filter for sender session */
  fromSessionId?: string;
  /** Maximum number of messages to return */
  limit?: number;
  /** Whether to mark messages as read */
  markAsRead?: boolean;
}

/**
 * A message in the receive result
 */
export interface ReceivedMessage {
  /** Message ID */
  id: string;
  /** Sender session ID */
  fromSessionId: string;
  /** Message type */
  type: string;
  /** Message payload */
  payload: unknown;
  /** When the message was sent */
  timestamp: string;
  /** ID of the message this is replying to */
  replyTo?: string;
}

/**
 * Result of receive_messages tool
 */
export interface ReceiveMessagesResult {
  /** The received messages */
  messages: ReceivedMessage[];
  /** Total unread count (may be higher than returned messages) */
  unreadCount: number;
}
