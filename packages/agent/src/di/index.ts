/**
 * @fileoverview Dependency Injection Module
 *
 * Provides dependency injection abstractions for:
 * - Settings access
 * - (Future) Service locator patterns
 * - (Future) Context providers
 *
 * These abstractions improve testability and make dependencies explicit.
 */

export {
  type SettingsProvider,
  DefaultSettingsProvider,
  MockSettingsProvider,
  createSettingsProvider,
} from './settings-provider.js';
