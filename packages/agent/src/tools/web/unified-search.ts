/**
 * @fileoverview Unified Search Tool
 *
 * Multi-provider search tool that routes queries to Brave and/or Exa
 * based on their capabilities and the request parameters.
 *
 * Key features:
 * - Automatic provider selection based on content type
 * - Parallel provider execution
 * - Result merging and deduplication
 * - Domain filtering
 * - Hour-level freshness via Exa
 */

import type { TronTool, TronToolResult } from '../../types/index.js';
import { createLogger } from '../../logging/index.js';
import type {
  SearchProvider,
  ProviderName,
  ProviderSearchParams,
  UnifiedResult,
  ContentType,
  Freshness,
} from './providers/types.js';

const logger = createLogger('tool:unified-search');

const MAX_QUERY_LENGTH = 400;

// =============================================================================
// Types
// =============================================================================

/**
 * Unified search tool configuration
 */
export interface UnifiedSearchConfig {
  /** Available providers */
  providers: {
    brave?: SearchProvider;
    exa?: SearchProvider;
  };
  /** Default blocked domains (applied to all searches) */
  blockedDomains?: string[];
}

/**
 * Unified search parameters (agent-facing)
 */
export interface UnifiedSearchParams {
  /** Search query (required) */
  query: string;

  /** Which providers to use (default: all available) */
  providers?: ProviderName[];

  /** Number of results per provider (default: 10) */
  count?: number;

  /** Time filter */
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

// =============================================================================
// Tool Implementation
// =============================================================================

/**
 * Unified multi-provider search tool.
 *
 * Routes search queries to available providers based on their capabilities
 * and the request parameters. Results are merged and deduplicated.
 */
export class UnifiedSearchTool implements TronTool {
  readonly name = 'WebSearch';
  readonly description: string;
  readonly parameters = {
    type: 'object' as const,
    properties: {
      query: {
        type: 'string' as const,
        description: 'Search query (required, max 400 characters)',
      },
      providers: {
        type: 'array' as const,
        items: { type: 'string' as const, enum: ['brave', 'exa'] as string[] },
        description: "Which providers to use (default: all available). Use 'exa' for hour-level freshness, tweets, or research papers.",
      },
      count: {
        type: 'number' as const,
        description: 'Number of results per provider (default: 10)',
      },
      freshness: {
        type: 'string' as const,
        enum: ['hour', 'day', 'week', 'month', 'year'] as string[],
        description: "Time filter. 'hour' only works with Exa provider.",
      },
      startDate: {
        type: 'string' as const,
        description: 'Exact start date (ISO 8601) - Exa only. Use for precise date ranges.',
      },
      endDate: {
        type: 'string' as const,
        description: 'Exact end date (ISO 8601) - Exa only',
      },
      contentType: {
        type: 'string' as const,
        enum: ['web', 'news', 'images', 'videos', 'social', 'research'] as string[],
        description: "Content type. 'social' (tweets) and 'research' only work with Exa. 'images' and 'videos' only work with Brave.",
      },
      includeDomains: {
        type: 'array' as const,
        items: { type: 'string' as const },
        description: 'Only include results from these domains',
      },
      excludeDomains: {
        type: 'array' as const,
        items: { type: 'string' as const },
        description: 'Exclude results from these domains',
      },
    },
    required: ['query'] as string[],
  };

  readonly category = 'network' as const;
  readonly label = 'Web Search';

  private braveProvider?: SearchProvider;
  private exaProvider?: SearchProvider;
  private configBlockedDomains: string[];
  private availableProviders: ProviderName[];

  constructor(config: UnifiedSearchConfig) {
    this.braveProvider = config.providers.brave;
    this.exaProvider = config.providers.exa;
    this.configBlockedDomains = config.blockedDomains ?? [];

    // Track available providers
    this.availableProviders = [];
    if (this.braveProvider) this.availableProviders.push('brave');
    if (this.exaProvider) this.availableProviders.push('exa');

    if (this.availableProviders.length === 0) {
      throw new Error('UnifiedSearchTool requires at least one provider');
    }

    // Build description based on available providers
    this.description = this.buildDescription();

    logger.info('UnifiedSearchTool initialized', {
      providers: this.availableProviders,
      hasBlockedDomains: this.configBlockedDomains.length > 0,
    });
  }

