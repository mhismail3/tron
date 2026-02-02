/**
 * @fileoverview Inter-agent message bus types
 *
 * Provides types for agent-to-agent messaging within the Tron system.
 */

/**
 * Message sent between agents
 */
export interface AgentMessage {
  /** Unique message ID */
  id: string;
  /** Session ID of the sender */
  fromSessionId: string;
  /** Session ID of the recipient (undefined = broadcast) */
  toSessionId?: string;
  /** Message type for routing */
  type: string;
  /** Message payload */
  payload: unknown;
  /** When the message was sent */
  timestamp: string;
  /** Reference to a message this is replying to */
  replyTo?: string;
}

/**
 * Filter for querying messages
 */
export interface MessageFilter {
  /** Filter by message type */
  type?: string;
  /** Filter by sender session */
  fromSessionId?: string;
  /** Only include unread messages */
  unreadOnly?: boolean;
  /** Minimum timestamp */
  since?: string;
}

/**
 * Filter for session matching in broadcasts
 */
export interface SessionFilter {
  /** Filter by workspace ID */
  workspaceId?: string;
  /** Filter by session status */
  status?: 'active' | 'idle' | 'any';
  /** Exclude specific session IDs */
  excludeSessionIds?: string[];
}

/**
 * Handler for incoming messages
 */
export type MessageHandler = (message: AgentMessage) => void | Promise<void>;

/**
 * Unsubscribe function returned by subscribe
 */
export type Unsubscribe = () => void;

/**
 * Message bus interface for inter-agent communication
 */
export interface MessageBus {
  /**
   * Send a message to a specific session
   * @param targetSessionId - The recipient session
   * @param message - The message to send (without id, timestamp, fromSessionId)
   */
  send(
    targetSessionId: string,
    message: Omit<AgentMessage, 'id' | 'timestamp' | 'fromSessionId' | 'toSessionId'>
  ): Promise<string>;

  /**
   * Broadcast a message to multiple sessions
   * @param message - The message to broadcast
   * @param filter - Optional filter for target sessions
   */
  broadcast(
    message: Omit<AgentMessage, 'id' | 'timestamp' | 'fromSessionId' | 'toSessionId'>,
    filter?: SessionFilter
  ): Promise<void>;

  /**
   * Receive messages for a session
   * @param sessionId - The session to get messages for
   * @param filter - Optional filter
   * @param limit - Maximum messages to return
   */
  receive(sessionId: string, filter?: MessageFilter, limit?: number): Promise<AgentMessage[]>;

  /**
   * Mark messages as read
   * @param messageIds - Messages to mark as read
   */
  markAsRead(messageIds: string[]): Promise<void>;

  /**
   * Subscribe to messages matching a pattern
   * @param pattern - Message type pattern (supports * wildcard)
   * @param handler - Callback for matching messages
   * @returns Unsubscribe function
   */
  subscribe(pattern: string, handler: MessageHandler): Unsubscribe;

  /**
   * Get unread message count for a session
   */
  getUnreadCount(sessionId: string): Promise<number>;
}

/**
 * Configuration for the message bus
 */
export interface MessageBusConfig {
  /** Current session ID (sender identity) */
  currentSessionId: string;
  /** Maximum messages to store per session */
  maxMessagesPerSession?: number;
  /** How long to retain messages (ms) */
  retentionMs?: number;
}

/**
 * Message stored in the database
 */
export interface StoredMessage extends AgentMessage {
  /** When the message was read (null if unread) */
  readAt: string | null;
  /** When the message was created in the store */
  createdAt: string;
}
