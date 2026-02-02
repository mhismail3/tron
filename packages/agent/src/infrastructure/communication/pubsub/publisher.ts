/**
 * @fileoverview Publisher implementation
 *
 * Publishes events to channels for distribution to subscribers.
 */

import { EventEmitter } from 'events';
import type { Publisher, PubSubEvent } from './types.js';
import { createLogger } from '../../logging/index.js';

const logger = createLogger('pubsub-publisher');

/**
 * Publisher configuration
 */
export interface PublisherConfig {
  /** Publisher identity (session ID) */
  publisherId: string;
  /** Event emitter for local pub/sub */
  eventBus?: EventEmitter;
}

/**
 * Default event bus for local pub/sub
 */
let globalEventBus: EventEmitter | null = null;

/**
 * Get or create the global event bus
 */
export function getGlobalEventBus(): EventEmitter {
  if (!globalEventBus) {
    globalEventBus = new EventEmitter();
    globalEventBus.setMaxListeners(1000); // Support many subscribers
  }
  return globalEventBus;
}

/**
 * Publisher implementation for event distribution
 */
export class EventPublisher implements Publisher {
  private config: PublisherConfig;
  private eventBus: EventEmitter;

  constructor(config: PublisherConfig) {
    this.config = config;
    this.eventBus = config.eventBus ?? getGlobalEventBus();
  }

  /**
   * Publish an event to a channel
   */
  async publish<T>(channel: string, type: string, data: T): Promise<void> {
    const event: PubSubEvent<T> = {
      channel,
      type,
      data,
      publisherId: this.config.publisherId,
      timestamp: new Date().toISOString(),
    };

    logger.debug('Publishing event', {
      channel,
      type,
      publisherId: this.config.publisherId,
    });

    // Emit to the specific channel
    this.eventBus.emit(`channel:${channel}`, event);

    // Emit to wildcard listeners (e.g., channel:* matches all)
    this.eventBus.emit('channel:*', event);
  }

  /**
   * Publish to multiple channels at once
   */
  async publishToMany<T>(channels: string[], type: string, data: T): Promise<void> {
    await Promise.all(channels.map((channel) => this.publish(channel, type, data)));
  }
}

/**
 * Create a publisher instance
 */
export function createPublisher(config: PublisherConfig): Publisher {
  return new EventPublisher(config);
}
