/**
 * @fileoverview WebSearch Tool v2
 *
 * Comprehensive web search tool exposing all Brave Search API capabilities:
 * - Multiple endpoints: Web, News, Images, Videos
 * - Full parameter support: freshness, country, language, etc.
 * - Multi-key rotation with rate limiting
 * - Domain filtering (allowed/blocked)
 *
 * The calling agent decides which endpoint and parameters to use.
 * This is a deterministic tool - same inputs always produce same outputs.
 */

import type { TronTool, TronToolResult } from '@core/types/index.js';
import { createLogger } from '@infrastructure/logging/index.js';
import { BraveKeyRotator } from './brave-key-rotator.js';
import { BraveMultiClient, type BraveSearchParams, type BraveSearchResult } from './brave-multi-client.js';
import type {
  BraveEndpoint,
  BraveWebResult,
  BraveNewsResult,
  BraveImageResult,
  BraveVideoResult,
} from './brave-types.js';

const logger = createLogger('tool:web-search-v2');

const MAX_QUERY_LENGTH = 400;

// =============================================================================
// Types
// =============================================================================

/**
 * WebSearchTool configuration
 */
export interface WebSearchV2Config {
  /** API keys for Brave Search (required, at least one) */
  apiKeys: string[];
  /** Default blocked domains (applied to all searches) */
  blockedDomains?: string[];
  /** Default allowed domains (applied to all searches) */
  allowedDomains?: string[];
  /** Request timeout in milliseconds (default: 15000) */
  timeout?: number;
}

/**
 * Formatted search result for output
 */
interface FormattedResult {
  title: string;
  url: string;
  snippet: string;
  age?: string;
  domain?: string;
  source?: string;
  duration?: string;
  dimensions?: string;
}

// =============================================================================
// Tool Implementation
// =============================================================================

/**
 * Comprehensive WebSearch tool with full Brave API support.
 */
export class WebSearchToolV2 implements TronTool {
  readonly name = 'WebSearch';
  readonly description = `Search the web using Brave Search API.

Endpoints:
- **web**: General web search (default)
- **news**: Current news articles
- **images**: Image search
- **videos**: Video search

Parameters:
- **query** (required): Search query (max 400 characters)
- **endpoint**: 'web' | 'news' | 'images' | 'videos' (default: 'web')
- **count**: Number of results (web: 1-20, news/videos: 1-50, images: 1-200)
- **freshness**: Time filter - 'pd' (day), 'pw' (week), 'pm' (month), 'py' (year)
- **country**: 2-char country code (e.g., 'US', 'GB')
- **searchLang**: Content language (e.g., 'en', 'es')
- **safesearch**: 'off' | 'moderate' | 'strict'
- **offset**: Pagination offset (0-9, web/news/videos only)
- **resultFilter**: Comma-separated types (web only): discussions,faq,infobox,news,videos,web
- **extraSnippets**: Get additional excerpts (web/news only)
- **allowedDomains**: Only include these domains
- **blockedDomains**: Exclude these domains

Tips:
- Use 'news' endpoint for current events
- Use 'freshness' to filter by recency
- Use domain filters for trusted sources
- Use WebFetch to read full content of results`;

  readonly parameters = {
    type: 'object' as const,
    properties: {
      query: {
        type: 'string' as const,
        description: 'Search query (required, max 400 characters)',
      },
      endpoint: {
        type: 'string' as const,
        enum: ['web', 'news', 'images', 'videos'] as string[],
        description: "Search endpoint (default: 'web')",
      },
      count: {
        type: 'number' as const,
        description: 'Number of results to return',
      },
      // Support old parameter name for backwards compatibility
      maxResults: {
        type: 'number' as const,
        description: 'Alias for count (backwards compatibility)',
      },
      freshness: {
        type: 'string' as const,
        description: "Time filter: 'pd' (day), 'pw' (week), 'pm' (month), 'py' (year), or date range",
      },
      country: {
        type: 'string' as const,
        description: '2-char country code (e.g., US, GB)',
      },
      searchLang: {
        type: 'string' as const,
        description: 'Content language code (e.g., en, es)',
      },
      safesearch: {
        type: 'string' as const,
        enum: ['off', 'moderate', 'strict'] as string[],
        description: 'Safe search level',
      },
      offset: {
        type: 'number' as const,
        description: 'Pagination offset (0-9, not available for images)',
      },
      resultFilter: {
        type: 'string' as const,
        description: 'Comma-separated result types (web only): discussions,faq,infobox,news,videos,web',
      },
      extraSnippets: {
        type: 'boolean' as const,
        description: 'Get additional text excerpts (web/news only)',
      },
      allowedDomains: {
        type: 'array' as const,
        items: { type: 'string' as const },
        description: 'Only include results from these domains',
      },
      blockedDomains: {
        type: 'array' as const,
        items: { type: 'string' as const },
        description: 'Exclude results from these domains',
      },
    },
    required: ['query'] as string[],
  };

