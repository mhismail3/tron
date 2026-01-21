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

// Google OAuth functions
export {
  generateGooglePKCE,
  getGoogleAuthorizationUrl,
  exchangeGoogleCodeForTokens,
  refreshGoogleOAuthToken,
  shouldRefreshGoogleTokens,
  isGoogleOAuthToken,
  loadGoogleServerAuth,
  saveGoogleOAuthTokens,
  discoverGoogleProject,
  getGeminiApiUrl,
  getGeminiApiHeaders,
  GoogleOAuthError,
  CLOUD_CODE_ASSIST_CONFIG,
  ANTIGRAVITY_CONFIG,
  type GooglePKCEPair,
  type GoogleOAuthEndpoint,
  type GoogleOAuthConfig,
  type GoogleAuth,
} from './google-oauth.js';

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
