/**
 * @fileoverview Brave Search API Client
 *
 * Client for the Brave Search API with domain filtering support.
 */

import { createLogger } from '../../logging/index.js';
import type {
  BraveSearchClientConfig,
  BraveSearchResponse,
  BraveWebResult,
  WebSearchResult,
  SearchResultItem,
} from './types.js';

const logger = createLogger('brave-search');

const DEFAULT_BASE_URL = 'https://api.search.brave.com';
const DEFAULT_TIMEOUT = 10000; // 10 seconds

/**
 * Options for a search request
 */
export interface SearchOptions {
  /** Maximum number of results */
  count?: number;
  /** Only include results from these domains */
  allowedDomains?: string[];
  /** Exclude results from these domains */
  blockedDomains?: string[];
  /** Safe search level */
  safesearch?: 'off' | 'moderate' | 'strict';
}

/**
 * Brave Search API client
 */
export class BraveSearchClient {
  private apiKey: string;
  private baseUrl: string;
  private timeout: number;

  constructor(config: BraveSearchClientConfig) {
    this.apiKey = config.apiKey;
    this.baseUrl = config.baseUrl ?? DEFAULT_BASE_URL;
    this.timeout = config.timeout ?? DEFAULT_TIMEOUT;
  }

  /**
   * Search the web using Brave Search API
   *
   * @param query - Search query
   * @param options - Search options
   * @returns Search results
   */
  async search(query: string, options: SearchOptions = {}): Promise<WebSearchResult> {
    const {
      count = 10,
      allowedDomains = [],
      blockedDomains = [],
      safesearch = 'moderate',
    } = options;

    // Build URL with query parameters
    const params = new URLSearchParams({
      q: query,
      count: count.toString(),
      safesearch,
    });

    const url = `${this.baseUrl}/res/v1/web/search?${params.toString()}`;

    logger.trace('Brave API request', {
      endpoint: '/res/v1/web/search',
      query,
      count,
      safesearch,
    });

    const startTime = Date.now();

    // Make API request
    const response = await fetch(url, {
      method: 'GET',
      headers: {
        'Accept': 'application/json',
        'X-Subscription-Token': this.apiKey,
      },
      signal: AbortSignal.timeout(this.timeout),
    });

    const durationMs = Date.now() - startTime;

    // Extract rate limit headers if present
    const rateLimitRemaining = response.headers.get('x-ratelimit-remaining');
    const rateLimitReset = response.headers.get('x-ratelimit-reset');

    logger.debug('Brave API response', {
      status: response.status,
      durationMs,
      rateLimitRemaining: rateLimitRemaining ? parseInt(rateLimitRemaining, 10) : undefined,
      rateLimitReset,
    });

    if (!response.ok) {
      const errorText = await response.text().catch(() => 'Unknown error');
      logger.warn('Brave API error response', {
        status: response.status,
        error: errorText,
        rateLimitRemaining,
      });
      throw new Error(`Brave Search API error: ${response.status} - ${errorText}`);
    }

    const data = (await response.json()) as BraveSearchResponse;

    logger.trace('Brave API raw results', {
      webResultCount: data.web?.results?.length ?? 0,
      hasQuery: !!data.query,
    });

    // Get web results
    let results = data.web?.results ?? [];
    const originalCount = results.length;

    // Apply domain filters
    if (allowedDomains.length > 0) {
      const beforeAllowedFilter = results.length;
      results = results.filter((result) => {
        const domain = extractDomain(result.url);
        return domain && allowedDomains.some((allowed) =>
          domainMatches(domain, allowed)
        );
      });
      if (results.length !== beforeAllowedFilter) {
        logger.debug('Allowed domain filter applied', {
          query,
          beforeCount: beforeAllowedFilter,
          afterCount: results.length,
          allowedDomains,
        });
      }
    }

    if (blockedDomains.length > 0) {
      const beforeBlockedFilter = results.length;
      results = results.filter((result) => {
        const domain = extractDomain(result.url);
        return !domain || !blockedDomains.some((blocked) =>
          domainMatches(domain, blocked)
        );
      });
      if (results.length !== beforeBlockedFilter) {
        logger.debug('Blocked domain filter applied', {
          query,
          beforeCount: beforeBlockedFilter,
          afterCount: results.length,
          blockedDomains,
        });
      }
    }

    if (results.length !== originalCount) {
      logger.debug('Domain filters reduced results', {
        query,
        originalCount,
        finalCount: results.length,
      });
    }

    return formatSearchResults(results, query);
  }
}

/**
 * Format Brave Search results to our standard format
 *
 * @param results - Raw Brave Search results
 * @param query - Original query
 * @returns Formatted search results
 */
export function formatSearchResults(
  results: BraveWebResult[],
  query: string
): WebSearchResult {
  const formattedResults: SearchResultItem[] = results.map((result) => ({
    title: result.title,
    url: result.url,
    snippet: result.description,
    age: result.age,
    domain: extractDomain(result.url),
  }));

  return {
    results: formattedResults,
    totalResults: formattedResults.length,
    query,
  };
}

/**
 * Extract domain from URL
 */
function extractDomain(url: string): string | undefined {
  try {
    const parsed = new URL(url);
    return parsed.hostname.toLowerCase();
  } catch {
    return undefined;
  }
}

/**
 * Check if a hostname matches a domain pattern (including subdomains)
 */
function domainMatches(hostname: string, domain: string): boolean {
  const normalizedHost = hostname.toLowerCase();
  const normalizedDomain = domain.toLowerCase();

  // Exact match
  if (normalizedHost === normalizedDomain) {
    return true;
  }
  // Subdomain match
  if (normalizedHost.endsWith(`.${normalizedDomain}`)) {
    return true;
  }
  return false;
}