  readonly category = 'network' as const;
  readonly label = 'Web Search';

  private client: BraveMultiClient;
  private configBlockedDomains: string[];
  private configAllowedDomains: string[];

  constructor(config: WebSearchV2Config) {
    // Validate at least one key is provided
    const validKeys = config.apiKeys.filter((k) => k && k.trim() !== '');
    if (validKeys.length === 0) {
      throw new Error('WebSearch requires at least one Brave Search API key');
    }

    const keyRotator = new BraveKeyRotator(validKeys);
    this.client = new BraveMultiClient({
      keyRotator,
      timeout: config.timeout,
    });

    this.configBlockedDomains = config.blockedDomains ?? [];
    this.configAllowedDomains = config.allowedDomains ?? [];

    logger.info('WebSearchToolV2 initialized', {
      keyCount: validKeys.length,
      hasBlockedDomains: this.configBlockedDomains.length > 0,
      hasAllowedDomains: this.configAllowedDomains.length > 0,
    });
  }

  async execute(args: Record<string, unknown>): Promise<TronToolResult> {
    // Validate query parameter
    const query = args.query as string | undefined;

    if (!query || typeof query !== 'string' || query.trim() === '') {
      return {
        content: 'Error: Missing required parameter "query". Please provide a search query.',
        isError: true,
        details: { error: 'Missing query parameter' } as any,
      };
    }

    const trimmedQuery = query.trim();

    if (trimmedQuery.length > MAX_QUERY_LENGTH) {
      return {
        content: `Error: Query is too long. Maximum length is ${MAX_QUERY_LENGTH} characters, got ${trimmedQuery.length}.`,
        isError: true,
        details: { error: 'Query too long', length: trimmedQuery.length } as any,
      };
    }

    // Parse endpoint
    const endpoint = (args.endpoint as BraveEndpoint | undefined) ?? 'web';

    // Parse count (with backwards compatibility for maxResults)
    const count = (args.count as number | undefined) ?? (args.maxResults as number | undefined);

    // Build search params
    const searchParams: BraveSearchParams = {
      endpoint,
      query: trimmedQuery,
      count,
      offset: args.offset as number | undefined,
      freshness: args.freshness as string | undefined,
      country: args.country as string | undefined,
      searchLang: args.searchLang as string | undefined,
      safesearch: args.safesearch as 'off' | 'moderate' | 'strict' | undefined,
      resultFilter: args.resultFilter as string | undefined,
      extraSnippets: args.extraSnippets as boolean | undefined,
    };

    // Combine config and request domain filters
    const allowedDomains = [
      ...this.configAllowedDomains,
      ...((args.allowedDomains as string[] | undefined) ?? []),
    ];
    const blockedDomains = [
      ...this.configBlockedDomains,
      ...((args.blockedDomains as string[] | undefined) ?? []),
    ];

    logger.info('WebSearch executing', {
      endpoint,
      query: trimmedQuery,
      count,
      freshness: searchParams.freshness,
      hasAllowedDomains: allowedDomains.length > 0,
      hasBlockedDomains: blockedDomains.length > 0,
    });

    const startTime = Date.now();

    try {
      const result = await this.client.search(searchParams);
      const durationMs = Date.now() - startTime;

      // Extract and format results based on endpoint
      const formattedResults = this.extractResults(result, allowedDomains, blockedDomains);

      logger.info('WebSearch completed', {
        endpoint,
        query: trimmedQuery,
        resultCount: formattedResults.length,
        durationMs,
        rateLimitRemaining: result.rateLimitInfo?.remaining,
      });

      // Handle no results
      if (formattedResults.length === 0) {
        return {
          content: `No results found for query: "${trimmedQuery}"\n\nTry:\n- Different search terms\n- More general query\n- Removing domain filters`,
          isError: false,
          details: {
            endpoint,
            results: [],
            totalResults: 0,
            query: trimmedQuery,
          },
        };
      }

      // Format results for output
      const formattedContent = this.formatResultsAsText(formattedResults, trimmedQuery, endpoint);

      return {
        content: formattedContent,
        isError: false,
        details: {
          endpoint,
          results: formattedResults,
          totalResults: formattedResults.length,
          query: trimmedQuery,
        },
      };
    } catch (error) {
      const err = error as Error;
      const durationMs = Date.now() - startTime;

      // Check for rate limiting
      const isRateLimited = err.message.includes('429') || err.message.toLowerCase().includes('rate');

      logger.error('WebSearch failed', {
        endpoint,
        query: trimmedQuery,
        error: err.message,
        durationMs,
        isRateLimited,
      });

      if (isRateLimited) {
        return {
          content: 'Error: Search rate limit exceeded. Please wait a moment before searching again.',
          isError: true,
          details: { error: 'rate_limited', query: trimmedQuery } as any,
        };
      }

      return {
        content: `Error performing search: ${err.message}`,
        isError: true,
        details: { error: err.message, query: trimmedQuery } as any,
      };
    }
  }

