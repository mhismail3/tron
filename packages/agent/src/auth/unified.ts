/**
 * @fileoverview Unified auth storage management
 *
 * Provides functions to load, save, and manage authentication data
 * for all providers from a single ~/.tron/auth.json file.
 */

import * as fs from 'fs';
import * as fsPromises from 'fs/promises';
import * as path from 'path';
import { createLogger, categorizeError, LogErrorCategory } from '../logging/index.js';
import { getTronDataDir } from '../settings/index.js';
import type { AuthStorage, ProviderAuth, ProviderId, ServiceAuth, ServiceId, OAuthTokens } from './types.js';

const logger = createLogger('unified-auth');

// =============================================================================
// Constants
// =============================================================================

const AUTH_FILENAME = 'auth.json';

// =============================================================================
// File Path
// =============================================================================

/**
 * Get the path to the unified auth.json file
 */
export function getAuthFilePath(): string {
  return path.join(getTronDataDir(), AUTH_FILENAME);
}

// =============================================================================
// Load Functions
// =============================================================================

/**
 * Load the unified auth data from ~/.tron/auth.json
 * Returns null if file doesn't exist or is invalid
 */
export async function loadAuthStorage(): Promise<AuthStorage | null> {
  const authPath = getAuthFilePath();

  try {
    const data = await fsPromises.readFile(authPath, 'utf-8');
    const parsed = JSON.parse(data) as AuthStorage;

    // Validate it's the unified format
    if (parsed.version !== 1 || !parsed.providers) {
      logger.warn('auth.json is not in unified format', { path: authPath });
      return null;
    }

    return parsed;
  } catch (error) {
    // File doesn't exist or is invalid
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
      const structured = categorizeError(error, { path: authPath, operation: 'loadAuthStorage' });
      logger.warn('Failed to load unified auth', {
        code: structured.code,
        category: LogErrorCategory.PROVIDER_AUTH,
        error: structured.message,
        retryable: structured.retryable,
      });
    }
    return null;
  }
}

/**
 * Synchronously load unified auth data (for server-side use)
 * Returns null if file doesn't exist or is invalid
 */
export function loadAuthStorageSync(): AuthStorage | null {
  const authPath = getAuthFilePath();

  try {
    const data = fs.readFileSync(authPath, 'utf-8');
    const parsed = JSON.parse(data) as AuthStorage;

    if (parsed.version !== 1 || !parsed.providers) {
      logger.warn('auth.json is not in unified format (sync)', { path: authPath });
      return null;
    }

    return parsed;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
      const structured = categorizeError(error, { path: authPath, operation: 'loadAuthStorageSync' });
      logger.warn('Failed to load unified auth (sync)', {
        code: structured.code,
        category: LogErrorCategory.PROVIDER_AUTH,
        error: structured.message,
        retryable: structured.retryable,
      });
    }
    return null;
  }
}

/**
 * Get authentication for a specific provider
 */
export async function getProviderAuth(provider: ProviderId): Promise<ProviderAuth | null> {
  const auth = await loadAuthStorage();
  return auth?.providers[provider] ?? null;
}

/**
 * Synchronously get authentication for a specific provider
 */
export function getProviderAuthSync(provider: ProviderId): ProviderAuth | null {
  const auth = loadAuthStorageSync();
  return auth?.providers[provider] ?? null;
}

/**
 * Get authentication for a specific external service
 */
export async function getServiceAuth(service: ServiceId): Promise<ServiceAuth | null> {
  const auth = await loadAuthStorage();
  return auth?.services?.[service] ?? null;
}

/**
 * Synchronously get authentication for a specific external service
 */
export function getServiceAuthSync(service: ServiceId): ServiceAuth | null {
  const auth = loadAuthStorageSync();
  return auth?.services?.[service] ?? null;
}

/**
 * Get API keys for a service, supporting both single and multiple key configs.
 *
 * If the service has apiKeys[] configured, returns that array.
 * If only apiKey is configured, returns it as a single-element array.
 * Returns empty array if no keys are configured.
 *
 * @param service - Service identifier (e.g., 'brave')
 * @returns Array of API keys for the service
 */
export function getServiceApiKeys(service: ServiceId): string[] {
  const serviceAuth = getServiceAuthSync(service);
  if (!serviceAuth) {
    return [];
  }

  // Prefer apiKeys array if present and non-empty
  if (serviceAuth.apiKeys && serviceAuth.apiKeys.length > 0) {
    // Filter out empty strings
    return serviceAuth.apiKeys.filter((k) => k && k.trim() !== '');
  }

  // Fall back to single apiKey
  if (serviceAuth.apiKey && serviceAuth.apiKey.trim() !== '') {
    return [serviceAuth.apiKey];
  }

  return [];
}

