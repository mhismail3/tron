/**
 * @fileoverview Tests for Brave Search Client
 *
 * TDD: Tests for Brave Search API integration.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { BraveSearchClient, formatSearchResults } from '../brave-search.js';
import type {
  BraveSearchResponse,
  BraveWebResult,
  SearchResultItem,
} from '../types.js';

// Mock fetch for tests
const mockFetch = vi.fn((url: string, options?: RequestInit) => {
  return Promise.resolve(new Response('{}', { status: 200 }));
});

describe('Brave Search Client', () => {
  let client: BraveSearchClient;
  let originalFetch: typeof globalThis.fetch;

  beforeEach(() => {
    originalFetch = globalThis.fetch;
    globalThis.fetch = mockFetch as typeof fetch;
    mockFetch.mockClear();
    client = new BraveSearchClient({ apiKey: 'test-api-key' });
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  describe('constructor', () => {
    it('should create client with API key', () => {
      const client = new BraveSearchClient({ apiKey: 'my-key' });
      expect(client).toBeDefined();
    });

    it('should use default base URL', () => {
      const client = new BraveSearchClient({ apiKey: 'key' });
      expect(client).toBeDefined();
    });

    it('should accept custom base URL', () => {
      const client = new BraveSearchClient({
        apiKey: 'key',
        baseUrl: 'https://custom.api.com',
      });
      expect(client).toBeDefined();
    });
  });

  describe('search method', () => {
    it('should send correct API request', async () => {
      const mockResponse: BraveSearchResponse = {
        query: { original: 'test query' },
        web: { results: [] },
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      );

      await client.search('test query');

      expect(mockFetch).toHaveBeenCalledTimes(1);
      const callArgs = mockFetch.mock.calls[0];
      const url = callArgs[0] as string;
      const options = callArgs[1] as RequestInit;

      expect(url).toContain('api.search.brave.com');
      expect(url).toContain('q=test+query');
      expect(options.headers).toHaveProperty('X-Subscription-Token', 'test-api-key');
    });

    it('should include count parameter', async () => {
      const mockResponse: BraveSearchResponse = {
        query: { original: 'test' },
        web: { results: [] },
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      await client.search('test', { count: 5 });

      const url = mockFetch.mock.calls[0][0] as string;
      expect(url).toContain('count=5');
    });

    it('should format results correctly', async () => {
      const mockResults: BraveWebResult[] = [
        {
          title: 'Result 1',
          url: 'https://example1.com',
          description: 'Description 1',
          age: '2 days ago',
        },
        {
          title: 'Result 2',
          url: 'https://example2.com',
          description: 'Description 2',
        },
      ];

      const mockResponse: BraveSearchResponse = {
        query: { original: 'test' },
        web: { results: mockResults },
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      const results = await client.search('test');

      expect(results.results).toHaveLength(2);
      expect(results.results[0].title).toBe('Result 1');
      expect(results.results[0].url).toBe('https://example1.com');
      expect(results.results[0].snippet).toBe('Description 1');
      expect(results.results[0].age).toBe('2 days ago');
    });

    it('should handle API errors', async () => {
      mockFetch.mockResolvedValueOnce(
        new Response('{"error": "Rate limited"}', { status: 429 })
      );

      await expect(client.search('test')).rejects.toThrow();
    });

    it('should handle network errors', async () => {
      mockFetch.mockRejectedValueOnce(new Error('Network error'));

      await expect(client.search('test')).rejects.toThrow('Network error');
    });

    it('should handle empty results', async () => {
      const mockResponse: BraveSearchResponse = {
        query: { original: 'obscure query' },
        web: { results: [] },
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      const results = await client.search('obscure query');

      expect(results.results).toHaveLength(0);
      expect(results.totalResults).toBe(0);
    });

    it('should handle missing web results', async () => {
      const mockResponse: BraveSearchResponse = {
        query: { original: 'test' },
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      const results = await client.search('test');

      expect(results.results).toHaveLength(0);
    });
  });

  describe('domain filtering', () => {
    it('should filter results by allowed domains', async () => {
      const mockResults: BraveWebResult[] = [
        { title: 'GitHub', url: 'https://github.com/repo', description: 'A repo' },
        { title: 'GitLab', url: 'https://gitlab.com/repo', description: 'Another repo' },
        { title: 'Other', url: 'https://other.com/page', description: 'Other site' },
      ];

      const mockResponse: BraveSearchResponse = {
        query: { original: 'test' },
        web: { results: mockResults },
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      const results = await client.search('test', {
        allowedDomains: ['github.com'],
      });

      expect(results.results).toHaveLength(1);
      expect(results.results[0].url).toContain('github.com');
    });

    it('should filter out blocked domains', async () => {
      const mockResults: BraveWebResult[] = [
        { title: 'Good Site', url: 'https://good.com/page', description: 'Good' },
        { title: 'Bad Site', url: 'https://bad.com/page', description: 'Bad' },
      ];

      const mockResponse: BraveSearchResponse = {
        query: { original: 'test' },
        web: { results: mockResults },
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      const results = await client.search('test', {
        blockedDomains: ['bad.com'],
      });

      expect(results.results).toHaveLength(1);
      expect(results.results[0].url).toContain('good.com');
    });
  });

  describe('formatSearchResults', () => {
    it('should format Brave results to SearchResultItem', () => {
      const braveResults: BraveWebResult[] = [
        {
          title: 'Test Title',
          url: 'https://example.com/page',
          description: 'Test description',
          age: '1 day ago',
        },
      ];

      const formatted = formatSearchResults(braveResults, 'test query');

      expect(formatted.query).toBe('test query');
      expect(formatted.results).toHaveLength(1);
      expect(formatted.results[0]).toEqual({
        title: 'Test Title',
        url: 'https://example.com/page',
        snippet: 'Test description',
        age: '1 day ago',
        domain: 'example.com',
      });
    });

    it('should extract domain from URL', () => {
      const braveResults: BraveWebResult[] = [
        {
          title: 'Test',
          url: 'https://sub.domain.example.com/path?query=1',
          description: 'Test',
        },
      ];

      const formatted = formatSearchResults(braveResults, 'query');

      expect(formatted.results[0].domain).toBe('sub.domain.example.com');
    });

    it('should handle results without age', () => {
      const braveResults: BraveWebResult[] = [
        {
          title: 'Test',
          url: 'https://example.com',
          description: 'Test',
        },
      ];

      const formatted = formatSearchResults(braveResults, 'query');

      expect(formatted.results[0].age).toBeUndefined();
    });

    it('should calculate total results', () => {
      const braveResults: BraveWebResult[] = [
        { title: '1', url: 'https://example1.com', description: '1' },
        { title: '2', url: 'https://example2.com', description: '2' },
        { title: '3', url: 'https://example3.com', description: '3' },
      ];

      const formatted = formatSearchResults(braveResults, 'query');

      expect(formatted.totalResults).toBe(3);
    });
  });
});
