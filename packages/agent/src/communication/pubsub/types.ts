/**
 * @fileoverview Pub/Sub types
 *
 * Types for the publish/subscribe pattern for real-time event distribution.
 */

/**
 * Event published through the pub/sub system
 */
export interface PubSubEvent<T = unknown> {
  /** Event channel/topic */
  channel: string;
  /** Event type */
  type: string;
  /** Event payload */
  data: T;
  /** Publisher session ID */
  publisherId?: string;
  /** When the event was published */
  timestamp: string;
}

/**
 * Subscriber callback function
 */
export type SubscriberCallback<T = unknown> = (event: PubSubEvent<T>) => void | Promise<void>;

/**
 * Subscription handle returned when subscribing
 */
export interface Subscription {
  /** Unique subscription ID */
  id: string;
  /** Channel subscribed to */
  channel: string;
  /** Pattern if using wildcard subscription */
  pattern?: string;
  /** Unsubscribe from this subscription */
  unsubscribe: () => void;
}

/**
 * Channel subscription options
 */
export interface SubscribeOptions {
  /** Optional pattern for wildcard matching (e.g., "session.*") */
  pattern?: string;
  /** Only receive events from specific publisher */
  fromPublisher?: string;
  /** Filter by event types */
  eventTypes?: string[];
}

/**
 * Publisher interface for sending events
 */
export interface Publisher {
  /**
   * Publish an event to a channel
   * @param channel - Channel to publish to
   * @param type - Event type
   * @param data - Event payload
   */
  publish<T>(channel: string, type: string, data: T): Promise<void>;

  /**
   * Publish to multiple channels at once
   */
  publishToMany<T>(channels: string[], type: string, data: T): Promise<void>;
}

/**
 * Subscriber interface for receiving events
 */
export interface Subscriber {
  /**
   * Subscribe to a channel
   * @param channel - Channel to subscribe to
   * @param callback - Callback for received events
   * @param options - Subscription options
   */
  subscribe<T = unknown>(
    channel: string,
    callback: SubscriberCallback<T>,
    options?: SubscribeOptions
  ): Subscription;

  /**
   * Unsubscribe from a specific subscription
   */
  unsubscribe(subscriptionId: string): void;

  /**
   * Unsubscribe from all subscriptions
   */
  unsubscribeAll(): void;

  /**
   * Get active subscriptions
   */
  getSubscriptions(): Subscription[];
}
