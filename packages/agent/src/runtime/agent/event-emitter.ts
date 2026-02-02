/**
 * @fileoverview Agent Event Emitter
 *
 * Manages event listeners and emission for the agent.
 * Provides error isolation so one failing listener doesn't affect others.
 */

import type { TronEvent } from '@core/types/index.js';
import type { EventEmitter as IEventEmitter } from './internal-types.js';
import { createLogger } from '@infrastructure/logging/index.js';

const logger = createLogger('agent:events');

/**
 * Event emitter implementation for agent events
 */
export class AgentEventEmitter implements IEventEmitter {
  private listeners: ((event: TronEvent) => void)[] = [];

  /**
   * Add an event listener
   */
  addListener(listener: (event: TronEvent) => void): void {
    this.listeners.push(listener);
  }

  /**
   * Remove an event listener
   */
  removeListener(listener: (event: TronEvent) => void): void {
    const index = this.listeners.indexOf(listener);
    if (index !== -1) {
      this.listeners.splice(index, 1);
    }
  }

  /**
   * Emit an event to all listeners
   * Errors in listeners are caught and logged to prevent cascading failures
   */
  emit(event: TronEvent): void {
    for (const listener of this.listeners) {
      try {
        listener(event);
      } catch (error) {
        logger.error(
          'Event listener error',
          error instanceof Error ? error : new Error(String(error))
        );
      }
    }
  }

  /**
   * Get the number of registered listeners
   */
  listenerCount(): number {
    return this.listeners.length;
  }

  /**
   * Remove all listeners
   */
  removeAllListeners(): void {
    this.listeners = [];
  }
}

/**
 * Create an event emitter instance
 */
export function createEventEmitter(): AgentEventEmitter {
  return new AgentEventEmitter();
}
