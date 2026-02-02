/**
 * @fileoverview Brave Multi-Endpoint Search Client
 *
 * Unified client for all Brave Search API endpoints:
 * - Web Search (/res/v1/web/search)
 * - News Search (/res/v1/news/search)
 * - Image Search (/res/v1/images/search)
 * - Video Search (/res/v1/videos/search)
 *
 * Features:
 * - Full parameter support for each endpoint
 * - Automatic count clamping to endpoint limits
 * - Key rotation integration for rate limiting
 * - Rate limit info extraction from headers
 */

import { createLogger } from '@infrastructure/logging/index.js';
import { BraveKeyRotator } from './brave-key-rotator.js';
import {
  type BraveEndpoint,
  type BraveRateLimitInfo,
  type BraveWebSearchResponse,
  type BraveNewsSearchResponse,
  type BraveImageSearchResponse,
  type BraveVideoSearchResponse,
  BRAVE_ENDPOINT_PATHS,
  BRAVE_ENDPOINT_LIMITS,
  BRAVE_ENDPOINT_CAPABILITIES,
} from './brave-types.js';

const logger = createLogger('brave-multi-client');

const DEFAULT_BASE_URL = 'https://api.search.brave.com';
const DEFAULT_TIMEOUT = 15000; // 15 seconds

// =============================================================================
// Types
// =============================================================================

/**
 * Search parameters for all endpoints
 */
export interface BraveSearchParams {
  /** Endpoint to use (default: 'web') */
  endpoint?: BraveEndpoint;
  /** Search query (required) */
  query: string;
  /** Number of results */
  count?: number;
  /** Pagination offset (0-9, web/news/videos only) */
  offset?: number;
  /** Time filter: 'pd' (day), 'pw' (week), 'pm' (month), 'py' (year), or date range */
  freshness?: string;
  /** 2-char country code */
  country?: string;
  /** Content language code */
  searchLang?: string;
  /** Safe search level */
  safesearch?: 'off' | 'moderate' | 'strict';
  /** Comma-separated result types (web only) */
  resultFilter?: string;
  /** Get additional excerpts (web/news only) */
  extraSnippets?: boolean;
  /** Enable/disable spellcheck */
  spellcheck?: boolean;
}

/**
 * Search result with endpoint-specific data
 */
export type BraveSearchResult =
  | { endpoint: 'web'; data: BraveWebSearchResponse; rateLimitInfo?: BraveRateLimitInfo }
  | { endpoint: 'news'; data: BraveNewsSearchResponse; rateLimitInfo?: BraveRateLimitInfo }
  | { endpoint: 'images'; data: BraveImageSearchResponse; rateLimitInfo?: BraveRateLimitInfo }
  | { endpoint: 'videos'; data: BraveVideoSearchResponse; rateLimitInfo?: BraveRateLimitInfo };

/**
 * Client configuration
 */
export interface BraveMultiClientConfig {
  /** Key rotator for managing API keys */
  keyRotator: BraveKeyRotator;
  /** Base URL (default: https://api.search.brave.com) */
  baseUrl?: string;
  /** Request timeout in milliseconds (default: 15000) */
  timeout?: number;
}

// =============================================================================
// Client Implementation
// =============================================================================

/**
 * Brave Search API client with multi-endpoint support.
 *
 * Usage:
 * ```typescript
 * const rotator = new BraveKeyRotator(['key1', 'key2']);
 * const client = new BraveMultiClient({ keyRotator: rotator });
 *
 * // Web search
 * const webResults = await client.search({
 *   endpoint: 'web',
 *   query: 'nodejs tutorials',
 *   count: 10,
 *   freshness: 'pw',
 * });
 *
 * // News search
 * const newsResults = await client.search({
 *   endpoint: 'news',
 *   query: 'technology',
 *   count: 20,
 * });
 * ```
 */
export class BraveMultiClient {
  private keyRotator: BraveKeyRotator;
  private baseUrl: string;
  private timeout: number;

  constructor(config: BraveMultiClientConfig) {
    this.keyRotator = config.keyRotator;
    this.baseUrl = config.baseUrl ?? DEFAULT_BASE_URL;
    this.timeout = config.timeout ?? DEFAULT_TIMEOUT;
  }