  async execute(args: Record<string, unknown>): Promise<TronToolResult> {
    // Validate query
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
        content: `Error: Query is too long. Maximum length is ${MAX_QUERY_LENGTH} characters.`,
        isError: true,
        details: { error: 'Query too long' } as any,
      };
    }

    // Parse parameters
    const params: UnifiedSearchParams = {
      query: trimmedQuery,
      providers: args.providers as ProviderName[] | undefined,
      count: args.count as number | undefined,
      freshness: args.freshness as Freshness | undefined,
      startDate: args.startDate as string | undefined,
      endDate: args.endDate as string | undefined,
      contentType: args.contentType as ContentType | undefined,
      includeDomains: args.includeDomains as string[] | undefined,
      excludeDomains: args.excludeDomains as string[] | undefined,
    };

    // Determine which providers to query
    const providersToUse = this.selectProviders(params);

    if (providersToUse.length === 0) {
      return {
        content: `Error: No available provider supports the requested content type "${params.contentType}".`,
        isError: true,
        details: { error: 'No suitable provider' } as any,
      };
    }

    logger.info('UnifiedSearch executing', {
      query: trimmedQuery,
      providers: providersToUse,
      contentType: params.contentType,
      freshness: params.freshness,
    });

    const startTime = Date.now();

    try {
      // Execute searches in parallel
      const results = await this.executeSearches(providersToUse, params);
      const durationMs = Date.now() - startTime;

      // Apply domain filtering
      const filteredResults = this.filterResults(results, params);

      // Deduplicate by URL
      const deduped = this.deduplicateResults(filteredResults);

      logger.info('UnifiedSearch completed', {
        query: trimmedQuery,
        totalResults: deduped.length,
        providers: providersToUse,
        durationMs,
      });

      // Handle no results
      if (deduped.length === 0) {
        return {
          content: `No results found for query: "${trimmedQuery}"\n\nTry:\n- Different search terms\n- Broader query\n- Removing domain filters`,
          isError: false,
          details: {
            query: trimmedQuery,
            results: [],
            totalResults: 0,
            providers: providersToUse,
          },
        };
      }

      // Format results
      const formattedContent = this.formatResults(deduped, trimmedQuery, providersToUse);

      return {
        content: formattedContent,
        isError: false,
        details: {
          query: trimmedQuery,
          results: deduped,
          totalResults: deduped.length,
          providers: providersToUse,
        },
      };
    } catch (error) {
      const err = error as Error;
      const durationMs = Date.now() - startTime;

      logger.error('UnifiedSearch failed', {
        query: trimmedQuery,
        error: err.message,
        durationMs,
      });

      return {
        content: `Error performing search: ${err.message}`,
        isError: true,
        details: { error: err.message, query: trimmedQuery } as any,
      };
    }
  }

  /**
   * Select which providers to query based on request and capabilities.
   */
  private selectProviders(params: UnifiedSearchParams): ProviderName[] {
    // If specific providers requested, use those (filtered by availability)
    if (params.providers && params.providers.length > 0) {
      return params.providers.filter((p) => this.availableProviders.includes(p));
    }

    // Auto-select based on content type
    if (params.contentType) {
      const suitable: ProviderName[] = [];

      if (this.braveProvider?.capabilities.supportedContentTypes.includes(params.contentType)) {
        suitable.push('brave');
      }
      if (this.exaProvider?.capabilities.supportedContentTypes.includes(params.contentType)) {
        suitable.push('exa');
      }

      return suitable;
    }

    // Default: use all available
    return [...this.availableProviders];
  }

  /**
   * Execute searches on selected providers in parallel.
   */
  private async executeSearches(
    providers: ProviderName[],
    params: UnifiedSearchParams
  ): Promise<UnifiedResult[]> {
    const searchParams: ProviderSearchParams = {
      query: params.query,
      count: params.count,
      freshness: params.freshness,
      startDate: params.startDate,
      endDate: params.endDate,
      contentType: params.contentType,
      includeDomains: params.includeDomains,
      excludeDomains: params.excludeDomains,
    };

    const searches: Promise<UnifiedResult[]>[] = [];
    const errors: Error[] = [];

    for (const providerName of providers) {
      const provider = providerName === 'brave' ? this.braveProvider : this.exaProvider;
      if (!provider) continue;

      searches.push(
        provider.search(searchParams).catch((error) => {
          logger.warn(`Provider ${providerName} failed`, { error: error.message });
          errors.push(error);
          return []; // Return empty on failure, other providers may succeed
        })
      );
    }

    const results = await Promise.all(searches);

    // If all providers failed, throw the first error
    if (results.every((r) => r.length === 0) && errors.length > 0) {
      throw errors[0];
    }

    return results.flat();
  }

  /**
   * Filter results by domain rules.
   */
  private filterResults(results: UnifiedResult[], params: UnifiedSearchParams): UnifiedResult[] {
    let filtered = results;

    // Combine config and request domain filters
    const includeDomains = params.includeDomains ?? [];
    const excludeDomains = [
      ...this.configBlockedDomains,
      ...(params.excludeDomains ?? []),
    ];

    // Apply include filter
    if (includeDomains.length > 0) {
      filtered = filtered.filter((r) => {
        const domain = r.domain ?? this.extractDomain(r.url);
        return domain && includeDomains.some((allowed) => this.domainMatches(domain, allowed));
      });
    }

    // Apply exclude filter
    if (excludeDomains.length > 0) {
      filtered = filtered.filter((r) => {
        const domain = r.domain ?? this.extractDomain(r.url);
        return !domain || !excludeDomains.some((blocked) => this.domainMatches(domain, blocked));
      });
    }

    return filtered;
  }

  /**
   * Deduplicate results by URL (keeps first occurrence).
   */
  private deduplicateResults(results: UnifiedResult[]): UnifiedResult[] {
    const seen = new Set<string>();
    return results.filter((r) => {
      const normalized = r.url.toLowerCase();
      if (seen.has(normalized)) {
        return false;
      }
      seen.add(normalized);
      return true;
    });
  }

  /**
   * Format results as readable text.
   */
  private formatResults(
    results: UnifiedResult[],
    query: string,
    providers: ProviderName[]
  ): string {
    const providerLabel = providers.length > 1 ? providers.join('+') : providers[0];

    const lines: string[] = [
      `Search results for: "${query}" (via ${providerLabel})`,
      `Found ${results.length} result${results.length === 1 ? '' : 's'}:`,
      '',
    ];

    for (let i = 0; i < results.length; i++) {
      const r = results[i]!;
      lines.push(`**${i + 1}. ${r.title}** [${r.source}]`);
      lines.push(`   ${r.url}`);

      if (r.snippet) {
        lines.push(`   ${r.snippet}`);
      }

      const meta: string[] = [];
      if (r.age) meta.push(r.age);
      if (r.publishedDate && !r.age) {
        meta.push(new Date(r.publishedDate).toLocaleDateString());
      }
      if (r.author) meta.push(`by ${r.author}`);

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
   * Build tool description based on available providers.
   */
  private buildDescription(): string {
    const parts: string[] = ['Search the web using multiple providers.'];

    if (this.braveProvider && this.exaProvider) {
      parts.push('\n\n**Providers:**');
      parts.push('- **brave**: Fast general search, news, images, videos');
      parts.push('- **exa**: Semantic search, hour-level time filters, tweets, research papers');
      parts.push('\n**When to use each:**');
      parts.push('- Recent news (last hour): Use exa with freshness: "hour"');
      parts.push('- Social media/tweets: Use contentType: "social" (Exa only)');
      parts.push('- Research papers: Use contentType: "research" (Exa only)');
      parts.push('- Images/videos: Use contentType: "images" or "videos" (Brave only)');
      parts.push('- General web search: Use both for comprehensive results');
    } else if (this.braveProvider) {
      parts.push('\n**Provider:** Brave Search');
      parts.push('\nSupports: web, news, images, videos');
      parts.push('Freshness: day, week, month, year');
    } else if (this.exaProvider) {
      parts.push('\n**Provider:** Exa Search');
      parts.push('\nSupports: web, news, social (tweets), research');
      parts.push('Freshness: hour, day, week, month, year (with exact date ranges)');
    }

    return parts.join('\n');
  }

  /**
   * Extract domain from URL.
   */
  private extractDomain(url: string): string | undefined {
    try {
      return new URL(url).hostname.toLowerCase();
    } catch {
      return undefined;
    }
  }

  /**
   * Check if hostname matches domain pattern.
   */
  private domainMatches(hostname: string, domain: string): boolean {
    const h = hostname.toLowerCase();
    const d = domain.toLowerCase();
    return h === d || h.endsWith(`.${d}`);
  }
}
