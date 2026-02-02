/**
 * @fileoverview Message Store
 *
 * Handles message storage and token caching for context management.
 * Extracted from ContextManager to provide focused message operations.
 */

import type { Message } from '@core/types/index.js';
import { estimateMessageTokens } from './token-estimator.js';

// =============================================================================
// Types
// =============================================================================

export interface MessageStoreConfig {
  /** Initial messages to populate the store */
  initialMessages?: Message[];
}

// =============================================================================
// MessageStore
// =============================================================================

/**
 * Manages message storage with token caching.
 *
 * Responsibilities:
 * - Store and retrieve messages
 * - Cache token estimates per message
 * - Provide total token count for all messages
 */
export class MessageStore {
  private messages: Message[] = [];
  private tokenCache: WeakMap<Message, number> = new WeakMap();

  constructor(config?: MessageStoreConfig) {
    if (config?.initialMessages) {
      this.set(config.initialMessages);
    }
  }

  /**
   * Add a message to the store.
   * Token estimate is computed and cached immediately.
   */
  add(message: Message): void {
    this.messages.push(message);
    this.tokenCache.set(message, estimateMessageTokens(message));
  }

  /**
   * Replace all messages in the store.
   * Token cache is rebuilt for new messages.
   */
  set(messages: Message[]): void {
    this.messages = [...messages];
    for (const msg of this.messages) {
      this.tokenCache.set(msg, estimateMessageTokens(msg));
    }
  }

  /**
   * Get all messages (defensive copy).
   */
  get(): Message[] {
    return [...this.messages];
  }

  /**
   * Clear all messages from the store.
   */
  clear(): void {
    this.messages = [];
  }

  /**
   * Get total token count for all messages.
   * Uses cached values for efficiency.
   */
  getTokens(): number {
    let total = 0;
    for (const msg of this.messages) {
      total += this.tokenCache.get(msg) ?? estimateMessageTokens(msg);
    }
    return total;
  }

  /**
   * Get cached token count for a specific message.
   * Returns undefined if message is not in cache.
   */
  getCachedTokens(message: Message): number | undefined {
    return this.tokenCache.get(message);
  }

  /**
   * Get current message count.
   */
  get length(): number {
    return this.messages.length;
  }
}

// =============================================================================
// Factory
// =============================================================================

/**
 * Create a new MessageStore instance.
 */
export function createMessageStore(config?: MessageStoreConfig): MessageStore {
  return new MessageStore(config);
}
