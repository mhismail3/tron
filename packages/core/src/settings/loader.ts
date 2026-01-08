/**
 * @fileoverview Settings Loader
 *
 * Loads and merges user settings from ~/.tron/settings.json with defaults.
 * Provides a singleton pattern for accessing settings throughout the app.
 *
 * PERFORMANCE NOTES:
 * - Settings are cached after first load for fast subsequent access
 * - Use preloadSettings() at app startup for eager loading
 * - Async methods available for non-blocking I/O
 */

import * as fs from 'fs';
import * as fsAsync from 'fs/promises';
import * as path from 'path';
import * as os from 'os';
import type { TronSettings, UserSettings, DeepPartial } from './types.js';
import { DEFAULT_SETTINGS } from './defaults.js';

// =============================================================================
// Constants
// =============================================================================

/** Default settings file location */
const SETTINGS_DIR = '.tron';
const SETTINGS_FILE = 'settings.json';

// =============================================================================
// Merge Utilities
// =============================================================================

/**
 * Deep merge two objects, with source taking precedence
 * Arrays are replaced entirely, not merged
 */
function deepMerge<T extends object>(target: T, source: DeepPartial<T>): T {
  const result = { ...target };

  for (const key in source) {
    if (Object.prototype.hasOwnProperty.call(source, key)) {
      const sourceValue = source[key];
      const targetValue = target[key];

      if (
        sourceValue !== undefined &&
        sourceValue !== null &&
        typeof sourceValue === 'object' &&
        !Array.isArray(sourceValue) &&
        targetValue !== undefined &&
        typeof targetValue === 'object' &&
        !Array.isArray(targetValue)
      ) {
        // Recursively merge objects
        (result as Record<string, unknown>)[key] = deepMerge(
          targetValue as object,
          sourceValue as DeepPartial<typeof targetValue>
        );
      } else if (sourceValue !== undefined) {
        // Replace value (including arrays)
        (result as Record<string, unknown>)[key] = sourceValue;
      }
    }
  }

  return result;
}

// =============================================================================
// Settings Loading
// =============================================================================

/**
 * Get the path to the settings file
 */
export function getSettingsPath(homeDir?: string): string {
  const home = homeDir ?? os.homedir();
  return path.join(home, SETTINGS_DIR, SETTINGS_FILE);
}

/**
 * Get the path to the settings directory
 */
export function getSettingsDir(homeDir?: string): string {
  const home = homeDir ?? os.homedir();
  return path.join(home, SETTINGS_DIR);
}

/**
 * Load user settings from file (synchronous - prefer async version)
 * @param settingsPath - Optional custom path to settings file
 * @returns User settings or null if file doesn't exist
 */
export function loadUserSettings(settingsPath?: string): UserSettings | null {
  const filePath = settingsPath ?? getSettingsPath();

  try {
    if (!fs.existsSync(filePath)) {
      return null;
    }

    const content = fs.readFileSync(filePath, 'utf-8');
    const parsed = JSON.parse(content) as UserSettings;
    return parsed;
  } catch (error) {
    // Log warning but don't fail - use defaults
    console.warn(`Failed to load settings from ${filePath}:`, error);
    return null;
  }
}

/**
 * Load user settings from file (async - preferred for startup)
 * @param settingsPath - Optional custom path to settings file
 * @returns User settings or null if file doesn't exist
 */
export async function loadUserSettingsAsync(settingsPath?: string): Promise<UserSettings | null> {
  const filePath = settingsPath ?? getSettingsPath();

  try {
    const content = await fsAsync.readFile(filePath, 'utf-8');
    const parsed = JSON.parse(content) as UserSettings;
    return parsed;
  } catch (error) {
    // ENOENT is expected if file doesn't exist - not an error
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      return null;
    }
    // Log warning but don't fail - use defaults
    console.warn(`Failed to load settings from ${filePath}:`, error);
    return null;
  }
}

/**
 * Load and merge settings with defaults (synchronous)
 * @param settingsPath - Optional custom path to settings file
 * @returns Complete merged settings
 */
export function loadSettings(settingsPath?: string): TronSettings {
  const userSettings = loadUserSettings(settingsPath);

  if (!userSettings) {
    return { ...DEFAULT_SETTINGS };
  }

  return deepMerge(DEFAULT_SETTINGS, userSettings);
}

/**
 * Load and merge settings with defaults (async - preferred for startup)
 * @param settingsPath - Optional custom path to settings file
 * @returns Complete merged settings
 */
