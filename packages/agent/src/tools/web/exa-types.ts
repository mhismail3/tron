/**
 * @fileoverview Exa Search API Types
 *
 * Type definitions for the Exa Search API.
 * Exa provides semantic/neural search with unique capabilities:
 * - Hour-level date filtering (startPublishedDate with full ISO 8601 timestamps)
 * - Category filtering (tweets, research papers, news, etc.)
 * - Neural, auto, fast, and deep search modes
 *
 * API Documentation: https://docs.exa.ai
 */

// =============================================================================
// Search Parameter Types
// =============================================================================

/**
 * Exa search type
 * - neural: Use neural/semantic search (slower but better for natural language)
 * - auto: Let Exa decide between neural and keyword (default)
 * - fast: Keyword-based search (fastest)
 * - deep: Deep crawl for comprehensive results (slowest)
 */
export type ExaSearchType = 'neural' | 'auto' | 'fast' | 'deep';

/**
 * Exa category filter for specialized content types
 */
export type ExaCategory =
  | 'news'
  | 'tweet'
  | 'research paper'
  | 'company'
  | 'personal site'
  | 'pdf'
  | 'github'
  | 'people';

/**
 * Content options for retrieving page content
 *
 * Note: These use camelCase internally but are converted to snake_case
 * when sent to the Exa API (e.g., numSentences -> num_sentences).
 */
export interface ExaContentsOptions {
  /** Include full text content */
  text?: boolean | { maxCharacters?: number };
  /** Include highlighted sentences */
  highlights?: boolean | { numSentences?: number; highlightsPerUrl?: number };
  /** Include summary (requires text to be true) */
  summary?: boolean | { query?: string };
}

/**
 * Exa search request parameters
 */
export interface ExaSearchParams {
  /** Search query (required) */
  query: string;

  /** Search type (default: 'auto') */
  type?: ExaSearchType;

  /** Filter by category */
  category?: ExaCategory;

  /** Number of results to return (default: 10, max: 100) */
  numResults?: number;

  /**
   * Start of date range for published content
   * Full ISO 8601 format: 2025-01-31T09:00:00.000Z
   * This is the key capability Brave lacks - hour-level filtering!
   */
  startPublishedDate?: string;

  /**
   * End of date range for published content
   * Full ISO 8601 format: 2025-01-31T09:00:00.000Z
   */
  endPublishedDate?: string;

  /**
   * Start of date range for crawled content
   * Useful for finding newly indexed pages
   */
  startCrawlDate?: string;

  /**
   * End of date range for crawled content
   */
  endCrawlDate?: string;

  /** Only include results from these domains */
  includeDomains?: string[];

  /** Exclude results from these domains */
  excludeDomains?: string[];

  /** Only include results matching these text patterns */
  includeText?: string[];

  /** Exclude results matching these text patterns */
  excludeText?: string[];

  /** Content retrieval options */
  contents?: ExaContentsOptions;

  /**
   * Use autoprompt to optimize query for neural search
   * Exa will rewrite your query for better results
   */
  useAutoprompt?: boolean;
}

// =============================================================================
// Response Types
// =============================================================================

/**
 * Individual search result
 */
export interface ExaResult {
  /** Unique result ID */
  id: string;

  /** Page URL */
  url: string;

  /** Page title */
  title: string;

  /**
   * Publication date (ISO 8601)
   * May not be available for all results
   */
  publishedDate?: string;

  /** Author name if available */
  author?: string;

  /**
   * Full text content (if contents.text was requested)
   */
  text?: string;

  /**
   * Highlighted sentences (if contents.highlights was requested)
   */
  highlights?: string[];

  /**
   * Highlighted HTML (if contents.highlights was requested)
   */
  highlightScores?: number[];

  /**
   * Summary (if contents.summary was requested)
   */
  summary?: string;

  /**
   * Relevance score (0-1)
   */
  score?: number;
}

/**
 * Exa search response
 */
export interface ExaSearchResponse {
  /** Request ID for debugging/tracking */
  requestId: string;

  /** Search results */
  results: ExaResult[];

  /**
   * Rewritten query if useAutoprompt was true
   */
  autopromptString?: string;

  /**
   * Cost information (may not always be present)
   */
  costDollars?: {
    total: number;
  };
}

// =============================================================================
// Error Types
// =============================================================================

/**
 * Exa API error response
 */
export interface ExaErrorResponse {
  /** Error message */
  error: string;

  /** Error details */
  message?: string;

  /** HTTP status code */
  statusCode?: number;
}

// =============================================================================
// Client Configuration
// =============================================================================

/**
 * Exa client configuration
 */
export interface ExaClientConfig {
  /** Exa API key (required) */
  apiKey: string;

  /** Base URL (default: https://api.exa.ai) */
  baseUrl?: string;

  /** Request timeout in milliseconds (default: 30000) */
  timeout?: number;
}

// =============================================================================
// Constants
// =============================================================================

/** Default Exa API base URL */
export const EXA_DEFAULT_BASE_URL = 'https://api.exa.ai';

/** Default request timeout */
export const EXA_DEFAULT_TIMEOUT = 30000;

/** Maximum number of results per request */
export const EXA_MAX_RESULTS = 100;

/** Default number of results */
export const EXA_DEFAULT_RESULTS = 10;
