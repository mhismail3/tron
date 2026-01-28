/**
 * @fileoverview Mock factories for testing
 *
 * Provides type-safe mock factories to eliminate unsafe `as any` casts in test files.
 *
 * @example
 * ```typescript
 * import { createMockStats, createMockDirent, createFsError } from '../__fixtures__/mocks/index.js';
 *
 * vi.mocked(fs.stat).mockResolvedValue(createMockStats({ size: 1024 }));
 * vi.mocked(fs.readdir).mockResolvedValue([createMockDirent('file.ts')]);
 * ```
 *
 * @example
 * ```typescript
 * import { createMockEventStore, createMockSessionRow } from '../__fixtures__/mocks/index.js';
 *
 * const mockStore = createMockEventStore();
 * vi.mocked(mockStore.getSession).mockResolvedValue(createMockSessionRow());
 * ```
 */

// File system mocks
export {
  createMockStats,
  createMockDirent,
  createFsError,
  createMockDirents,
  type MockStatsOptions,
  type MockDirentOptions,
  type FsErrorCode,
} from './fs.js';

// Event store mocks
export {
  createMockEventStore,
  createMockSessionEvent,
  createMockSessionRow,
  createMockCreateSessionResult,
  createMockForkResult,
  createMockMessage,
  createMockMessageWithEventId,
  type MockEventStoreOptions,
  type MockEventStoreWithTracking,
  type MockSessionEventOptions,
  type MockSessionRowOptions,
  type MockCreateSessionResultOptions,
} from './event-store.js';
