/**
 * @fileoverview Brave Search Provider
 *
 * Implements the SearchProvider interface for Brave Search API.
 * Wraps the existing BraveMultiClient for use with the unified search tool.
 *
 * Key capabilities:
 * - Multiple endpoints: web, news, images, videos
 * - Multi-key rotation for rate limiting
 * - Day/week/month/year freshness filtering (no hour support)
 */

import { BraveMultiClient, type BraveSearchParams, type BraveSearchResult } from '../brave-multi-client.js';
import { BraveKeyRotator } from '../brave-key-rotator.js';
import type {
  BraveEndpoint,
  BraveWebResult,
  BraveNewsResult,
  BraveImageResult,
  BraveVideoResult,
} from '../brave-types.js';
import {
  type SearchProvider,
  type ProviderSearchParams,
  type ProviderCapabilities,
  type UnifiedResult,
  type ContentType,
  BRAVE_CAPABILITIES,
  freshnessToBrave,
  contentTypeToBraveEndpoint,
} from './types.js';

/**
 * Brave provider configuration
 */
export interface BraveProviderConfig {
  /** Brave Search API keys (at least one required) */
  apiKeys: string[];
  /** Base URL override */
  baseUrl?: string;
  /** Request timeout in milliseconds */
  timeout?: number;
}

/**
 * Brave Search Provider implementation.
 *
 * Capabilities:
 * - Web, news, images, videos search
 * - Multi-key rotation for rate limiting
 * - Day/week/month/year freshness filtering
 *
 * Limitations:
 * - No hour-level freshness (falls back to day)
 * - No social/research content types
 * - No exact date range filtering
 */
export class BraveProvider implements SearchProvider {
  readonly name = 'brave' as const;
  readonly capabilities: ProviderCapabilities = BRAVE_CAPABILITIES;

  private client: BraveMultiClient;

  constructor(config: BraveProviderConfig) {
    const keyRotator = new BraveKeyRotator(config.apiKeys);
    this.client = new BraveMultiClient({
      keyRotator,
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
    // Determine endpoint from content type
    const endpoint = params.contentType
      ? contentTypeToBraveEndpoint(params.contentType)
      : 'web';

    // Return empty if content type is not supported
    if (!endpoint) {
      return [];
    }

    const braveParams = this.translateParams(params, endpoint);
    const response = await this.client.search(braveParams);

    return this.normalizeResults(response);
  }

  /**
   * Translate unified params to Brave-specific params.
   */
  private translateParams(params: ProviderSearchParams, endpoint: BraveEndpoint): BraveSearchParams {
    const braveParams: BraveSearchParams = {
      endpoint,
      query: params.query,
    };

    // Count
    if (params.count !== undefined) {
      braveParams.count = params.count;
    }

    // Freshness (Brave uses codes like 'pd', 'pw', 'pm', 'py')
    // Note: 'hour' falls back to 'day' (pd)
    if (params.freshness) {
      braveParams.freshness = freshnessToBrave(params.freshness);
    }

    // Note: Brave doesn't support domain filtering in API
    // We handle domain filtering at the tool level

    return braveParams;
  }

  /**
   * Normalize Brave results to unified format.
   */
  private normalizeResults(response: BraveSearchResult): UnifiedResult[] {
    switch (response.endpoint) {
      case 'web':
        return this.normalizeWebResults(response.data.web?.results ?? []);
      case 'news':
        return this.normalizeNewsResults(response.data.results ?? []);
      case 'images':
        return this.normalizeImageResults(response.data.results ?? []);
      case 'videos':
        return this.normalizeVideoResults(response.data.results ?? []);
    }
  }

  /**
   * Normalize web search results.
   */
  private normalizeWebResults(results: BraveWebResult[]): UnifiedResult[] {
    return results.map((r) => ({
      title: r.title,
      url: r.url,
      snippet: r.description,
      publishedDate: r.page_age,
      age: r.age,
      source: 'brave' as const,
      contentType: 'web' as ContentType,
      author: undefined,
      domain: this.extractDomain(r.url),
      score: undefined,
    }));
  }

  /**
   * Normalize news search results.
   */
  private normalizeNewsResults(results: BraveNewsResult[]): UnifiedResult[] {
    return results.map((r) => ({
      title: r.title,
      url: r.url,
      snippet: r.description,
      publishedDate: r.page_age,
      age: r.age,
      source: 'brave' as const,
      contentType: 'news' as ContentType,
      author: undefined,
      domain: this.extractDomain(r.url),
      score: undefined,
    }));
  }

  /**
   * Normalize image search results.
   */
  private normalizeImageResults(results: BraveImageResult[]): UnifiedResult[] {
    return results.map((r) => ({
      title: r.title,
      url: r.url,
      snippet: r.src, // Use image URL as snippet
      publishedDate: undefined,
      age: undefined,
      source: 'brave' as const,
      contentType: 'images' as ContentType,
      author: undefined,
      domain: this.extractDomain(r.url),
      score: undefined,
    }));
  }

  /**
   * Normalize video search results.
   */
  private normalizeVideoResults(results: BraveVideoResult[]): UnifiedResult[] {
    return results.map((r) => ({
      title: r.title,
      url: r.url,
      snippet: r.description,
      publishedDate: r.page_age,
      age: r.age,
      source: 'brave' as const,
      contentType: 'videos' as ContentType,
      author: undefined,
      domain: this.extractDomain(r.url),
      score: undefined,
    }));
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
