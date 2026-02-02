/**
 * @fileoverview Brave Search API Types
 *
 * Comprehensive type definitions for all Brave Search API endpoints:
 * - Web Search (/res/v1/web/search)
 * - News Search (/res/v1/news/search)
 * - Image Search (/res/v1/images/search)
 * - Video Search (/res/v1/videos/search)
 *
 * Based on Brave Search API documentation.
 * Free plan: 1 RPS, 2000 requests/month per key
 */

// =============================================================================
// Common Types
// =============================================================================

/**
 * Query information returned by all endpoints
 */
export interface BraveQueryInfo {
  /** Original query string */
  original: string;
  /** Altered query (spelling corrections, etc.) */
  altered?: string;
  /** Whether spelling was checked */
  spellcheck_off?: boolean;
}

/**
 * Rate limit information from response headers
 */
export interface BraveRateLimitInfo {
  /** Requests remaining in current period */
  remaining?: number;
  /** Timestamp when limit resets (ISO 8601) */
  reset?: string;
  /** Time in seconds until limit resets */
  retryAfter?: number;
}

/**
 * Deep link for additional actions
 */
export interface BraveDeepLink {
  title: string;
  url: string;
}

/**
 * Thumbnail image
 */
export interface BraveThumbnail {
  src: string;
  width?: number;
  height?: number;
}

// =============================================================================
// Web Search Types
// =============================================================================

/**
 * Web search result
 */
export interface BraveWebResult {
  /** Page title */
  title: string;
  /** Page URL */
  url: string;
  /** Description/snippet */
  description: string;
  /** Human-readable age (e.g., "2 days ago") */
  age?: string;
  /** ISO 8601 date when page was indexed */
  page_age?: string;
  /** Content language code */
  language?: string;
  /** Whether content is family friendly */
  family_friendly?: boolean;
  /** Additional text excerpts (up to 5 if extra_snippets=true) */
  extra_snippets?: string[];
  /** Deep links for sub-pages */
  deep_results?: {
    links?: BraveDeepLink[];
  };
}

/**
 * News result (from web search result_filter or news endpoint)
 */
export interface BraveNewsResult {
  /** Article title */
  title: string;
  /** Article URL */
  url: string;
  /** Article description/snippet */
  description: string;
  /** Human-readable age */
  age?: string;
  /** ISO 8601 publication date */
  page_age?: string;
  /** Publisher/source name */
  source?: string;
  /** Thumbnail image */
  thumbnail?: BraveThumbnail;
  /** Whether content is family friendly */
  family_friendly?: boolean;
}

/**
 * Video result
 */
export interface BraveVideoResult {
  /** Video title */
  title: string;
  /** Video page URL */
  url: string;
  /** Video description */
  description: string;
  /** Human-readable age */
  age?: string;
  /** ISO 8601 publication date */
  page_age?: string;
  /** Video duration in format "MM:SS" or "HH:MM:SS" */
  duration?: string;
  /** Thumbnail image */
  thumbnail?: BraveThumbnail;
  /** Publisher/creator name */
  publisher?: string;
  /** View count (if available) */
  views?: number;
  /** Whether content is family friendly */
  family_friendly?: boolean;
}

/**
 * Image result
 */
export interface BraveImageResult {
  /** Image title/alt text */
  title: string;
  /** Image source page URL */
  url: string;
  /** Direct image URL */
  src: string;
  /** Image width */
  width?: number;
  /** Image height */
  height?: number;
  /** Thumbnail */
  thumbnail?: BraveThumbnail;
  /** Source page domain */
  source?: string;
  /** Whether content is family friendly */
  family_friendly?: boolean;
}

/**
 * FAQ result (from web search)
 */
export interface BraveFaqResult {
  /** Question */
  question: string;
  /** Answer */
  answer: string;
  /** Source page title */
  title: string;
  /** Source URL */
  url: string;
}

/**
 * Discussion result (from web search with discussions filter)
 */
export interface BraveDiscussionResult {
  /** Discussion title */
  title: string;
  /** Discussion URL */
  url: string;
  /** Description/snippet */
  description: string;
  /** Forum/platform name */
  forum_name?: string;
  /** Number of comments/replies */
  num_answers?: number;
  /** Human-readable age */
  age?: string;
}

/**
 * Infobox result (knowledge graph style)
 */
export interface BraveInfobox {
  /** Entity type (person, place, organization, etc.) */
  type?: string;
  /** Main title */
  title: string;
  /** Description */
  description?: string;
  /** Source URL */
  url?: string;
  /** Long description */
  long_desc?: string;
  /** Key-value attributes */
  attributes?: Record<string, string>;
  /** Images */
  images?: BraveThumbnail[];
  /** Provider (e.g., "Wikipedia") */
  provider?: {
    name: string;
    url?: string;
  };
}

/**
 * Mixed result type indicator
 */
export interface BraveMixedItem {
  /** Result type: 'web', 'news', 'videos', 'images', 'faq', 'infobox', 'discussions' */
  type: string;
  /** Index into the corresponding results array */
  index: number;
  /** Whether this is an "all" or ranked result */
  all?: boolean;
}

/**
 * Web search API response
 */
export interface BraveWebSearchResponse {
  /** Query information */
  query: BraveQueryInfo;
  /** Web results */
  web?: {
    results: BraveWebResult[];
  };
  /** News results (if result_filter includes news) */
  news?: {
    results: BraveNewsResult[];
  };
  /** Video results (if result_filter includes videos) */
  videos?: {
    results: BraveVideoResult[];
  };
  /** FAQ results (if result_filter includes faq) */
  faq?: {
    results: BraveFaqResult[];
  };
  /** Discussion results (if result_filter includes discussions) */
  discussions?: {
    results: BraveDiscussionResult[];
  };
  /** Infobox (if result_filter includes infobox) */
  infobox?: BraveInfobox;
  /** Mixed result ordering */
  mixed?: {
    main: BraveMixedItem[];
    top?: BraveMixedItem[];
    side?: BraveMixedItem[];
  };
}

