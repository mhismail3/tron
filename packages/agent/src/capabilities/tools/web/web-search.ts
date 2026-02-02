/**
 * @fileoverview WebSearch Tool
 *
 * Searches the web using the Brave Search API and returns formatted results.
 * Provides up-to-date information beyond the model's training cutoff.
 */

import type { TronTool, TronToolResult } from '@core/types/index.js';
import { createLogger } from '@infrastructure/logging/index.js';
import { BraveSearchClient } from './brave-search.js';
import type {
  WebSearchParams,
  WebSearchResult,
  WebSearchToolConfig,
  SearchResultItem,
} from './types.js';

const logger = createLogger('tool:web-search');

const DEFAULT_MAX_RESULTS = 10;
const MAX_ALLOWED_RESULTS = 20;
const MAX_QUERY_LENGTH = 400;

/**
 * WebSearch tool for searching the web
 */
export class WebSearchTool implements TronTool<WebSearchParams, WebSearchResult> {
  readonly name = 'WebSearch';
  readonly description = `Search the web for current information using Brave Search.

Returns a list of search results with titles, URLs, and snippets.
Use this when you need:
- Up-to-date information beyond your training cutoff
- Current news, documentation, or announcements
- Information about recent events or releases

Parameters:
- **query**: Search query (required, max 400 characters)
- **maxResults**: Maximum results to return (optional, default: 10, max: 20)
- **allowedDomains**: Only include results from these domains (optional)
- **blockedDomains**: Exclude results from these domains (optional)

Tips:
- Be specific in your query for better results
- Use WebFetch to read the full content of interesting results
- Domain filters help focus results on trusted sources`;

  readonly parameters = {
    type: 'object' as const,
    properties: {
      query: {
        type: 'string' as const,
        description: 'The search query (max 400 characters).',
      },
      maxResults: {
        type: 'number' as const,
        description: 'Maximum number of results to return (default: 10, max: 20).',
      },
      allowedDomains: {
        type: 'array' as const,
        items: { type: 'string' as const },
        description: 'Only include results from these domains.',
      },
      blockedDomains: {
        type: 'array' as const,
        items: { type: 'string' as const },
        description: 'Exclude results from these domains.',
      },
    },
    required: ['query'] as string[],
  };

  readonly category = 'network' as const;
  readonly label = 'Web Search';

  private client: BraveSearchClient;
  private config: WebSearchToolConfig;

  constructor(config: WebSearchToolConfig) {
    if (!config.apiKey || config.apiKey.trim() === '') {
      throw new Error(
        'WebSearch requires a Brave Search API key. Set BRAVE_SEARCH_API_KEY env var.'
      );
    }

    this.config = config;
    this.client = new BraveSearchClient({
      apiKey: config.apiKey,
      timeout: config.timeout,
    });
  }

  async execute(args: Record<string, unknown>): Promise<TronToolResult<WebSearchResult>> {
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

    // Validate query length
    if (trimmedQuery.length > MAX_QUERY_LENGTH) {
      return {
        content: `Error: Query is too long. Maximum length is ${MAX_QUERY_LENGTH} characters, got ${trimmedQuery.length}.`,
        isError: true,
        details: { error: 'Query too long', length: trimmedQuery.length } as any,
      };
    }

    // Parse optional parameters
    const maxResults = Math.min(
      (args.maxResults as number | undefined) ?? this.config.defaultMaxResults ?? DEFAULT_MAX_RESULTS,
      this.config.maxAllowedResults ?? MAX_ALLOWED_RESULTS
    );

    const allowedDomains = [
      ...(this.config.allowedDomains ?? []),
      ...((args.allowedDomains as string[] | undefined) ?? []),
    ];

    const blockedDomains = [
      ...(this.config.blockedDomains ?? []),
      ...((args.blockedDomains as string[] | undefined) ?? []),
    ];

    logger.info('WebSearch starting', {
      query: trimmedQuery,
      maxResults,
      allowedDomains: allowedDomains.length > 0 ? allowedDomains : undefined,
      blockedDomains: blockedDomains.length > 0 ? blockedDomains : undefined,
    });

    const searchStartTime = Date.now();

    try {
      // Search using Brave API
      logger.debug('Calling Brave Search API', {
        query: trimmedQuery,
        count: maxResults,
        hasAllowedDomains: allowedDomains.length > 0,
        hasBlockedDomains: blockedDomains.length > 0,
      });

      const searchResult = await this.client.search(trimmedQuery, {
        count: maxResults,
        allowedDomains: allowedDomains.length > 0 ? allowedDomains : undefined,
        blockedDomains: blockedDomains.length > 0 ? blockedDomains : undefined,
      });

      const searchDuration = Date.now() - searchStartTime;

      // Apply maxResults limit (in case API returns more than requested)
      const limitedResults = searchResult.results.slice(0, maxResults);

      logger.info('WebSearch completed', {
        query: trimmedQuery,
        totalResults: limitedResults.length,
        durationMs: searchDuration,
        apiRawResultCount: searchResult.results.length,
      });

      // Log result domains for debugging
      if (limitedResults.length > 0) {
        const domains = limitedResults.map((r) => {
          try {
            return new URL(r.url).hostname;
          } catch {
            return 'unknown';
          }
        });
        logger.debug('Search result domains', { query: trimmedQuery, domains });
      }

      // Handle no results
      if (limitedResults.length === 0) {
        return {
          content: `No results found for query: "${trimmedQuery}"\n\nTry:\n- Different search terms\n- More general query\n- Removing domain filters`,
          isError: false,
          details: {
            results: [],
            totalResults: 0,
            query: trimmedQuery,
          },
        };
      }

      // Format results as readable text
      const formattedContent = formatResultsAsText(limitedResults, trimmedQuery);

      return {
        content: formattedContent,
        isError: false,
        details: {
          results: limitedResults,
          totalResults: limitedResults.length,
          query: trimmedQuery,
        },
      };
    } catch (error) {
      const err = error as Error;
      const searchDuration = Date.now() - searchStartTime;

      // Check for rate limiting
      const isRateLimited = err.message.includes('429') || err.message.toLowerCase().includes('rate');

      logger.error('WebSearch failed', {
        query: trimmedQuery,
        error: err.message,
        durationMs: searchDuration,
        isRateLimited,
        errorType: err.name,
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
}

/**
 * Format search results as readable text
 */
function formatResultsAsText(results: SearchResultItem[], query: string): string {
  const lines: string[] = [
    `Search results for: "${query}"`,
    `Found ${results.length} result${results.length === 1 ? '' : 's'}:`,
    '',
  ];

  for (let i = 0; i < results.length; i++) {
    const result = results[i]!;
    lines.push(`**${i + 1}. ${result.title}**`);
    lines.push(`   ${result.url}`);
    if (result.snippet) {
      lines.push(`   ${result.snippet}`);
    }
    if (result.age) {
      lines.push(`   *${result.age}*`);
    }
    lines.push('');
  }

  lines.push('---');
  lines.push('Use WebFetch to read the full content of any result.');

  return lines.join('\n');
}