export async function loadSettingsAsync(settingsPath?: string): Promise<TronSettings> {
  const userSettings = await loadUserSettingsAsync(settingsPath);

  if (!userSettings) {
    return { ...DEFAULT_SETTINGS };
  }

  return deepMerge(DEFAULT_SETTINGS, userSettings);
}

/**
 * Save settings to file
 * @param settings - Settings to save (can be partial)
 * @param settingsPath - Optional custom path to settings file
 */
export function saveSettings(
  settings: UserSettings,
  settingsPath?: string
): void {
  const filePath = settingsPath ?? getSettingsPath();
  const dirPath = path.dirname(filePath);

  // Ensure directory exists
  if (!fs.existsSync(dirPath)) {
    fs.mkdirSync(dirPath, { recursive: true });
  }

  const content = JSON.stringify(settings, null, 2);
  fs.writeFileSync(filePath, content, 'utf-8');
}

/**
 * Generate a default settings file with all options documented
 * @param settingsPath - Optional custom path to settings file
 */
export function generateDefaultSettingsFile(settingsPath?: string): void {
  const filePath = settingsPath ?? getSettingsPath();
  saveSettings(DEFAULT_SETTINGS, filePath);
}

// =============================================================================
// Singleton Settings Instance
// =============================================================================

/** Cached settings instance */
let cachedSettings: TronSettings | null = null;

/** Custom settings path (for testing) */
let customSettingsPath: string | undefined;

/** Promise for async preloading (prevents duplicate loads) */
let preloadPromise: Promise<TronSettings> | null = null;

/**
 * Preload settings asynchronously (call at app startup)
 * This is the preferred way to initialize settings as it doesn't block.
 * Subsequent calls to getSettings() will return the cached result instantly.
 *
 * @returns Promise resolving to the loaded settings
 */
export async function preloadSettings(): Promise<TronSettings> {
  // Return cached if already loaded
  if (cachedSettings) {
    return cachedSettings;
  }

  // Return existing promise if load is in progress
  if (preloadPromise) {
    return preloadPromise;
  }

  // Start async load
  preloadPromise = loadSettingsAsync(customSettingsPath).then(settings => {
    cachedSettings = settings;
    preloadPromise = null;
    return settings;
  });

  return preloadPromise;
}

/**
 * Get the current settings (loads and caches on first call)
 * NOTE: Prefer preloadSettings() at startup to avoid blocking.
 * This sync version is kept for backwards compatibility.
 */
export function getSettings(): TronSettings {
  if (!cachedSettings) {
    cachedSettings = loadSettings(customSettingsPath);
  }
  return cachedSettings;
}

/**
 * Reload settings from disk (async version - preferred)
 */
export async function reloadSettingsAsync(): Promise<TronSettings> {
  cachedSettings = await loadSettingsAsync(customSettingsPath);
  return cachedSettings;
}

/**
 * Reload settings from disk (sync version - for backwards compatibility)
 */
export function reloadSettings(): TronSettings {
  cachedSettings = loadSettings(customSettingsPath);
  return cachedSettings;
}

/**
 * Set a custom settings path (mainly for testing)
 * Also clears the cache to force reload
 */
export function setSettingsPath(path: string | undefined): void {
  customSettingsPath = path;
  cachedSettings = null;
  preloadPromise = null;
}

/**
 * Clear the settings cache (forces reload on next access)
 */
export function clearSettingsCache(): void {
  cachedSettings = null;
  preloadPromise = null;
}

/**
 * Get a specific setting value by path
 * @param path - Dot-separated path to the setting
 * @returns The setting value or undefined if not found
 */
export function getSetting<T>(path: string): T | undefined {
  const settings = getSettings();
  const parts = path.split('.');
  let current: unknown = settings;

  for (const part of parts) {
    if (current && typeof current === 'object' && part in current) {
      current = (current as Record<string, unknown>)[part];
    } else {
      return undefined;
    }
  }

  return current as T;
}

// =============================================================================
// Environment Variable Overrides
// =============================================================================

/**
 * Apply environment variable overrides to settings
 * Environment variables take precedence over file settings
 */
