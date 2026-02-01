/**
 * @fileoverview Tests for ExaClient
 *
 * TDD: Tests for Exa Search API client.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { ExaClient } from '../exa-client.js';
import type { ExaSearchResponse, ExaSearchParams } from '../exa-types.js';

// Mock fetch
const mockFetch = vi.fn();

describe('ExaClient', () => {
  let client: ExaClient;
  let originalFetch: typeof globalThis.fetch;

  beforeEach(() => {
    originalFetch = globalThis.fetch;
    globalThis.fetch = mockFetch as unknown as typeof fetch;
    mockFetch.mockClear();

    client = new ExaClient({ apiKey: 'test-exa-key' });
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  describe('constructor', () => {
    it('should create client with API key', () => {
      const client = new ExaClient({ apiKey: 'test-key' });
      expect(client).toBeDefined();
    });

    it('should accept custom base URL', () => {
      const client = new ExaClient({
        apiKey: 'test-key',
        baseUrl: 'https://custom.exa.ai',
      });
      expect(client).toBeDefined();
    });

    it('should accept custom timeout', () => {
      const client = new ExaClient({
        apiKey: 'test-key',
        timeout: 5000,
      });
      expect(client).toBeDefined();
    });
  });

  describe('search', () => {
    it('should make correct API request', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [],
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      );

      await client.search({ query: 'test query' });

      expect(mockFetch).toHaveBeenCalledTimes(1);
      const [url, options] = mockFetch.mock.calls[0] as [string, RequestInit];

      expect(url).toContain('api.exa.ai');
      expect(url).toContain('/search');
      expect(options.method).toBe('POST');
      expect(options.headers).toHaveProperty('x-api-key', 'test-exa-key');
      expect(options.headers).toHaveProperty('Content-Type', 'application/json');
    });

    it('should send query in request body', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [],
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      await client.search({ query: 'nodejs tutorials' });

      const [, options] = mockFetch.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(options.body as string);
      expect(body.query).toBe('nodejs tutorials');
    });

    it('should include all search parameters', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [],
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      const params: ExaSearchParams = {
        query: 'AI news',
        type: 'neural',
        category: 'news',
        numResults: 20,
        startPublishedDate: '2025-01-31T08:00:00.000Z',
        endPublishedDate: '2025-01-31T12:00:00.000Z',
        includeDomains: ['techcrunch.com', 'wired.com'],
        excludeDomains: ['spam.com'],
        useAutoprompt: true,
      };

      await client.search(params);

      const [, options] = mockFetch.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(options.body as string);

      // API uses snake_case parameter names
      expect(body.query).toBe('AI news');
      expect(body.type).toBe('neural');
      expect(body.category).toBe('news');
      expect(body.num_results).toBe(20);
      expect(body.start_published_date).toBe('2025-01-31T08:00:00.000Z');
      expect(body.end_published_date).toBe('2025-01-31T12:00:00.000Z');
      expect(body.include_domains).toEqual(['techcrunch.com', 'wired.com']);
      expect(body.exclude_domains).toEqual(['spam.com']);
      expect(body.use_autoprompt).toBe(true);
    });

    it('should handle hour-level date filtering', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [],
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      // The key feature: hour-level filtering
      const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString();

      await client.search({
        query: 'breaking news',
        startPublishedDate: oneHourAgo,
      });

      const [, options] = mockFetch.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(options.body as string);

      // API uses snake_case
      expect(body.start_published_date).toBe(oneHourAgo);
    });

    it('should include content options when specified', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [],
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      await client.search({
        query: 'test',
        contents: {
          text: { maxCharacters: 1000 },
          highlights: { numSentences: 3 },
        },
      });

      const [, options] = mockFetch.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(options.body as string);

      // API uses snake_case
      expect(body.contents).toBeDefined();
      expect(body.contents.text).toEqual({ max_characters: 1000 });
      expect(body.contents.highlights).toEqual({ num_sentences: 3 });
    });

    it('should return search results', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [
          {
            id: 'result-1',
            url: 'https://example.com/article',
            title: 'Test Article',
            publishedDate: '2025-01-31T10:00:00.000Z',
            score: 0.95,
          },
          {
            id: 'result-2',
            url: 'https://example.com/article2',
            title: 'Another Article',
            score: 0.85,
          },
        ],
        autopromptString: 'optimized query',
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      const result = await client.search({ query: 'test' });

      expect(result.requestId).toBe('req-123');
      expect(result.results).toHaveLength(2);
      expect(result.results[0].title).toBe('Test Article');
      expect(result.results[0].publishedDate).toBe('2025-01-31T10:00:00.000Z');
      expect(result.autopromptString).toBe('optimized query');
    });

    it('should return results with text content', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [
          {
            id: 'result-1',
            url: 'https://example.com/article',
            title: 'Test Article',
            text: 'This is the full article text content...',
            highlights: ['Key sentence one.', 'Key sentence two.'],
          },
        ],
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      const result = await client.search({
        query: 'test',
        contents: { text: true, highlights: true },
      });

      expect(result.results[0].text).toBe('This is the full article text content...');
      expect(result.results[0].highlights).toEqual(['Key sentence one.', 'Key sentence two.']);
    });
  });

  describe('category filtering', () => {
    it('should filter by tweet category', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [],
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      await client.search({
        query: 'OpenAI GPT',
        category: 'tweet',
      });

      const [, options] = mockFetch.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(options.body as string);

      expect(body.category).toBe('tweet');
    });

    it('should filter by research paper category', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [],
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      await client.search({
        query: 'transformer architecture',
        category: 'research paper',
      });

      const [, options] = mockFetch.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(options.body as string);

      expect(body.category).toBe('research paper');
    });
  });

  describe('search types', () => {
    it.each(['neural', 'auto', 'fast', 'deep'] as const)(
      'should support %s search type',
      async (searchType) => {
        const mockResponse: ExaSearchResponse = {
          requestId: 'req-123',
          results: [],
        };

        mockFetch.mockResolvedValueOnce(
          new Response(JSON.stringify(mockResponse), { status: 200 })
        );

        await client.search({
          query: 'test',
          type: searchType,
        });

        const [, options] = mockFetch.mock.calls[0] as [string, RequestInit];
        const body = JSON.parse(options.body as string);

        expect(body.type).toBe(searchType);
      }
    );
  });

  describe('error handling', () => {
    it('should throw on 401 unauthorized', async () => {
      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify({ error: 'Invalid API key' }), { status: 401 })
      );

      await expect(client.search({ query: 'test' })).rejects.toThrow('401');
    });

    it('should throw on 429 rate limit', async () => {
      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify({ error: 'Rate limited' }), { status: 429 })
      );

      await expect(client.search({ query: 'test' })).rejects.toThrow('429');
    });

    it('should throw on 500 server error', async () => {
      mockFetch.mockResolvedValueOnce(
        new Response('Internal server error', { status: 500 })
      );

      await expect(client.search({ query: 'test' })).rejects.toThrow('500');
    });

    it('should handle network errors', async () => {
      mockFetch.mockRejectedValueOnce(new Error('Network error'));

      await expect(client.search({ query: 'test' })).rejects.toThrow('Network error');
    });

    it('should handle timeout', async () => {
      mockFetch.mockRejectedValueOnce(new DOMException('The operation was aborted', 'AbortError'));

      await expect(client.search({ query: 'test' })).rejects.toThrow();
    });

    it('should include error details from response', async () => {
      mockFetch.mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            error: 'Bad Request',
            message: 'Query parameter is required',
          }),
          { status: 400 }
        )
      );

      await expect(client.search({ query: '' })).rejects.toThrow(/Query parameter/);
    });
  });

  describe('custom base URL', () => {
    it('should use custom base URL when provided', async () => {
      const customClient = new ExaClient({
        apiKey: 'test-key',
        baseUrl: 'https://custom.exa.ai',
      });

      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [],
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      await customClient.search({ query: 'test' });

      const [url] = mockFetch.mock.calls[0] as [string, RequestInit];
      expect(url).toContain('custom.exa.ai');
    });
  });

  describe('parameter validation', () => {
    it('should not send undefined parameters', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [],
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      await client.search({ query: 'test' });

      const [, options] = mockFetch.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(options.body as string);

      // Only query should be present, not undefined values
      expect(Object.keys(body)).toEqual(['query']);
    });

    it('should clamp numResults to max 100', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [],
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      await client.search({ query: 'test', numResults: 200 });

      const [, options] = mockFetch.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(options.body as string);

      // API uses snake_case
      expect(body.num_results).toBe(100);
    });
  });
});
