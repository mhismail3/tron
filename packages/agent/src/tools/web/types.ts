/**
 * @fileoverview Web Tools Types
 *
 * Type definitions for WebFetch and WebSearch tools.
 */

// =============================================================================
// URL Validation Types
// =============================================================================

/**
 * Result of URL validation
 */
export interface UrlValidationResult {
  valid: boolean;
  url?: string; // Normalized URL (with HTTPS)
  error?: UrlValidationError;
}

/**
 * URL validation error
 */
export interface UrlValidationError {
  code: UrlErrorCode;
  message: string;
  details?: Record<string, unknown>;
}

/**
 * URL error codes
 */
export type UrlErrorCode =
  | 'INVALID_FORMAT'
  | 'INVALID_PROTOCOL'
  | 'DOMAIN_BLOCKED'
  | 'DOMAIN_NOT_ALLOWED'
  | 'CREDENTIALS_IN_URL'
  | 'URL_TOO_LONG'
  | 'INTERNAL_ADDRESS'
  | 'INVALID_HOST';

/**
 * URL validator configuration
 */
export interface UrlValidatorConfig {
  /** Max URL length in characters (default: 2000) */
  maxLength?: number;
  /** Allowed domains (empty = allow all) */
  allowedDomains?: string[];
  /** Blocked domains */
  blockedDomains?: string[];
  /** Allow localhost/internal IPs (default: false) */
  allowInternal?: boolean;
}

// =============================================================================
// HTML Parser Types
// =============================================================================

/**
 * Result of HTML parsing
 */
export interface HtmlParseResult {
  /** Markdown content extracted from HTML */
  markdown: string;
  /** Page title */
  title: string;
  /** Page description (meta) */
  description?: string;
  /** Original content length in bytes */
  originalLength: number;
  /** Parsed content length in characters */
  parsedLength: number;
}

/**
 * HTML parser configuration
 */
export interface HtmlParserConfig {
  /** Include images in output (default: false) */
  includeImages?: boolean;
  /** Maximum content length before truncation (default: 500000) */
  maxContentLength?: number;
}

// =============================================================================
// Content Truncation Types
// =============================================================================

/**
 * Result of content truncation
 */
export interface ContentTruncateResult {
  /** Truncated content */
  content: string;
  /** Whether truncation occurred */
  truncated: boolean;
  /** Original token estimate */
  originalTokens: number;
  /** Final token estimate */
  finalTokens: number;
  /** Number of lines preserved */
  linesPreserved: number;
}

/**
 * Content truncator configuration
 */
export interface ContentTruncatorConfig {
  /** Maximum tokens (default: 50000) */
  maxTokens?: number;
  /** Preserve first N lines (default: 100) */
  preserveStartLines?: number;
  /** Characters per token estimate (default: 4) */
  charsPerToken?: number;
}

// =============================================================================
// Cache Types
// =============================================================================

/**
 * Cached fetch result
 */
export interface CachedFetchResult {
  /** The cached answer */
  answer: string;
  /** Source metadata */
  source: {
    url: string;
    title: string;
    fetchedAt: string;
  };
  /** Subagent session ID that produced this result */
  subagentSessionId: string;
  /** When this entry was cached */
  cachedAt: number;
  /** When this entry expires */
  expiresAt: number;
}

/**
 * Cache configuration
 */
export interface WebCacheConfig {
  /** Time-to-live in milliseconds (default: 900000 = 15 minutes) */
  ttl?: number;
  /** Maximum cache entries (default: 100) */
  maxEntries?: number;
}

/**
 * Cache statistics
 */
export interface CacheStats {
  /** Number of entries currently in cache */
  size: number;
  /** Cache hit count */
  hits: number;
  /** Cache miss count */
  misses: number;
  /** Hit rate (0-1) */
  hitRate: number;
}

// =============================================================================
// WebFetch Types
// =============================================================================

/**
 * WebFetch tool parameters
 */
export interface WebFetchParams {
  /** URL to fetch (required) */
  url: string;
  /** Question/prompt about the content (required) */
  prompt: string;
  /** Maximum content size in bytes before truncation (optional, default: 100KB) */
  maxContentSize?: number;
}

/**
 * WebFetch tool result
 */
export interface WebFetchResult {
  /** Haiku's answer to the prompt about the content */
  answer: string;
  /** Source metadata */
  source: {
    url: string;
    title: string;
    fetchedAt: string;
  };
  /** Subagent session ID for debugging/tracking */
  subagentSessionId: string;
  /** Whether result came from cache */
  fromCache?: boolean;
  /** Token usage from the summarization */
  tokenUsage?: {
    inputTokens: number;
    outputTokens: number;
  };
}

/**
 * WebFetch error
 */
