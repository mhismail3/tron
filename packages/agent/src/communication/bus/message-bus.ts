/**
 * @fileoverview In-memory message bus implementation
 *
 * Provides inter-agent messaging with SQLite persistence support.
 * This implementation uses an in-memory store with optional SQLite backing.
 */

import { randomUUID } from 'crypto';
import { EventEmitter } from 'events';
import type {
  MessageBus,
  MessageBusConfig,
  AgentMessage,
  MessageFilter,
  SessionFilter,
  MessageHandler,
  Unsubscribe,
  StoredMessage,
} from './types.js';
import { createLogger } from '../../logging/index.js';

const logger = createLogger('message-bus');

/**
 * In-memory message bus implementation
 */
export class InMemoryMessageBus extends EventEmitter implements MessageBus {
  private messages = new Map<string, StoredMessage>();
  private sessionMessages = new Map<string, Set<string>>(); // sessionId -> messageIds
  private subscriptions = new Map<string, Set<MessageHandler>>(); // pattern -> handlers
  private config: Required<MessageBusConfig>;

  constructor(config: MessageBusConfig) {
    super();
    this.config = {
      currentSessionId: config.currentSessionId,
      maxMessagesPerSession: config.maxMessagesPerSession ?? 1000,
      retentionMs: config.retentionMs ?? 24 * 60 * 60 * 1000, // 24 hours
    };
  }

  async send(
    targetSessionId: string,
    message: Omit<AgentMessage, 'id' | 'timestamp' | 'fromSessionId' | 'toSessionId'>
  ): Promise<string> {
    const fullMessage: StoredMessage = {
      id: randomUUID(),
      fromSessionId: this.config.currentSessionId,
      toSessionId: targetSessionId,
      type: message.type,
      payload: message.payload,
      timestamp: new Date().toISOString(),
      replyTo: message.replyTo,
      readAt: null,
      createdAt: new Date().toISOString(),
    };

    this.storeMessage(fullMessage);
    this.notifySubscribers(fullMessage);

    logger.debug('Message sent', {
      messageId: fullMessage.id,
      from: fullMessage.fromSessionId,
      to: targetSessionId,
      type: fullMessage.type,
    });

    return fullMessage.id;
  }

  async broadcast(
    message: Omit<AgentMessage, 'id' | 'timestamp' | 'fromSessionId' | 'toSessionId'>,
    filter?: SessionFilter
  ): Promise<void> {
    const fullMessage: StoredMessage = {
      id: randomUUID(),
      fromSessionId: this.config.currentSessionId,
      toSessionId: undefined, // Broadcast
      type: message.type,
      payload: message.payload,
      timestamp: new Date().toISOString(),
      replyTo: message.replyTo,
      readAt: null,
      createdAt: new Date().toISOString(),
    };

    // Store in all active sessions (filtered)
    const targetSessions = this.getTargetSessions(filter);
    for (const sessionId of targetSessions) {
      this.addMessageToSession(sessionId, fullMessage.id);
    }

    this.messages.set(fullMessage.id, fullMessage);
    this.notifySubscribers(fullMessage);

    logger.debug('Message broadcast', {
      messageId: fullMessage.id,
      from: fullMessage.fromSessionId,
      type: fullMessage.type,
      targetCount: targetSessions.length,
    });
  }

  async receive(
    sessionId: string,
    filter?: MessageFilter,
    limit: number = 50
  ): Promise<AgentMessage[]> {
    const messageIds = this.sessionMessages.get(sessionId) ?? new Set();
    const messages: StoredMessage[] = [];

    for (const id of messageIds) {
      const msg = this.messages.get(id);
      if (!msg) continue;

      // Apply filters
      if (filter?.type && msg.type !== filter.type) continue;
      if (filter?.fromSessionId && msg.fromSessionId !== filter.fromSessionId) continue;
      if (filter?.unreadOnly && msg.readAt !== null) continue;
      if (filter?.since && msg.timestamp < filter.since) continue;

      messages.push(msg);
      if (messages.length >= limit) break;
    }

    // Sort by timestamp descending (newest first)
    messages.sort((a, b) => b.timestamp.localeCompare(a.timestamp));

    return messages.slice(0, limit);
  }

  async markAsRead(messageIds: string[]): Promise<void> {
    const now = new Date().toISOString();
    for (const id of messageIds) {
      const msg = this.messages.get(id);
      if (msg) {
        msg.readAt = now;
      }
    }
  }

