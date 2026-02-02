/**
 * @fileoverview Subscriber implementation
 *
 * Subscribes to channels to receive events from publishers.
 */

import { randomUUID } from 'node:crypto';
import { EventEmitter } from 'events';
import type { Subscriber, Subscription, SubscriberCallback, SubscribeOptions, PubSubEvent } from './types.js';
import { getGlobalEventBus } from './publisher.js';
import { createLogger } from '../../logging/index.js';

const logger = createLogger('pubsub-subscriber');

/**
 * Subscriber configuration
 */
export interface SubscriberConfig {
  /** Subscriber identity (session ID) */
  subscriberId: string;
  /** Event emitter for local pub/sub */
  eventBus?: EventEmitter;
}

/**
 * Internal subscription tracking
 */
interface InternalSubscription extends Subscription {
  /** The wrapped callback with filters applied */
  wrappedCallback: (event: PubSubEvent<unknown>) => void;
  /** Original callback */
  callback: SubscriberCallback<unknown>;
  /** Options used for this subscription */
  options?: SubscribeOptions;
}

/**
 * Subscriber implementation for receiving events
 */
export class EventSubscriber implements Subscriber {
  private config: SubscriberConfig;
  private eventBus: EventEmitter;
  private subscriptions: Map<string, InternalSubscription> = new Map();

  constructor(config: SubscriberConfig) {
    this.config = config;
    this.eventBus = config.eventBus ?? getGlobalEventBus();
  }

  /**
   * Subscribe to a channel
   */
  subscribe<T = unknown>(
    channel: string,
    callback: SubscriberCallback<T>,
    options?: SubscribeOptions
  ): Subscription {
    const subscriptionId = randomUUID();

    // Create wrapped callback that applies filters
    const wrappedCallback = (event: PubSubEvent<T>): void => {
      // Apply filters
      if (options?.fromPublisher && event.publisherId !== options.fromPublisher) {
        return;
      }
      if (options?.eventTypes && !options.eventTypes.includes(event.type)) {
        return;
      }

      // If using pattern, check if channel matches
      if (options?.pattern) {
        const regex = new RegExp(`^${options.pattern.replace(/\*/g, '.*')}$`);
        if (!regex.test(event.channel)) {
          return;
        }
      }

      // Call the actual callback
      try {
        const result = callback(event);
        if (result instanceof Promise) {
          result.catch((err) => {
            logger.error('Error in subscriber callback', {
              subscriptionId,
              channel,
              error: err instanceof Error ? err.message : String(err),
            });
          });
        }
      } catch (err) {
        logger.error('Error in subscriber callback', {
          subscriptionId,
          channel,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    };

    // Determine the event name to listen on
    const eventName = options?.pattern ? 'channel:*' : `channel:${channel}`;

    // Register the listener
    this.eventBus.on(eventName, wrappedCallback);

    // Create the subscription object
    const subscription: InternalSubscription = {
      id: subscriptionId,
      channel,
      pattern: options?.pattern,
      unsubscribe: () => this.unsubscribe(subscriptionId),
      wrappedCallback: wrappedCallback as (event: PubSubEvent<unknown>) => void,
      callback: callback as SubscriberCallback<unknown>,
      options,
    };

    this.subscriptions.set(subscriptionId, subscription);

    logger.debug('Created subscription', {
      subscriptionId,
      channel,
      pattern: options?.pattern,
      subscriberId: this.config.subscriberId,
    });

    return {
      id: subscription.id,
      channel: subscription.channel,
      pattern: subscription.pattern,
      unsubscribe: subscription.unsubscribe,
    };
  }

  /**
   * Unsubscribe from a specific subscription
   */
  unsubscribe(subscriptionId: string): void {
    const subscription = this.subscriptions.get(subscriptionId);
    if (!subscription) {
      return;
    }

    // Determine the event name
    const eventName = subscription.options?.pattern
      ? 'channel:*'
      : `channel:${subscription.channel}`;

    // Remove the listener
    this.eventBus.off(eventName, subscription.wrappedCallback);
    this.subscriptions.delete(subscriptionId);

    logger.debug('Removed subscription', {
      subscriptionId,
      channel: subscription.channel,
      subscriberId: this.config.subscriberId,
    });
  }

  /**
   * Unsubscribe from all subscriptions
   */
  unsubscribeAll(): void {
    for (const subscriptionId of this.subscriptions.keys()) {
      this.unsubscribe(subscriptionId);
    }
  }

  /**
   * Get active subscriptions
   */
  getSubscriptions(): Subscription[] {
    return Array.from(this.subscriptions.values()).map((sub) => ({
      id: sub.id,
      channel: sub.channel,
      pattern: sub.pattern,
      unsubscribe: sub.unsubscribe,
    }));
  }
}

/**
 * Create a subscriber instance
 */
export function createSubscriber(config: SubscriberConfig): Subscriber {
  return new EventSubscriber(config);
}