export interface WebFetchError {
  code: WebFetchErrorCode;
  message: string;
  details?: Record<string, unknown>;
}

/**
 * WebFetch error codes
 */
export type WebFetchErrorCode =
  | 'INVALID_URL'
  | 'FETCH_FAILED'
  | 'TIMEOUT'
  | 'PARSE_FAILED'
  | 'SUMMARIZATION_FAILED'
  | 'DOMAIN_BLOCKED'
  | 'CONTENT_TOO_LARGE'
  | 'REDIRECT_LOOP';

/**
 * WebFetch tool configuration
 */
export interface WebFetchToolConfig {
  /** Working directory for the session */
  workingDirectory: string;
  /** Callback to spawn Haiku subagent for summarization */
  onSpawnSubagent: SubagentSpawnCallback;
  /** Cache configuration */
  cache?: WebCacheConfig;
  /** HTTP fetch configuration */
  http?: HttpFetchConfig;
  /** URL validation configuration */
  urlValidator?: UrlValidatorConfig;
  /** Content truncation configuration */
  truncator?: ContentTruncatorConfig;
}

/**
 * HTTP fetch configuration
 */
export interface HttpFetchConfig {
  /** Request timeout in milliseconds (default: 30000) */
  timeout?: number;
  /** Maximum redirects to follow (default: 5) */
  maxRedirects?: number;
  /** User agent string (default: 'TronAgent/1.0') */
  userAgent?: string;
  /** Maximum response size in bytes (default: 10MB) */
  maxResponseSize?: number;
}

/**
 * Callback to spawn a subagent for summarization
 */
export type SubagentSpawnCallback = (params: {
  task: string;
  model: string;
  timeout: number;
  maxTurns: number;
}) => Promise<SubagentSpawnResult>;

/**
 * Result of spawning a subagent
 */
export interface SubagentSpawnResult {
  sessionId: string;
  success: boolean;
  output?: string;
  error?: string;
  tokenUsage?: {
    inputTokens: number;
    outputTokens: number;
  };
}

// =============================================================================
// WebSearch Types
// =============================================================================

/**
 * WebSearch tool parameters
 */
export interface WebSearchParams {
  /** Search query (required) */
  query: string;
  /** Maximum number of results (optional, default: 10, max: 20) */
  maxResults?: number;
  /** Only include results from these domains */
  allowedDomains?: string[];
  /** Exclude results from these domains */
  blockedDomains?: string[];
}

/**
 * WebSearch tool result
 */
export interface WebSearchResult {
  /** Search results */
  results: SearchResultItem[];
  /** Total number of results found */
  totalResults: number;
  /** The query that was executed */
  query: string;
}

/**
 * Individual search result item
 */
export interface SearchResultItem {
  /** Page title */
  title: string;
  /** Page URL */
  url: string;
  /** Content snippet */
  snippet: string;
  /** Age of the result (e.g., "2 days ago") */
  age?: string;
  /** Domain of the result */
  domain?: string;
}

/**
 * WebSearch error
 */
export interface WebSearchError {
  code: WebSearchErrorCode;
  message: string;
  details?: Record<string, unknown>;
}

/**
 * WebSearch error codes
 */
export type WebSearchErrorCode =
  | 'INVALID_QUERY'
  | 'QUERY_TOO_LONG'
  | 'API_ERROR'
  | 'RATE_LIMITED'
  | 'NO_API_KEY'
  | 'NO_RESULTS';

/**
 * WebSearch tool configuration
 */
export interface WebSearchToolConfig {
  /** Brave Search API key (required) */
  apiKey: string;
  /** Default maximum results (default: 10) */
  defaultMaxResults?: number;
  /** Maximum allowed results (default: 20) */
  maxAllowedResults?: number;
  /** Default domain filters */
  allowedDomains?: string[];
  /** Default blocked domains */
  blockedDomains?: string[];
  /** Request timeout in milliseconds (default: 10000) */
  timeout?: number;
}

// =============================================================================
// Brave Search API Types
// =============================================================================

/**
 * Brave Search API response
 */
export interface BraveSearchResponse {
  query: {
    original: string;
    altered?: string;
  };
  web?: {
    results: BraveWebResult[];
  };
  mixed?: {
    main: Array<{ type: string; index: number }>;
  };
}

/**
 * Brave Search web result
 */
export interface BraveWebResult {
  title: string;
  url: string;
  description: string;
  age?: string;
  page_age?: string;
  language?: string;
  family_friendly?: boolean;
  extra_snippets?: string[];
}

/**
 * Brave Search client configuration
 */
export interface BraveSearchClientConfig {
  /** API key */
  apiKey: string;
  /** Base URL (default: https://api.search.brave.com) */
  baseUrl?: string;
  /** Request timeout in milliseconds */
  timeout?: number;
}
