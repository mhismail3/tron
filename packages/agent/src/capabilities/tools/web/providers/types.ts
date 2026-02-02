/**
 * @fileoverview Unified Search Provider Interface
 *
 * Defines the common interface for all search providers (Brave, Exa).
 * This allows the unified search tool to work with multiple providers
 * interchangeably.
 */

// =============================================================================
// Provider Types
// =============================================================================

/**
 * Available search provider names
 */
export type ProviderName = 'brave' | 'exa';

/**
 * Content types that can be searched
 */
export type ContentType = 'web' | 'news' | 'images' | 'videos' | 'social' | 'research';

/**
 * Freshness filter - time range for results
 */
export type Freshness = 'hour' | 'day' | 'week' | 'month' | 'year';

// =============================================================================
// Provider Capabilities
// =============================================================================

/**
 * Describes what a provider can do
 */
export interface ProviderCapabilities {
  /** Provider supports hour-level freshness filtering */
  supportsHourFreshness: boolean;

  /** Provider supports exact date range filtering (ISO 8601) */
  supportsExactDateRange: boolean;

  /** Content types this provider can search */
  supportedContentTypes: ContentType[];

  /** Maximum results per request */
  maxResults: number;
}

// =============================================================================
// Search Parameters & Results
// =============================================================================

/**
 * Parameters for provider search (normalized from unified params)
 */
export interface ProviderSearchParams {
  /** Search query (required) */
  query: string;

  /** Number of results to return */
  count?: number;

  /** Time filter (provider will translate to its format) */
  freshness?: Freshness;

  /** Exact start date (ISO 8601) - Exa only */
  startDate?: string;

  /** Exact end date (ISO 8601) - Exa only */
  endDate?: string;

  /** Content type to search */
  contentType?: ContentType;

  /** Only include these domains */
  includeDomains?: string[];

  /** Exclude these domains */
  excludeDomains?: string[];
}

/**
 * Unified search result from any provider
 */
export interface UnifiedResult {
  /** Result title */
  title: string;

  /** Result URL */
  url: string;

  /** Snippet/description */
  snippet: string;

  /** Publication date (ISO 8601 if available) */
  publishedDate?: string;

  /** Human-readable age (e.g., "2 hours ago") */
  age?: string;

  /** Which provider returned this result */
  source: ProviderName;

  /** What type of content this is */
  contentType: ContentType;

  /** Author name if available */
  author?: string;

  /** Domain of the result */
  domain?: string;

  /** Provider-specific score if available */
  score?: number;
}

// =============================================================================
// Provider Interface
// =============================================================================

/**
 * Interface that all search providers must implement
 */
export interface SearchProvider {
  /** Provider identifier */
  readonly name: ProviderName;

  /** What this provider can do */
  readonly capabilities: ProviderCapabilities;

  /**
   * Execute a search query
   *
   * @param params - Normalized search parameters
   * @returns Array of unified results
   */
  search(params: ProviderSearchParams): Promise<UnifiedResult[]>;
}

// =============================================================================
// Provider Capability Constants
// =============================================================================

/**
 * Brave provider capabilities
 */
export const BRAVE_CAPABILITIES: ProviderCapabilities = {
  supportsHourFreshness: false, // Brave only supports day/week/month/year
  supportsExactDateRange: false, // Brave uses freshness codes, not exact dates
  supportedContentTypes: ['web', 'news', 'images', 'videos'],
  maxResults: 200, // Images endpoint allows up to 200
};

/**
 * Exa provider capabilities
 */
export const EXA_CAPABILITIES: ProviderCapabilities = {
  supportsHourFreshness: true, // The key differentiator!
  supportsExactDateRange: true, // Full ISO 8601 timestamp support
  supportedContentTypes: ['web', 'news', 'social', 'research'],
  maxResults: 100,
};

// =============================================================================
// Freshness Mapping Utilities
// =============================================================================

/**
 * Convert unified freshness to Brave's freshness format
 * Note: Brave doesn't support 'hour', so it falls back to 'day'
 */
export function freshnessToBrave(freshness: Freshness): string {
  switch (freshness) {
    case 'hour':
      return 'pd'; // Fallback to past day
    case 'day':
      return 'pd';
    case 'week':
      return 'pw';
    case 'month':
      return 'pm';
    case 'year':
      return 'py';
  }
}

/**
 * Convert unified freshness to Exa's date format
 * Returns ISO 8601 timestamp for startPublishedDate
 */
export function freshnessToExaDate(freshness: Freshness): string {
  const now = Date.now();
  let ms: number;

  switch (freshness) {
    case 'hour':
      ms = 60 * 60 * 1000; // 1 hour
      break;
    case 'day':
      ms = 24 * 60 * 60 * 1000; // 24 hours
      break;
    case 'week':
      ms = 7 * 24 * 60 * 60 * 1000; // 7 days
      break;
    case 'month':
      ms = 31 * 24 * 60 * 60 * 1000; // 31 days
      break;
    case 'year':
      ms = 365 * 24 * 60 * 60 * 1000; // 365 days
      break;
  }

  return new Date(now - ms).toISOString();
}

// =============================================================================
// Content Type Mapping Utilities
// =============================================================================

/**
 * Map content type to Brave endpoint
 * Returns undefined for content types Brave doesn't support
 */
export function contentTypeToBraveEndpoint(
  contentType: ContentType
): 'web' | 'news' | 'images' | 'videos' | undefined {
  switch (contentType) {
    case 'web':
      return 'web';
    case 'news':
      return 'news';
    case 'images':
      return 'images';
    case 'videos':
      return 'videos';
    case 'social':
    case 'research':
      return undefined; // Brave doesn't support these
  }
}

/**
 * Map content type to Exa category
 * Returns undefined for content types that don't map to specific categories
 */
export function contentTypeToExaCategory(
  contentType: ContentType
): 'news' | 'tweet' | 'research paper' | undefined {
  switch (contentType) {
    case 'news':
      return 'news';
    case 'social':
      return 'tweet';
    case 'research':
      return 'research paper';
    case 'web':
    case 'images':
    case 'videos':
      return undefined; // No specific category, use default search
  }
}
