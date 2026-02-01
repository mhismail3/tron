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
  getDefaultAnthropicOAuthSettings,
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
  getGoogleOAuthCredentials,
  saveGoogleOAuthCredentials,
  getGoogleOAuthConfig,
  getDefaultGoogleApiSettings,
  GoogleOAuthError,
  CLOUD_CODE_ASSIST_CONFIG,
  ANTIGRAVITY_CONFIG,
  type GooglePKCEPair,
  type GoogleOAuthEndpoint,
  type GoogleOAuthConfig,
  type GoogleAuth,
} from './google-oauth.js';

// OpenAI/Codex auth functions
export {
  loadOpenAIServerAuth,
  loadOpenAIServerAuthSync,
  refreshOpenAIToken,
} from './openai-auth.js';

// Unified auth types
export type {
  OAuthTokens,
  ProviderAuth,
  GoogleProviderAuth,
  ProviderId,
  ServiceId,
  ServiceAuth,
  AuthStorage,
  ServerAuth,
  // NOTE: LegacyAnthropicAuth and LegacyCodexTokens removed - no longer needed
} from './types.js';

// Unified auth functions
export {
  getAuthFilePath,
  loadAuthStorage,
  loadAuthStorageSync,
  getProviderAuth,
  getProviderAuthSync,
  getServiceAuth,
  getServiceAuthSync,
  getServiceApiKeys,
  getServiceApiKeysAsync,
  saveAuthStorage,
  saveAuthStorageSync,
  saveProviderAuth,
  saveProviderAuthSync,
  saveProviderOAuthTokens,
  saveProviderApiKey,
  clearProviderAuth,
  clearAllAuth,
} from './unified.js';
