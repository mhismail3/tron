/**
 * @fileoverview Web Tools Module
 *
 * Tools for fetching and searching web content:
 * - WebFetch: Fetch URLs and analyze content with Haiku subagent
 * - WebSearch: Search the web using Brave Search API
 */

// Main tools
export { WebFetchTool } from './web-fetch.js';
export { WebSearchTool } from './web-search.js';

// Utilities
export { validateUrl, UrlValidator } from './url-validator.js';
export { parseHtml, HtmlParser } from './html-parser.js';
export { truncateContent, ContentTruncator, estimateTokens, tokensToChars } from './content-truncator.js';
export { WebCache } from './cache.js';
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
  // Brave Search
  BraveSearchResponse,
  BraveWebResult,
  BraveSearchClientConfig,
} from './types.js';

// Summarizer types
export type { SummarizerConfig } from './summarizer.js';