// =============================================================================
// News Search Types
// =============================================================================

/**
 * News search API response
 */
export interface BraveNewsSearchResponse {
  /** Query information */
  query: BraveQueryInfo;
  /** News results */
  results: BraveNewsResult[];
}

// =============================================================================
// Image Search Types
// =============================================================================

/**
 * Image search API response
 */
export interface BraveImageSearchResponse {
  /** Query information */
  query: BraveQueryInfo;
  /** Image results */
  results: BraveImageResult[];
}

// =============================================================================
// Video Search Types
// =============================================================================

/**
 * Video search API response
 */
export interface BraveVideoSearchResponse {
  /** Query information */
  query: BraveQueryInfo;
  /** Video results */
  results: BraveVideoResult[];
}

// =============================================================================
// Request Parameter Types
// =============================================================================

/**
 * Freshness filter values
 * - pd: Past day (24h)
 * - pw: Past week (7d)
 * - pm: Past month (31d)
 * - py: Past year (365d)
 * - YYYY-MM-DDtoYYYY-MM-DD: Custom date range
 */
export type BraveFreshness = 'pd' | 'pw' | 'pm' | 'py' | string;

/**
 * Safe search levels
 */
export type BraveSafesearch = 'off' | 'moderate' | 'strict';

/**
 * Web search result filter types (comma-separated in API)
 */
export type BraveResultFilter =
  | 'discussions'
  | 'faq'
  | 'infobox'
  | 'news'
  | 'videos'
  | 'web';

/**
 * Common search parameters (all endpoints)
 */
export interface BraveCommonParams {
  /** Search query (required, max 400 chars) */
  q: string;
  /** 2-char country code (e.g., 'US', 'GB') */
  country?: string;
  /** Content language code (e.g., 'en', 'es') */
  search_lang?: string;
  /** Safe search level */
  safesearch?: BraveSafesearch;
  /** Enable/disable spellcheck */
  spellcheck?: boolean;
}

/**
 * Web search specific parameters
 */
export interface BraveWebSearchParams extends BraveCommonParams {
  /** Number of results (1-20, default: 10) */
  count?: number;
  /** Pagination offset (0-9) */
  offset?: number;
  /** Time filter */
  freshness?: BraveFreshness;
  /** Comma-separated result types to include */
  result_filter?: string;
  /** Get additional text excerpts (up to 5 per result) */
  extra_snippets?: boolean;
}

/**
 * News search specific parameters
 */
export interface BraveNewsSearchParams extends BraveCommonParams {
  /** Number of results (1-50, default: 20) */
  count?: number;
  /** Pagination offset (0-9) */
  offset?: number;
  /** Time filter */
  freshness?: BraveFreshness;
  /** Get additional text excerpts */
  extra_snippets?: boolean;
}

/**
 * Image search specific parameters
 */
export interface BraveImageSearchParams extends BraveCommonParams {
  /** Number of results (1-200, default: 50) */
  count?: number;
  /** Note: images endpoint does NOT support offset or freshness */
}

/**
 * Video search specific parameters
 */
export interface BraveVideoSearchParams extends BraveCommonParams {
  /** Number of results (1-50, default: 20) */
  count?: number;
  /** Pagination offset (0-9) */
  offset?: number;
  /** Time filter */
  freshness?: BraveFreshness;
}

// =============================================================================
// Unified Types for BraveMultiClient
// =============================================================================

/**
 * Supported Brave API endpoints
 */
export type BraveEndpoint = 'web' | 'news' | 'images' | 'videos';

/**
 * Endpoint paths
 */
export const BRAVE_ENDPOINT_PATHS: Record<BraveEndpoint, string> = {
  web: '/res/v1/web/search',
  news: '/res/v1/news/search',
  images: '/res/v1/images/search',
  videos: '/res/v1/videos/search',
};

/**
 * Endpoint count limits
 */
export const BRAVE_ENDPOINT_LIMITS: Record<BraveEndpoint, { min: number; max: number; default: number }> = {
  web: { min: 1, max: 20, default: 10 },
  news: { min: 1, max: 50, default: 20 },
  images: { min: 1, max: 200, default: 50 },
  videos: { min: 1, max: 50, default: 20 },
};

/**
 * Endpoint capabilities
 */
export const BRAVE_ENDPOINT_CAPABILITIES: Record<BraveEndpoint, {
  supportsOffset: boolean;
  supportsFreshness: boolean;
  supportsExtraSnippets: boolean;
}> = {
  web: { supportsOffset: true, supportsFreshness: true, supportsExtraSnippets: true },
  news: { supportsOffset: true, supportsFreshness: true, supportsExtraSnippets: true },
  images: { supportsOffset: false, supportsFreshness: false, supportsExtraSnippets: false },
  videos: { supportsOffset: true, supportsFreshness: true, supportsExtraSnippets: false },
};

/**
 * Union type for all search responses
 */
export type BraveSearchResponse =
  | { endpoint: 'web'; data: BraveWebSearchResponse }
  | { endpoint: 'news'; data: BraveNewsSearchResponse }
  | { endpoint: 'images'; data: BraveImageSearchResponse }
  | { endpoint: 'videos'; data: BraveVideoSearchResponse };

/**
 * Error response from Brave API
 */
export interface BraveErrorResponse {
  /** Error type */
  type?: string;
  /** Error message */
  message?: string;
  /** HTTP status code */
  status?: number;
}
