/**
 * @fileoverview Exa Search Provider
 *
 * Implements the SearchProvider interface for Exa Search API.
 * Key capabilities:
 * - Hour-level date filtering (the unique feature!)
 * - Category filtering (tweets, research papers, news)
 * - Neural/semantic search
 */

import { ExaClient } from '../exa-client.js';
import type { ExaSearchParams, ExaResult } from '../exa-types.js';
import {
  type SearchProvider,
  type ProviderSearchParams,
  type ProviderCapabilities,
  type UnifiedResult,
  type ContentType,
  EXA_CAPABILITIES,
  freshnessToExaDate,
  contentTypeToExaCategory,
} from './types.js';

/**
 * Exa provider configuration
 */
export interface ExaProviderConfig {
  /** Exa API key (required) */
  apiKey: string;
  /** Base URL override */
  baseUrl?: string;
  /** Request timeout in milliseconds */
  timeout?: number;
}

/**
 * Exa Search Provider implementation.
 *
 * Unique capabilities over Brave:
 * - Hour-level freshness filtering
 * - Exact date range filtering (ISO 8601)
 * - Tweet/social search
 * - Research paper search
 * - Neural/semantic search
 */
export class ExaProvider implements SearchProvider {
  readonly name = 'exa' as const;
  readonly capabilities: ProviderCapabilities = EXA_CAPABILITIES;

  private client: ExaClient;

  constructor(config: ExaProviderConfig) {
    this.client = new ExaClient({
      apiKey: config.apiKey,
      baseUrl: config.baseUrl,
      timeout: config.timeout,
    });
  }

  /**
   * Execute a search query.
   *
   * @param params - Normalized search parameters
   * @returns Array of unified results
   */
  async search(params: ProviderSearchParams): Promise<UnifiedResult[]> {
    const exaParams = this.translateParams(params);
    const response = await this.client.search(exaParams);

    // Determine content type for results
    const contentType = params.contentType ?? 'web';

    return response.results.map((result) => this.normalizeResult(result, contentType));
  }

  /**
   * Translate unified params to Exa-specific params.
   */
  private translateParams(params: ProviderSearchParams): ExaSearchParams {
    const exaParams: ExaSearchParams = {
      query: params.query,
    };

    // Count -> numResults
    if (params.count !== undefined) {
      exaParams.numResults = params.count;
    }

    // Date filtering - exact dates take precedence over freshness
    if (params.startDate) {
      exaParams.startPublishedDate = params.startDate;
    } else if (params.freshness) {
      exaParams.startPublishedDate = freshnessToExaDate(params.freshness);
    }

    if (params.endDate) {
      exaParams.endPublishedDate = params.endDate;
    }

    // Content type -> category
    if (params.contentType) {
      const category = contentTypeToExaCategory(params.contentType);
      if (category) {
        exaParams.category = category;
      }
    }

    // Domain filtering
    if (params.includeDomains && params.includeDomains.length > 0) {
      exaParams.includeDomains = params.includeDomains;
    }

    if (params.excludeDomains && params.excludeDomains.length > 0) {
      exaParams.excludeDomains = params.excludeDomains;
    }

    // Request highlights for snippets
    // Exa recommends numSentences: 6, highlightsPerUrl: 6 for good snippets
    exaParams.contents = {
      highlights: { numSentences: 6, highlightsPerUrl: 6 },
    };

    return exaParams;
  }

  /**
   * Normalize an Exa result to unified format.
   */
  private normalizeResult(result: ExaResult, contentType: ContentType): UnifiedResult {
    // Build snippet from highlights or text
    let snippet = '';
    if (result.highlights && result.highlights.length > 0) {
      snippet = result.highlights.join(' ');
    } else if (result.text) {
      // Truncate text to first 200 chars as snippet
      snippet = result.text.length > 200 ? result.text.slice(0, 200) + '...' : result.text;
    }

    return {
      title: result.title,
      url: result.url,
      snippet,
      publishedDate: result.publishedDate,
      age: undefined, // Exa doesn't provide human-readable age
      source: 'exa',
      contentType,
      author: result.author,
      domain: this.extractDomain(result.url),
      score: result.score,
    };
  }

  /**
   * Extract domain from URL.
   */
  private extractDomain(url: string): string | undefined {
    try {
      const parsed = new URL(url);
      return parsed.hostname.toLowerCase();
    } catch {
      return undefined;
    }
  }
}
