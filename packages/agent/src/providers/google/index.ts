/**
 * @fileoverview Google Provider Module
 *
 * Public API for the Google Gemini provider.
 * Exports maintain exact compatibility with the original monolithic google.ts.
 */

// Re-export types
export type {
  GeminiThinkingLevel,
  HarmCategory,
  HarmBlockThreshold,
  HarmProbability,
  SafetyRating,
  SafetySetting,
  GoogleOAuthAuth,
  GoogleApiKeyAuth,
  GoogleProviderAuth,
  GoogleConfig,
  GoogleStreamOptions,
  GeminiModelInfo,
  GeminiModelId,
} from './types.js';

export {
  GEMINI_MODELS,
  DEFAULT_SAFETY_SETTINGS,
  isGemini3Model,
} from './types.js';

// Re-export provider class
export { GoogleProvider } from './google-provider.js';

// Re-export message conversion utilities (for testing)
export {
  convertMessages,
  convertTools,
  sanitizeSchemaForGemini,
} from './message-converter.js';