/**
 * Async version of getServiceApiKeys
 */
export async function getServiceApiKeysAsync(service: ServiceId): Promise<string[]> {
  const serviceAuth = await getServiceAuth(service);
  if (!serviceAuth) {
    return [];
  }

  if (serviceAuth.apiKeys && serviceAuth.apiKeys.length > 0) {
    return serviceAuth.apiKeys.filter((k) => k && k.trim() !== '');
  }

  if (serviceAuth.apiKey && serviceAuth.apiKey.trim() !== '') {
    return [serviceAuth.apiKey];
  }

  return [];
}

// =============================================================================
// Save Functions
// =============================================================================

/**
 * Save the entire unified auth structure
 */
export async function saveAuthStorage(auth: AuthStorage): Promise<void> {
  const authPath = getAuthFilePath();

  // Ensure directory exists
  const dir = path.dirname(authPath);
  await fsPromises.mkdir(dir, { recursive: true });

  // Update timestamp
  auth.lastUpdated = new Date().toISOString();

  // Write with secure permissions
  await fsPromises.writeFile(authPath, JSON.stringify(auth, null, 2), {
    mode: 0o600, // Owner read/write only
  });

  logger.debug('Saved unified auth', { providers: Object.keys(auth.providers) });
}

/**
 * Synchronously save the entire unified auth structure
 */
export function saveAuthStorageSync(auth: AuthStorage): void {
  const authPath = getAuthFilePath();

  // Ensure directory exists
  const dir = path.dirname(authPath);
  fs.mkdirSync(dir, { recursive: true });

  // Update timestamp
  auth.lastUpdated = new Date().toISOString();

  // Write with secure permissions
  fs.writeFileSync(authPath, JSON.stringify(auth, null, 2), {
    mode: 0o600,
  });

  logger.debug('Saved unified auth (sync)', { providers: Object.keys(auth.providers) });
}

/**
 * Save authentication for a specific provider
 * Preserves other providers' data
 */
export async function saveProviderAuth(
  provider: ProviderId,
  providerAuth: ProviderAuth
): Promise<void> {
  // Load existing or create new
  let auth = await loadAuthStorage();
  if (!auth) {
    auth = {
      version: 1,
      providers: {},
      lastUpdated: new Date().toISOString(),
    };
  }

  // Update provider auth
  auth.providers[provider] = providerAuth;

  await saveAuthStorage(auth);
  logger.info('Saved provider auth', { provider });
}

/**
 * Synchronously save authentication for a specific provider
 */
export function saveProviderAuthSync(
  provider: ProviderId,
  providerAuth: ProviderAuth
): void {
  let auth = loadAuthStorageSync();
  if (!auth) {
    auth = {
      version: 1,
      providers: {},
      lastUpdated: new Date().toISOString(),
    };
  }

  auth.providers[provider] = providerAuth;
  saveAuthStorageSync(auth);
  logger.info('Saved provider auth (sync)', { provider });
}

/**
 * Save OAuth tokens for a specific provider
 */
export async function saveProviderOAuthTokens(
  provider: ProviderId,
  tokens: OAuthTokens
): Promise<void> {
  const existing = await getProviderAuth(provider);
  await saveProviderAuth(provider, {
    ...existing,
    oauth: tokens,
  });
}

/**
 * Save API key for a specific provider
 */
export async function saveProviderApiKey(
  provider: ProviderId,
  apiKey: string
): Promise<void> {
  const existing = await getProviderAuth(provider);
  await saveProviderAuth(provider, {
    ...existing,
    apiKey,
  });
}

// =============================================================================
// Clear Functions
// =============================================================================

/**
 * Clear authentication for a specific provider
 * Removes the provider entry entirely
 */
export async function clearProviderAuth(provider: ProviderId): Promise<void> {
  const auth = await loadAuthStorage();
  if (!auth) {
    return; // Nothing to clear
  }

  delete auth.providers[provider];
  await saveAuthStorage(auth);
  logger.info('Cleared provider auth', { provider });
}

/**
 * Clear all authentication data
 * Removes the entire auth.json file
 */
export async function clearAllAuth(): Promise<void> {
  const authPath = getAuthFilePath();

  try {
    await fsPromises.unlink(authPath);
    logger.info('Cleared all auth');
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
      const structured = categorizeError(error, { path: authPath, operation: 'clearAllAuth' });
      logger.warn('Failed to clear auth file', {
        code: structured.code,
        category: LogErrorCategory.PROVIDER_AUTH,
        error: structured.message,
        retryable: structured.retryable,
      });
    }
  }
}
