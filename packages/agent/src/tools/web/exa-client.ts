/**
 * @fileoverview Exa Search API Client
 *
 * Client for the Exa Search API with full parameter support:
 * - Neural, auto, fast, and deep search modes
 * - Hour-level date filtering (the key capability!)
 * - Category filtering (tweets, research papers, news, etc.)
 * - Domain filtering
 * - Content retrieval (text, highlights, summary)
 *
 * API Documentation: https://docs.exa.ai
 */

import { createLogger } from '../../logging/index.js';
import {
  type ExaClientConfig,
  type ExaSearchParams,
  type ExaSearchResponse,
  EXA_DEFAULT_BASE_URL,
  EXA_DEFAULT_TIMEOUT,
  EXA_MAX_RESULTS,
} from './exa-types.js';

const logger = createLogger('exa-client');

/**
 * Convert camelCase string to snake_case.
 * E.g., "numResults" -> "num_results", "startPublishedDate" -> "start_published_date"
 */
function camelToSnake(str: string): string {
  return str.replace(/[A-Z]/g, (letter) => `_${letter.toLowerCase()}`);
}

/**
 * Recursively convert all object keys from camelCase to snake_case.
 * The Exa REST API expects snake_case parameter names.
 */
function toSnakeCase(obj: Record<string, unknown>): Record<string, unknown> {
  const result: Record<string, unknown> = {};

  for (const [key, value] of Object.entries(obj)) {
    const snakeKey = camelToSnake(key);

    if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
      result[snakeKey] = toSnakeCase(value as Record<string, unknown>);
    } else {
      result[snakeKey] = value;
    }
  }

  return result;
}

/**
 * Exa Search API client.
 *
 * Key features:
 * - Hour-level date filtering via startPublishedDate/endPublishedDate
 * - Category filtering for tweets, research papers, etc.
 * - Multiple search modes (neural, auto, fast, deep)
 *
 * Usage:
 * ```typescript
 * const client = new ExaClient({ apiKey: 'your-key' });
 *
 * // Search with hour-level filtering
 * const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString();
 * const results = await client.search({
 *   query: 'breaking AI news',
 *   startPublishedDate: oneHourAgo,
 * });
 *
 * // Search tweets
 * const tweets = await client.search({
 *   query: 'GPT-5 release',
 *   category: 'tweet',
 * });
 *
 * // Search research papers
 * const papers = await client.search({
 *   query: 'transformer architecture',
 *   category: 'research paper',
 *   type: 'neural',
 * });
 * ```
 */
export class ExaClient {
  private apiKey: string;
  private baseUrl: string;
  private timeout: number;

  constructor(config: ExaClientConfig) {
    this.apiKey = config.apiKey;
    this.baseUrl = config.baseUrl ?? EXA_DEFAULT_BASE_URL;
    this.timeout = config.timeout ?? EXA_DEFAULT_TIMEOUT;
  }

  /**
   * Execute a search query.
   *
   * @param params - Search parameters
   * @returns Search response with results
   */
  async search(params: ExaSearchParams): Promise<ExaSearchResponse> {
    const url = `${this.baseUrl}/search`;

    // Build request body, only including defined values
    const body = this.buildRequestBody(params);

    logger.debug('Exa API request', {
      url,
      query: params.query,
      type: params.type,
      category: params.category,
      numResults: body.numResults,
      hasDateFilter: !!params.startPublishedDate || !!params.endPublishedDate,
    });

    const startTime = Date.now();

    const response = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': this.apiKey,
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(this.timeout),
    });

    const durationMs = Date.now() - startTime;

    logger.debug('Exa API response', {
      status: response.status,
      durationMs,
    });

    if (!response.ok) {
      const errorText = await response.text().catch(() => 'Unknown error');
      let errorMessage = `Exa API error: ${response.status}`;

      // Try to parse error details
      try {
        const errorJson = JSON.parse(errorText);
        if (errorJson.message) {
          errorMessage += ` - ${errorJson.message}`;
        } else if (errorJson.error) {
          errorMessage += ` - ${errorJson.error}`;
        }
      } catch {
        if (errorText) {
          errorMessage += ` - ${errorText}`;
        }
      }

      throw new Error(errorMessage);
    }

    const data = (await response.json()) as ExaSearchResponse;

    logger.debug('Exa search completed', {
      requestId: data.requestId,
      resultCount: data.results.length,
      durationMs,
    });

    return data;
  }

  /**
   * Build the request body, only including defined values.
   * Converts all keys to snake_case for the Exa REST API.
   */
  private buildRequestBody(params: ExaSearchParams): Record<string, unknown> {
    const body: Record<string, unknown> = {
      query: params.query,
    };

    // Optional parameters - only include if defined
    if (params.type !== undefined) {
      body.type = params.type;
    }

    if (params.category !== undefined) {
      body.category = params.category;
    }

    if (params.numResults !== undefined) {
      // Clamp to max results
      body.numResults = Math.min(params.numResults, EXA_MAX_RESULTS);
    }

    if (params.startPublishedDate !== undefined) {
      body.startPublishedDate = params.startPublishedDate;
    }

    if (params.endPublishedDate !== undefined) {
      body.endPublishedDate = params.endPublishedDate;
    }

    if (params.startCrawlDate !== undefined) {
      body.startCrawlDate = params.startCrawlDate;
    }

    if (params.endCrawlDate !== undefined) {
      body.endCrawlDate = params.endCrawlDate;
    }

    if (params.includeDomains !== undefined && params.includeDomains.length > 0) {
      body.includeDomains = params.includeDomains;
    }

    if (params.excludeDomains !== undefined && params.excludeDomains.length > 0) {
      body.excludeDomains = params.excludeDomains;
    }

    if (params.includeText !== undefined && params.includeText.length > 0) {
      body.includeText = params.includeText;
    }

    if (params.excludeText !== undefined && params.excludeText.length > 0) {
      body.excludeText = params.excludeText;
    }

    if (params.contents !== undefined) {
      body.contents = params.contents;
    }

    if (params.useAutoprompt !== undefined) {
      body.useAutoprompt = params.useAutoprompt;
    }

    // Convert all keys to snake_case for Exa REST API
    // e.g., numResults -> num_results, startPublishedDate -> start_published_date
    return toSnakeCase(body);
  }
}