export function applyEnvOverrides(settings: TronSettings): TronSettings {
  const result = { ...settings };

  // API overrides
  if (process.env.ANTHROPIC_CLIENT_ID) {
    result.api = {
      ...result.api,
      anthropic: {
        ...result.api.anthropic,
        clientId: process.env.ANTHROPIC_CLIENT_ID,
      },
    };
  }

  // Server overrides
  if (process.env.TRON_WS_PORT) {
    result.server = {
      ...result.server,
      wsPort: parseInt(process.env.TRON_WS_PORT, 10),
    };
  }
  if (process.env.TRON_HEALTH_PORT) {
    result.server = {
      ...result.server,
      healthPort: parseInt(process.env.TRON_HEALTH_PORT, 10),
    };
  }
  if (process.env.TRON_HOST) {
    result.server = { ...result.server, host: process.env.TRON_HOST };
  }
  if (process.env.TRON_DEFAULT_MODEL) {
    result.server = {
      ...result.server,
      defaultModel: process.env.TRON_DEFAULT_MODEL,
    };
  }
  if (process.env.TRON_DEFAULT_PROVIDER) {
    result.server = {
      ...result.server,
      defaultProvider: process.env.TRON_DEFAULT_PROVIDER,
    };
  }
  if (process.env.TRON_MAX_SESSIONS) {
    result.server = {
      ...result.server,
      maxConcurrentSessions: parseInt(process.env.TRON_MAX_SESSIONS, 10),
    };
  }
  if (process.env.TRON_HEARTBEAT_INTERVAL) {
    result.server = {
      ...result.server,
      heartbeatIntervalMs: parseInt(process.env.TRON_HEARTBEAT_INTERVAL, 10),
    };
  }
  if (process.env.TRON_SESSIONS_DIR) {
    result.server = {
      ...result.server,
      sessionsDir: process.env.TRON_SESSIONS_DIR,
    };
  }
  if (process.env.TRON_MEMORY_DB) {
    result.server = {
      ...result.server,
      memoryDbPath: process.env.TRON_MEMORY_DB,
    };
  }
  if (process.env.TRON_TRANSCRIBE_ENABLED) {
    const enabled = process.env.TRON_TRANSCRIBE_ENABLED.toLowerCase();
    result.server = {
      ...result.server,
      transcription: {
        ...result.server.transcription,
        enabled: enabled === 'true' || enabled === '1' || enabled === 'yes',
      },
    };
  }
  if (process.env.TRON_TRANSCRIBE_URL) {
    result.server = {
      ...result.server,
      transcription: {
        ...result.server.transcription,
        baseUrl: process.env.TRON_TRANSCRIBE_URL,
      },
    };
  }
  if (process.env.TRON_TRANSCRIBE_TIMEOUT_MS) {
    result.server = {
      ...result.server,
      transcription: {
        ...result.server.transcription,
        timeoutMs: parseInt(process.env.TRON_TRANSCRIBE_TIMEOUT_MS, 10),
      },
    };
  }
  if (process.env.TRON_TRANSCRIBE_MAX_BYTES) {
    result.server = {
      ...result.server,
      transcription: {
        ...result.server.transcription,
        maxBytes: parseInt(process.env.TRON_TRANSCRIBE_MAX_BYTES, 10),
      },
    };
  }
  if (process.env.TRON_TRANSCRIBE_CLEANUP_MODE) {
    const cleanupMode = process.env.TRON_TRANSCRIBE_CLEANUP_MODE;
    if (cleanupMode === 'none' || cleanupMode === 'basic' || cleanupMode === 'llm') {
      result.server = {
        ...result.server,
        transcription: {
          ...result.server.transcription,
          cleanupMode,
        },
      };
    }
  }

  return result;
}

/**
 * Get settings with environment variable overrides applied
 */
export function getSettingsWithEnv(): TronSettings {
  return applyEnvOverrides(getSettings());
}

// =============================================================================
// Path Resolution Utilities
// =============================================================================

/**
 * Resolve a path that may be relative to the Tron directory (~/.tron)
 * If the path is already absolute, returns it unchanged.
 * If the path is relative, resolves it against ~/.tron.
 *
 * This ensures all clients (server, TUI, etc.) use the same canonical paths
 * for data storage, enabling collaborative sharing across interfaces.
 *
 * @param relativePath - Path that may be relative (e.g., 'sessions', 'memory.db')
 * @param tronDir - Optional override for the Tron directory (defaults to ~/.tron)
 * @returns Absolute path resolved against the Tron directory
 */
export function resolveTronPath(relativePath: string, tronDir?: string): string {
  // If already absolute, return as-is
  if (path.isAbsolute(relativePath)) {
    return relativePath;
  }

  const baseTronDir = tronDir ?? getSettingsDir();
  return path.join(baseTronDir, relativePath);
}

/**
 * Get the canonical Tron data directory (~/.tron)
 * This is the single source of truth for all Tron data storage paths.
 */
export function getTronDataDir(homeDir?: string): string {
  return getSettingsDir(homeDir);
}