  /**
   * Extract and filter results from the API response.
   */
  private extractResults(
    result: BraveSearchResult,
    allowedDomains: string[],
    blockedDomains: string[]
  ): FormattedResult[] {
    let formatted: FormattedResult[] = [];

    switch (result.endpoint) {
      case 'web':
        formatted = this.formatWebResults(result.data.web?.results ?? []);
        break;
      case 'news':
        formatted = this.formatNewsResults(result.data.results ?? []);
        break;
      case 'images':
        formatted = this.formatImageResults(result.data.results ?? []);
        break;
      case 'videos':
        formatted = this.formatVideoResults(result.data.results ?? []);
        break;
    }

    // Apply domain filters
    if (allowedDomains.length > 0) {
      formatted = formatted.filter((r) => {
        const domain = this.extractDomain(r.url);
        return domain && allowedDomains.some((allowed) => this.domainMatches(domain, allowed));
      });
    }

    if (blockedDomains.length > 0) {
      formatted = formatted.filter((r) => {
        const domain = this.extractDomain(r.url);
        return !domain || !blockedDomains.some((blocked) => this.domainMatches(domain, blocked));
      });
    }

    return formatted;
  }

  /**
   * Format web search results.
   */
  private formatWebResults(results: BraveWebResult[]): FormattedResult[] {
    return results.map((r) => ({
      title: r.title,
      url: r.url,
      snippet: r.description,
      age: r.age,
      domain: this.extractDomain(r.url),
    }));
  }

  /**
   * Format news search results.
   */
  private formatNewsResults(results: BraveNewsResult[]): FormattedResult[] {
    return results.map((r) => ({
      title: r.title,
      url: r.url,
      snippet: r.description,
      age: r.age,
      domain: this.extractDomain(r.url),
      source: r.source,
    }));
  }

  /**
   * Format image search results.
   */
  private formatImageResults(results: BraveImageResult[]): FormattedResult[] {
    return results.map((r) => ({
      title: r.title,
      url: r.url,
      snippet: r.src, // Use image URL as snippet
      domain: this.extractDomain(r.url),
      dimensions: r.width && r.height ? `${r.width}x${r.height}` : undefined,
    }));
  }

  /**
   * Format video search results.
   */
  private formatVideoResults(results: BraveVideoResult[]): FormattedResult[] {
    return results.map((r) => ({
      title: r.title,
      url: r.url,
      snippet: r.description,
      age: r.age,
      domain: this.extractDomain(r.url),
      duration: r.duration,
    }));
  }

  /**
   * Format results as readable text output.
   */
  private formatResultsAsText(
    results: FormattedResult[],
    query: string,
    endpoint: BraveEndpoint
  ): string {
    const endpointLabel = endpoint === 'web' ? 'Web' : endpoint.charAt(0).toUpperCase() + endpoint.slice(1);

    const lines: string[] = [
      `${endpointLabel} search results for: "${query}"`,
      `Found ${results.length} result${results.length === 1 ? '' : 's'}:`,
      '',
    ];

    for (let i = 0; i < results.length; i++) {
      const result = results[i]!;
      lines.push(`**${i + 1}. ${result.title}**`);
      lines.push(`   ${result.url}`);

      if (result.snippet && endpoint !== 'images') {
        lines.push(`   ${result.snippet}`);
      }

      const meta: string[] = [];
      if (result.age) meta.push(result.age);
      if (result.source) meta.push(`Source: ${result.source}`);
      if (result.duration) meta.push(`Duration: ${result.duration}`);
      if (result.dimensions) meta.push(result.dimensions);

      if (meta.length > 0) {
        lines.push(`   *${meta.join(' | ')}*`);
      }

      lines.push('');
    }

    lines.push('---');
    lines.push('Use WebFetch to read the full content of any result.');

    return lines.join('\n');
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

  /**
   * Check if a hostname matches a domain pattern (including subdomains).
   */
  private domainMatches(hostname: string, domain: string): boolean {
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
}
