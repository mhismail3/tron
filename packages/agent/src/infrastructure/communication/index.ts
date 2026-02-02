/**
 * @fileoverview Inter-agent communication module
 *
 * Provides infrastructure for agent-to-agent messaging:
 * - Message bus for routing messages between sessions
 * - Pub/sub for event-driven communication
 *
 * @example
 * ```typescript
 * import { createMessageBus } from '@tron/agent/communication';
 *
 * const bus = createMessageBus({ currentSessionId: 'session-1' });
 *
 * // Send a message to another session
 * await bus.send('session-2', {
 *   type: 'task.assigned',
 *   payload: { taskId: 'task-1', description: 'Review PR #123' }
 * });
 *
 * // Subscribe to messages
 * const unsubscribe = bus.subscribe('task.*', (message) => {
 *   console.log('Received task message:', message);
 * });
 * ```
 */

export * from './bus/index.js';
export * from './pubsub/index.js';
