/**
 * @fileoverview Tests for BraveMultiClient
 *
 * TDD: Tests for multi-endpoint Brave Search client.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import {
  BraveMultiClient,
  type BraveSearchParams,
  type BraveMultiClientConfig,
} from '../brave-multi-client.js';
import { BraveKeyRotator } from '../brave-key-rotator.js';
import type {
  BraveWebSearchResponse,
  BraveNewsSearchResponse,
  BraveImageSearchResponse,
  BraveVideoSearchResponse,
} from '../brave-types.js';

// Mock fetch
const mockFetch = vi.fn();

describe('BraveMultiClient', () => {
  let client: BraveMultiClient;
  let keyRotator: BraveKeyRotator;
  let originalFetch: typeof globalThis.fetch;

  beforeEach(() => {
    originalFetch = globalThis.fetch;
    globalThis.fetch = mockFetch as unknown as typeof fetch;
    mockFetch.mockClear();

    keyRotator = new BraveKeyRotator(['test-api-key-1', 'test-api-key-2']);
    client = new BraveMultiClient({ keyRotator });
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  describe('constructor', () => {
    it('should create client with key rotator', () => {
      const client = new BraveMultiClient({ keyRotator });
      expect(client).toBeDefined();
    });

    it('should accept custom base URL', () => {
      const client = new BraveMultiClient({
        keyRotator,
        baseUrl: 'https://custom.api.com',
      });
      expect(client).toBeDefined();
    });

    it('should accept custom timeout', () => {
      const client = new BraveMultiClient({
        keyRotator,
        timeout: 5000,
      });
      expect(client).toBeDefined();
    });
  });

  describe('web search', () => {
    it('should make correct API request for web search', async () => {
      const mockResponse: BraveWebSearchResponse = {
        query: { original: 'test query' },
        web: { results: [] },
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      );

      await client.search({
        endpoint: 'web',
        query: 'test query',
      });

      expect(mockFetch).toHaveBeenCalledTimes(1);
      const [url, options] = mockFetch.mock.calls[0] as [string, RequestInit];

      expect(url).toContain('api.search.brave.com');
      expect(url).toContain('/res/v1/web/search');
      expect(url).toContain('q=test+query');
      expect(options.headers).toHaveProperty('X-Subscription-Token');
    });

    it('should include web-specific parameters', async () => {
      const mockResponse: BraveWebSearchResponse = {
        query: { original: 'test' },
        web: { results: [] },
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      await client.search({
        endpoint: 'web',
        query: 'test',
        count: 15,
        offset: 2,
        freshness: 'pw',
        country: 'US',
        searchLang: 'en',
        safesearch: 'moderate',
        resultFilter: 'web,news',
        extraSnippets: true,
      });

      const url = mockFetch.mock.calls[0][0] as string;
      expect(url).toContain('count=15');
      expect(url).toContain('offset=2');
      expect(url).toContain('freshness=pw');
      expect(url).toContain('country=US');
      expect(url).toContain('search_lang=en');
      expect(url).toContain('safesearch=moderate');
      expect(url).toContain('result_filter=web%2Cnews');
      expect(url).toContain('extra_snippets=true');
    });

    it('should clamp count to web limits (1-20)', async () => {
      const mockResponse: BraveWebSearchResponse = {
        query: { original: 'test' },
        web: { results: [] },
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      await client.search({
        endpoint: 'web',
        query: 'test',
        count: 100, // Too high, should be clamped to 20
      });

      const url = mockFetch.mock.calls[0][0] as string;
      expect(url).toContain('count=20');
    });

    it('should return web search results', async () => {
      const mockResponse: BraveWebSearchResponse = {
        query: { original: 'test' },
        web: {
          results: [
            {
              title: 'Test Result',
              url: 'https://example.com',
              description: 'A test result',
              age: '2 days ago',
            },
          ],
        },
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      const result = await client.search({
        endpoint: 'web',
        query: 'test',
      });

      expect(result.endpoint).toBe('web');
      expect(result.data.web?.results).toHaveLength(1);
      expect(result.data.web?.results[0].title).toBe('Test Result');
    });
  });

  describe('news search', () => {
    it('should make correct API request for news search', async () => {
      const mockResponse: BraveNewsSearchResponse = {
        query: { original: 'breaking news' },
        results: [],
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      await client.search({
        endpoint: 'news',
        query: 'breaking news',
      });

      const url = mockFetch.mock.calls[0][0] as string;
      expect(url).toContain('/res/v1/news/search');
    });

    it('should clamp count to news limits (1-50)', async () => {
      const mockResponse: BraveNewsSearchResponse = {
        query: { original: 'test' },
        results: [],
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      await client.search({
        endpoint: 'news',
        query: 'test',
        count: 100, // Should be clamped to 50
      });

      const url = mockFetch.mock.calls[0][0] as string;
      expect(url).toContain('count=50');
    });

    it('should include news-specific parameters', async () => {
      const mockResponse: BraveNewsSearchResponse = {
        query: { original: 'test' },
        results: [],
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      await client.search({
        endpoint: 'news',
        query: 'test',
        freshness: 'pd',
        extraSnippets: true,
      });

      const url = mockFetch.mock.calls[0][0] as string;
      expect(url).toContain('freshness=pd');
      expect(url).toContain('extra_snippets=true');
    });
  });

  describe('image search', () => {
    it('should make correct API request for image search', async () => {
      const mockResponse: BraveImageSearchResponse = {
        query: { original: 'cats' },
        results: [],
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      await client.search({
        endpoint: 'images',
        query: 'cats',
      });

      const url = mockFetch.mock.calls[0][0] as string;
      expect(url).toContain('/res/v1/images/search');
    });

    it('should clamp count to image limits (1-200)', async () => {
      const mockResponse: BraveImageSearchResponse = {
        query: { original: 'test' },
        results: [],
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      await client.search({
        endpoint: 'images',
        query: 'test',
        count: 500, // Should be clamped to 200
      });

      const url = mockFetch.mock.calls[0][0] as string;
      expect(url).toContain('count=200');
    });

    it('should NOT include offset or freshness for images (not supported)', async () => {
      const mockResponse: BraveImageSearchResponse = {
        query: { original: 'test' },
        results: [],
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      await client.search({
        endpoint: 'images',
        query: 'test',
        offset: 5,      // Should be ignored
        freshness: 'pw', // Should be ignored
      });

      const url = mockFetch.mock.calls[0][0] as string;
      expect(url).not.toContain('offset=');
      expect(url).not.toContain('freshness=');
    });
  });

  describe('video search', () => {
    it('should make correct API request for video search', async () => {
      const mockResponse: BraveVideoSearchResponse = {
        query: { original: 'tutorials' },
        results: [],
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      await client.search({
        endpoint: 'videos',
        query: 'tutorials',
      });

      const url = mockFetch.mock.calls[0][0] as string;
      expect(url).toContain('/res/v1/videos/search');
    });

    it('should clamp count to video limits (1-50)', async () => {
      const mockResponse: BraveVideoSearchResponse = {
        query: { original: 'test' },
        results: [],
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      await client.search({
        endpoint: 'videos',
        query: 'test',
        count: 100, // Should be clamped to 50
      });

      const url = mockFetch.mock.calls[0][0] as string;
      expect(url).toContain('count=50');
    });
  });

  describe('error handling', () => {
    it('should throw on 4xx errors', async () => {
      mockFetch.mockResolvedValueOnce(
        new Response('{"error": "Bad request"}', { status: 400 })
      );

      await expect(
        client.search({ endpoint: 'web', query: 'test' })
      ).rejects.toThrow('400');
    });

    it('should throw on 5xx errors', async () => {
      mockFetch.mockResolvedValueOnce(
        new Response('Server error', { status: 500 })
      );

      await expect(
        client.search({ endpoint: 'web', query: 'test' })
      ).rejects.toThrow('500');
    });

    it('should handle network errors', async () => {
      mockFetch.mockRejectedValueOnce(new Error('Network error'));

      await expect(
        client.search({ endpoint: 'web', query: 'test' })
      ).rejects.toThrow('Network error');
    });

    it('should mark key as rate limited on 429', async () => {
      const markRateLimitedSpy = vi.spyOn(keyRotator, 'markRateLimited');

      mockFetch.mockResolvedValueOnce(
        new Response('Rate limited', {
          status: 429,
          headers: { 'Retry-After': '60' },
        })
      );

      await expect(
        client.search({ endpoint: 'web', query: 'test' })
      ).rejects.toThrow('429');

      expect(markRateLimitedSpy).toHaveBeenCalled();
    });
  });

  describe('rate limiting info', () => {
    it('should include rate limit info in result when available', async () => {
      const mockResponse: BraveWebSearchResponse = {
        query: { original: 'test' },
        web: { results: [] },
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), {
          status: 200,
          headers: {
            'X-RateLimit-Remaining': '95',
            'X-RateLimit-Reset': '2024-01-15T12:00:00Z',
          },
        })
      );

      const result = await client.search({
        endpoint: 'web',
        query: 'test',
      });

      expect(result.rateLimitInfo).toBeDefined();
      expect(result.rateLimitInfo?.remaining).toBe(95);
    });
  });

  describe('default endpoint', () => {
    it('should default to web endpoint if not specified', async () => {
      const mockResponse: BraveWebSearchResponse = {
        query: { original: 'test' },
        web: { results: [] },
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      await client.search({ query: 'test' } as BraveSearchParams);

      const url = mockFetch.mock.calls[0][0] as string;
      expect(url).toContain('/res/v1/web/search');
    });
  });

  describe('key rotation', () => {
    it('should use key from rotator', async () => {
      const mockResponse: BraveWebSearchResponse = {
        query: { original: 'test' },
        web: { results: [] },
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      await client.search({ endpoint: 'web', query: 'test' });

      const [, options] = mockFetch.mock.calls[0] as [string, RequestInit];
      const headers = options.headers as Record<string, string>;
      expect(headers['X-Subscription-Token']).toMatch(/^test-api-key/);
    });

    it('should release key after request completes', async () => {
      const releaseKeySpy = vi.spyOn(keyRotator, 'releaseKey');

      const mockResponse: BraveWebSearchResponse = {
        query: { original: 'test' },
        web: { results: [] },
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      await client.search({ endpoint: 'web', query: 'test' });

      expect(releaseKeySpy).toHaveBeenCalled();
    });

    it('should release key even on error', async () => {
      const releaseKeySpy = vi.spyOn(keyRotator, 'releaseKey');

      mockFetch.mockRejectedValueOnce(new Error('Network error'));

      await expect(
        client.search({ endpoint: 'web', query: 'test' })
      ).rejects.toThrow();

      expect(releaseKeySpy).toHaveBeenCalled();
    });
  });
});