  subscribe(pattern: string, handler: MessageHandler): Unsubscribe {
    if (!this.subscriptions.has(pattern)) {
      this.subscriptions.set(pattern, new Set());
    }
    this.subscriptions.get(pattern)!.add(handler);

    logger.debug('Subscription added', { pattern });

    return () => {
      const handlers = this.subscriptions.get(pattern);
      if (handlers) {
        handlers.delete(handler);
        if (handlers.size === 0) {
          this.subscriptions.delete(pattern);
        }
      }
    };
  }

  async getUnreadCount(sessionId: string): Promise<number> {
    const messageIds = this.sessionMessages.get(sessionId) ?? new Set();
    let count = 0;

    for (const id of messageIds) {
      const msg = this.messages.get(id);
      if (msg && msg.readAt === null) {
        count++;
      }
    }

    return count;
  }

  /**
   * Update the current session ID (for session switching)
   */
  setCurrentSessionId(sessionId: string): void {
    this.config.currentSessionId = sessionId;
  }

  /**
   * Clean up expired messages
   */
  cleanup(): void {
    const cutoff = new Date(Date.now() - this.config.retentionMs).toISOString();
    let removed = 0;

    for (const [id, msg] of this.messages) {
      if (msg.createdAt < cutoff) {
        this.messages.delete(id);
        removed++;

        // Remove from session indices
        for (const sessionMsgs of this.sessionMessages.values()) {
          sessionMsgs.delete(id);
        }
      }
    }

    if (removed > 0) {
      logger.debug('Cleaned up expired messages', { removed });
    }
  }

  /**
   * Clear all messages (for testing)
   */
  clear(): void {
    this.messages.clear();
    this.sessionMessages.clear();
  }

  // Private helpers

  private storeMessage(message: StoredMessage): void {
    this.messages.set(message.id, message);

    if (message.toSessionId) {
      this.addMessageToSession(message.toSessionId, message.id);
    }

    // Enforce per-session limit
    this.enforceSessionLimit(message.toSessionId ?? message.fromSessionId);
  }

  private addMessageToSession(sessionId: string, messageId: string): void {
    if (!this.sessionMessages.has(sessionId)) {
      this.sessionMessages.set(sessionId, new Set());
    }
    this.sessionMessages.get(sessionId)!.add(messageId);
  }

  private enforceSessionLimit(sessionId: string): void {
    const messageIds = this.sessionMessages.get(sessionId);
    if (!messageIds || messageIds.size <= this.config.maxMessagesPerSession) {
      return;
    }

    // Get messages sorted by timestamp
    const messages = Array.from(messageIds)
      .map((id) => this.messages.get(id))
      .filter((m): m is StoredMessage => m !== undefined)
      .sort((a, b) => a.timestamp.localeCompare(b.timestamp));

    // Remove oldest messages
    const toRemove = messages.slice(0, messages.length - this.config.maxMessagesPerSession);
    for (const msg of toRemove) {
      messageIds.delete(msg.id);
      this.messages.delete(msg.id);
    }
  }

  private getTargetSessions(filter?: SessionFilter): string[] {
    // In a real implementation, this would query active sessions
    // For now, return all known sessions except excluded ones
    const sessions = Array.from(this.sessionMessages.keys());
    const excludeSet = new Set(filter?.excludeSessionIds ?? []);
    excludeSet.add(this.config.currentSessionId); // Don't broadcast to self

    return sessions.filter((s) => !excludeSet.has(s));
  }

  private notifySubscribers(message: AgentMessage): void {
    for (const [pattern, handlers] of this.subscriptions) {
      if (this.matchesPattern(message.type, pattern)) {
        for (const handler of handlers) {
          try {
            handler(message);
          } catch (error) {
            logger.error('Subscription handler error', { pattern, error });
          }
        }
      }
    }
  }

  private matchesPattern(type: string, pattern: string): boolean {
    if (pattern === '*') return true;
    if (pattern.endsWith('.*')) {
      const prefix = pattern.slice(0, -2);
      return type.startsWith(prefix + '.') || type === prefix;
    }
    return type === pattern;
  }
}

/**
 * Create a new message bus instance
 */
export function createMessageBus(config: MessageBusConfig): MessageBus {
  return new InMemoryMessageBus(config);
}
