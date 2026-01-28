/**
 * @fileoverview Centralized test fixtures
 *
 * Provides type-safe mock factories and event fixtures for testing.
 * Import from this file to access all test utilities.
 *
 * @example
 * ```typescript
 * import {
 *   // Mocks
 *   createMockStats,
 *   createMockEventStore,
 *   createMockSessionRow,
 *
 *   // Events
 *   createSessionStartEvent,
 *   createUserMessageEvent,
 *   createBasicConversationChain,
 * } from '../__fixtures__/index.js';
 * ```
 */

// Re-export all mocks
export * from './mocks/index.js';

// Re-export all event fixtures
export * from './events/index.js';
