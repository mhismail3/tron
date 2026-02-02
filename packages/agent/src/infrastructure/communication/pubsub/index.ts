/**
 * @fileoverview Pub/Sub module index
 *
 * Provides publish/subscribe functionality for event distribution.
 */

export type {
  PubSubEvent,
  SubscriberCallback,
  Subscription,
  SubscribeOptions,
  Publisher,
  Subscriber,
} from './types.js';

export { EventPublisher, createPublisher, getGlobalEventBus, type PublisherConfig } from './publisher.js';
export { EventSubscriber, createSubscriber, type SubscriberConfig } from './subscriber.js';
