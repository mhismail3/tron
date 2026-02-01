/**
 * @fileoverview Web Tools Module
 *
 * Tools for fetching and searching web content:
 * - WebFetch: Fetch URLs and analyze content with Haiku subagent
 * - WebSearch: Search the web with multiple providers (Brave + Exa)
 */

// Main tools
export { WebFetchTool } from './web-fetch.js';
export { UnifiedSearchTool, type UnifiedSearchConfig, type UnifiedSearchParams } from './unified-search.js';
// Legacy exports - WebSearchToolV2 for Brave-only, WebSearchTool deprecated
export { WebSearchToolV2, type WebSearchV2Config } from './web-search-v2.js';
export { WebSearchTool } from './web-search.js';

// Brave API components
export { BraveKeyRotator, KeyRotatorError, type KeyRotatorConfig, type RotatorStatus, type PublicKeyState } from './brave-key-rotator.js';
export { BraveMultiClient, type BraveMultiClientConfig, type BraveSearchParams, type BraveSearchResult } from './brave-multi-client.js';

// Exa API components
export { ExaClient } from './exa-client.js';
export type {
  ExaSearchParams,
  ExaSearchResponse,
  ExaResult,
  ExaClientConfig,
  ExaSearchType,
  ExaCategory,
} from './exa-types.js';

// Unified provider interface
export type {
  SearchProvider,
  ProviderName,
  ContentType,
  Freshness,
  ProviderCapabilities,
  ProviderSearchParams,
  UnifiedResult,
} from './providers/types.js';
export { BraveProvider, type BraveProviderConfig } from './providers/brave-provider.js';
export { ExaProvider, type ExaProviderConfig } from './providers/exa-provider.js';

// Brave API types
export type {
  BraveEndpoint,
  BraveWebResult,
  BraveNewsResult,
  BraveImageResult,
  BraveVideoResult,
  BraveFreshness,
  BraveSafesearch,
  BraveWebSearchResponse,
  BraveNewsSearchResponse,
  BraveImageSearchResponse,
  BraveVideoSearchResponse,
  BraveRateLimitInfo,
} from './brave-types.js';
export { BRAVE_ENDPOINT_PATHS, BRAVE_ENDPOINT_LIMITS, BRAVE_ENDPOINT_CAPABILITIES } from './brave-types.js';

// Utilities
export { validateUrl, UrlValidator } from './url-validator.js';
export { parseHtml, HtmlParser } from './html-parser.js';
export { truncateContent, ContentTruncator, estimateTokens, tokensToChars } from './content-truncator.js';
export { WebCache } from './cache.js';
// Legacy Brave client - deprecated, use BraveMultiClient
export { BraveSearchClient, formatSearchResults } from './brave-search.js';
export { createSummarizer, createHaikuSummarizer } from './summarizer.js';

// Types
export type {
  // URL Validation
  UrlValidationResult,
  UrlValidationError,
  UrlErrorCode,
  UrlValidatorConfig,
  // HTML Parsing
  HtmlParseResult,
  HtmlParserConfig,
  // Content Truncation
  ContentTruncateResult,
  ContentTruncatorConfig,
  // Cache
  CachedFetchResult,
  WebCacheConfig,
  CacheStats,
  // WebFetch
  WebFetchParams,
  WebFetchResult,
  WebFetchError,
  WebFetchErrorCode,
  WebFetchToolConfig,
  HttpFetchConfig,
  SubagentSpawnCallback,
  SubagentSpawnResult,
  // WebSearch
  WebSearchParams,
  WebSearchResult,
  WebSearchError,
  WebSearchErrorCode,
  WebSearchToolConfig,
  SearchResultItem,
  // Brave Search (legacy types from types.js)
  BraveSearchResponse as LegacyBraveSearchResponse,
  BraveWebResult as LegacyBraveWebResult,
  BraveSearchClientConfig,
} from './types.js';

// Summarizer types
export type { SummarizerConfig } from './summarizer.js';
