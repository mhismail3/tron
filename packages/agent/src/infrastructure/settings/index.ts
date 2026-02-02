/**
 * @fileoverview Settings Module
 *
 * Centralized configuration system for Tron.
 * Settings are loaded from ~/.tron/settings.json with sensible defaults.
 * Also includes feature flags system for controlling availability of features.
 *
 * @example
 * ```typescript
 * import { getSettings, getSetting } from '../index.js';
 *
 * // Get all settings
 * const settings = getSettings();
 * console.log(settings.models.default);
 *
 * // Get specific setting by path
 * const timeout = getSetting<number>('tools.bash.defaultTimeoutMs');
 * ```
 */

// Re-export feature flags
export * from './feature-flags.js';

// Re-export types
export type {
  TronSettings,
  UserSettings,
  DeepPartial,
  ApiSettings,
  AnthropicApiSettings,
  ModelSettings,
  RetrySettings,
  ToolSettings,
  BashToolSettings,
  ReadToolSettings,
  FindToolSettings,
  SearchToolSettings,
  ContextSettings,
  CompactorSettings,
  MemorySettings,
  HookSettings,
  ServerSettings,
  TmuxSettings,
  SessionSettings,
  UiSettings,
  PaletteSettings,
  IconSettings,
  ThinkingAnimationSettings,
  InputSettings,
  MenuSettings,
} from './types.js';

// Re-export defaults
export {
  DEFAULT_SETTINGS,
  DEFAULT_DANGEROUS_PATTERNS,
  DEFAULT_BINARY_EXTENSIONS,
  DEFAULT_SKIP_DIRECTORIES,
  getDefault,
} from './defaults.js';

// Re-export loader functions
export {
  // Async functions (preferred for startup)
  preloadSettings,
  loadSettingsAsync,
  loadUserSettingsAsync,
  reloadSettingsAsync,
  // Sync functions (backwards compatibility)
  getSettings,
  getSetting,
  reloadSettings,
  loadSettings,
  loadUserSettings,
  saveSettings,
  getSettingsPath,
  getSettingsDir,
  setSettingsPath,
  clearSettingsCache,
  generateDefaultSettingsFile,
  applyEnvOverrides,
  getSettingsWithEnv,
  // Path resolution utilities
  resolveTronPath,
  getTronDataDir,
} from './loader.js';
