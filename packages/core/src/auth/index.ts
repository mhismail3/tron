/**
 * @fileoverview Auth module exports
 */

// OAuth functions (Anthropic-specific)
export {
  generatePKCE,
  getAuthorizationUrl,
  exchangeCodeForTokens,
  refreshOAuthToken,
  shouldRefreshTokens,
  isOAuthToken,
  loadServerAuth,
  OAuthError,
  type PKCEPair,
  /** @deprecated Use UnifiedAuth from types.ts */
  type StoredAuth,
} from './oauth.js';

// Unified auth types
export type {
  OAuthTokens,
  ProviderAuth,
  ProviderId,
  AuthStorage,
  ServerAuth,
  LegacyAnthropicAuth,
  LegacyCodexTokens,
} from './types.js';

// Unified auth functions
export {
  getAuthFilePath,
  loadAuthStorage,
  loadAuthStorageSync,
  getProviderAuth,
  getProviderAuthSync,
  saveAuthStorage,
  saveAuthStorageSync,
  saveProviderAuth,
  saveProviderAuthSync,
  saveProviderOAuthTokens,
  saveProviderApiKey,
  clearProviderAuth,
  clearAllAuth,
} from './unified.js';