  /**
   * Execute a search on the specified endpoint.
   *
   * @param params - Search parameters
   * @returns Search results with endpoint-specific data
   */
  async search(params: BraveSearchParams): Promise<BraveSearchResult> {
    const endpoint = params.endpoint ?? 'web';
    const path = BRAVE_ENDPOINT_PATHS[endpoint];
    const limits = BRAVE_ENDPOINT_LIMITS[endpoint];
    const capabilities = BRAVE_ENDPOINT_CAPABILITIES[endpoint];

    // Build query parameters
    const queryParams = new URLSearchParams();
    queryParams.set('q', params.query);

    // Clamp count to endpoint limits
    const count = params.count
      ? Math.max(limits.min, Math.min(limits.max, params.count))
      : limits.default;
    queryParams.set('count', count.toString());

    // Add offset if supported
    if (params.offset !== undefined && capabilities.supportsOffset) {
      queryParams.set('offset', Math.min(9, Math.max(0, params.offset)).toString());
    }

    // Add freshness if supported
    if (params.freshness && capabilities.supportsFreshness) {
      queryParams.set('freshness', params.freshness);
    }

    // Add common parameters
    if (params.country) {
      queryParams.set('country', params.country);
    }
    if (params.searchLang) {
      queryParams.set('search_lang', params.searchLang);
    }
    if (params.safesearch) {
      queryParams.set('safesearch', params.safesearch);
    }
    if (params.spellcheck !== undefined) {
      queryParams.set('spellcheck', params.spellcheck.toString());
    }

    // Add endpoint-specific parameters
    if (endpoint === 'web' && params.resultFilter) {
      queryParams.set('result_filter', params.resultFilter);
    }
    if (capabilities.supportsExtraSnippets && params.extraSnippets) {
      queryParams.set('extra_snippets', 'true');
    }

    const url = `${this.baseUrl}${path}?${queryParams.toString()}`;

    logger.debug('Brave API request', {
      endpoint,
      query: params.query,
      count,
      url: url.replace(/q=[^&]+/, 'q=***'), // Mask query in logs
    });

    // Acquire key from rotator
    const apiKey = await this.keyRotator.acquireKey();

    try {
      const startTime = Date.now();

      const response = await fetch(url, {
        method: 'GET',
        headers: {
          Accept: 'application/json',
          'X-Subscription-Token': apiKey,
        },
        signal: AbortSignal.timeout(this.timeout),
      });

      const durationMs = Date.now() - startTime;

      // Extract rate limit info from headers
      const rateLimitInfo = this.extractRateLimitInfo(response.headers);

      logger.debug('Brave API response', {
        endpoint,
        status: response.status,
        durationMs,
        rateLimitRemaining: rateLimitInfo?.remaining,
      });

      // Handle rate limiting
      if (response.status === 429) {
        const retryAfter = response.headers.get('Retry-After');
        const retryMs = retryAfter ? parseInt(retryAfter, 10) * 1000 : 60000;
        this.keyRotator.markRateLimited(apiKey, retryMs);

        const errorText = await response.text().catch(() => 'Rate limited');
        throw new Error(`Brave Search API error: 429 - ${errorText}`);
      }

      // Handle other errors
      if (!response.ok) {
        const errorText = await response.text().catch(() => 'Unknown error');
        throw new Error(`Brave Search API error: ${response.status} - ${errorText}`);
      }

      const data = await response.json();

      // Return typed result based on endpoint
      return this.buildResult(endpoint, data, rateLimitInfo);
    } finally {
      // Always release the key
      this.keyRotator.releaseKey(apiKey);
    }
  }

  /**
   * Extract rate limit information from response headers.
   */
  private extractRateLimitInfo(headers: Headers): BraveRateLimitInfo | undefined {
    const remaining = headers.get('X-RateLimit-Remaining');
    const reset = headers.get('X-RateLimit-Reset');

    if (!remaining && !reset) {
      return undefined;
    }

    return {
      remaining: remaining ? parseInt(remaining, 10) : undefined,
      reset: reset ?? undefined,
    };
  }

  /**
   * Build typed result based on endpoint.
   */
  private buildResult(
    endpoint: BraveEndpoint,
    data: unknown,
    rateLimitInfo?: BraveRateLimitInfo
  ): BraveSearchResult {
    switch (endpoint) {
      case 'web':
        return {
          endpoint: 'web',
          data: data as BraveWebSearchResponse,
          rateLimitInfo,
        };
      case 'news':
        return {
          endpoint: 'news',
          data: data as BraveNewsSearchResponse,
          rateLimitInfo,
        };
      case 'images':
        return {
          endpoint: 'images',
          data: data as BraveImageSearchResponse,
          rateLimitInfo,
        };
      case 'videos':
        return {
          endpoint: 'videos',
          data: data as BraveVideoSearchResponse,
          rateLimitInfo,
        };
    }
  }
}
