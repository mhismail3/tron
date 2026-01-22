/**
 * @fileoverview Message Queue
 *
 * Queue for holding user messages during streaming responses.
 * When the agent is generating a response, typed messages are
 * queued and processed after the current turn completes.
 */

export class MessageQueue {
  private queue: string[] = [];

  /**
   * Add a message to the queue
   * Empty or whitespace-only messages are ignored
   */
  add(message: string): void {
    const trimmed = message.trim();
    if (trimmed) {
      this.queue.push(trimmed);
    }
  }

  /**
   * Check if there are queued messages
   */
  hasMessages(): boolean {
    return this.queue.length > 0;
  }

  /**
   * Get the number of queued messages
   */
  size(): number {
    return this.queue.length;
  }

  /**
   * Remove and return the next message (FIFO)
   */
  pop(): string | undefined {
    return this.queue.shift();
  }

  /**
   * View the next message without removing it
   */
  peek(): string | undefined {
    return this.queue[0];
  }

  /**
   * Clear all queued messages
   */
  clear(): void {
    this.queue = [];
  }

  /**
   * Get all messages and clear the queue
   */
  getAll(): string[] {
    const messages = [...this.queue];
    this.queue = [];
    return messages;
  }
}
