/**
 * @fileoverview Settings Provider Interface
 *
 * Provides dependency injection abstraction for settings access.
 * Replaces direct getSettings() calls to enable:
 * - Better testability (mock settings in tests)
 * - Explicit dependency declaration
 * - Potential for per-session settings overrides
 *
 * Migration path:
 * 1. Create provider at app startup
 * 2. Pass to functions/classes that need settings
 * 3. Gradually replace getSettings() calls
 */

import type { TronSettings } from '../settings/types.js';

/**
 * Interface for providing settings access.
 *
 * Implementations can provide settings from:
 * - File-based config (production)
 * - In-memory overrides (testing)
 * - Per-session customization (future)
 */
export interface SettingsProvider {
  /**
   * Get a specific settings section.
   * @param key - Top-level settings key
   * @returns The settings value for that key
   */
  get<K extends keyof TronSettings>(key: K): TronSettings[K];

  /**
   * Get all settings.
   * @returns Complete settings object
   */
  getAll(): TronSettings;

  /**
   * Get a nested setting by dot-separated path.
   * @param path - Dot-separated path (e.g., 'tools.bash.defaultTimeoutMs')
   * @returns The setting value or undefined if not found
   */
  getSetting<T>(path: string): T | undefined;
}

/**
 * Default settings provider using the singleton loader.
 *
 * This wraps the existing getSettings() function to provide
 * the SettingsProvider interface while maintaining backwards
 * compatibility with existing code.
 */
export class DefaultSettingsProvider implements SettingsProvider {
  private readonly settings: TronSettings;

  /**
   * Create a DefaultSettingsProvider.
   * @param settings - Settings object (usually from getSettings())
   */
  constructor(settings: TronSettings) {
    this.settings = settings;
  }

  get<K extends keyof TronSettings>(key: K): TronSettings[K] {
    return this.settings[key];
  }

  getAll(): TronSettings {
    return this.settings;
  }

  getSetting<T>(path: string): T | undefined {
    const parts = path.split('.');
    let current: unknown = this.settings;

    for (const part of parts) {
      if (current && typeof current === 'object' && part in current) {
        current = (current as Record<string, unknown>)[part];
      } else {
        return undefined;
      }
    }

    return current as T;
  }
}

/**
 * Mock settings provider for testing.
 *
 * Allows tests to provide custom settings without touching
 * the global singleton or file system.
 */
export class MockSettingsProvider implements SettingsProvider {
  private settings: TronSettings;

  /**
   * Create a MockSettingsProvider with custom settings.
   * @param settings - Complete or partial settings (merged with defaults)
   */
  constructor(settings: TronSettings) {
    this.settings = settings;
  }

  get<K extends keyof TronSettings>(key: K): TronSettings[K] {
    return this.settings[key];
  }

  getAll(): TronSettings {
    return this.settings;
  }

  getSetting<T>(path: string): T | undefined {
    const parts = path.split('.');
    let current: unknown = this.settings;

    for (const part of parts) {
      if (current && typeof current === 'object' && part in current) {
        current = (current as Record<string, unknown>)[part];
      } else {
        return undefined;
      }
    }

    return current as T;
  }

  /**
   * Override a specific setting for testing.
   * @param path - Dot-separated path
   * @param value - Value to set
   */
  override<T>(path: string, value: T): void {
    const parts = path.split('.');
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let current: Record<string, any> = this.settings as unknown as Record<string, any>;

    for (let i = 0; i < parts.length - 1; i++) {
      const part = parts[i]!;
      if (!(part in current) || typeof current[part] !== 'object') {
        current[part] = {};
      }
      current = current[part] as Record<string, unknown>;
    }

    const lastPart = parts[parts.length - 1]!;
    current[lastPart] = value;
  }
}

/**
 * Create a SettingsProvider from the current settings.
 *
 * Usage at app startup:
 * ```typescript
 * import { getSettings } from './settings/index.js';
 * import { createSettingsProvider } from './di/settings-provider.js';
 *
 * const settingsProvider = createSettingsProvider(getSettings());
 * // Pass to components that need settings
 * ```
 */
export function createSettingsProvider(settings: TronSettings): SettingsProvider {
  return new DefaultSettingsProvider(settings);
}
