/**
 * @fileoverview Tests for WebSearch Tool
 *
 * TDD: Tests for the WebSearch tool using Brave Search API.
 */

import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest';
import { WebSearchTool } from '../web-search.js';
import type { WebSearchToolConfig, BraveSearchResponse } from '../types.js';

// Mock fetch for HTTP requests
const mockFetch = vi.fn((url: string, options?: RequestInit) => {
  const mockResponse: BraveSearchResponse = {
    query: { original: 'test query' },
    web: {
      results: [
        {
          title: 'Result 1',
          url: 'https://example1.com',
          description: 'First result description',
          age: '1 day ago',
        },
        {
          title: 'Result 2',
          url: 'https://example2.com',
          description: 'Second result description',
          age: '2 days ago',
        },
      ],
    },
  };
  return Promise.resolve(
    new Response(JSON.stringify(mockResponse), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    })
  );
});

describe('WebSearch Tool', () => {
  let tool: WebSearchTool;
  let originalFetch: typeof globalThis.fetch;
  let config: WebSearchToolConfig;

  beforeEach(() => {
    originalFetch = globalThis.fetch;
    globalThis.fetch = mockFetch as typeof fetch;
    mockFetch.mockClear();

    config = {
      apiKey: 'test-brave-api-key',
    };
    tool = new WebSearchTool(config);
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  describe('tool definition', () => {
    it('should have correct name', () => {
      expect(tool.name).toBe('WebSearch');
    });

    it('should have description mentioning search', () => {
      expect(tool.description.toLowerCase()).toContain('search');
    });

    it('should require query parameter', () => {
      expect(tool.parameters.required).toContain('query');
    });

    it('should have network category', () => {
      expect(tool.category).toBe('network');
    });
  });

  describe('parameter validation', () => {
    it('should require query parameter', async () => {
      const result = await tool.execute({});
      expect(result.isError).toBe(true);
      expect(result.content).toContain('query');
    });

    it('should reject empty query', async () => {
      const result = await tool.execute({ query: '' });
      expect(result.isError).toBe(true);
    });

    it('should reject whitespace-only query', async () => {
      const result = await tool.execute({ query: '   ' });
      expect(result.isError).toBe(true);
    });

    it('should validate query length', async () => {
      const longQuery = 'x'.repeat(500);
      const result = await tool.execute({ query: longQuery });
      expect(result.isError).toBe(true);
      expect(result.content.toLowerCase()).toContain('too long');
    });
  });

  describe('searching', () => {
    it('should return formatted search results', async () => {
      const result = await tool.execute({ query: 'test query' });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('Result 1');
      expect(result.content).toContain('example1.com');
    });

    it('should include result URLs', async () => {
      const result = await tool.execute({ query: 'test query' });

      expect(result.content).toContain('https://example1.com');
      expect(result.content).toContain('https://example2.com');
    });

    it('should include result snippets', async () => {
      const result = await tool.execute({ query: 'test query' });

      expect(result.content).toContain('First result description');
      expect(result.content).toContain('Second result description');
    });

    it('should respect maxResults limit', async () => {
      // Mock returns 2 results, request only 1
      const result = await tool.execute({
        query: 'test query',
        maxResults: 1,
      });

      expect(result.details).toHaveProperty('results');
      // Should limit displayed results
      const details = result.details as any;
      expect(details.results.length).toBeLessThanOrEqual(1);
    });

    it('should handle API errors', async () => {
      mockFetch.mockResolvedValueOnce(
        new Response('{"error": "Invalid API key"}', { status: 401 })
      );

      const result = await tool.execute({ query: 'test' });

      expect(result.isError).toBe(true);
    });

    it('should handle no results', async () => {
      const emptyResponse: BraveSearchResponse = {
        query: { original: 'obscure query' },
        web: { results: [] },
      };
      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(emptyResponse), { status: 200 })
      );

      const result = await tool.execute({ query: 'obscure query' });

      expect(result.isError).toBeFalsy();
      expect(result.content.toLowerCase()).toContain('no result');
    });
  });

  describe('domain filtering', () => {
    it('should filter by allowed domains', async () => {
      const result = await tool.execute({
        query: 'test query',
        allowedDomains: ['example1.com'],
      });

      const details = result.details as any;
      // Only example1.com results should be included
      expect(details.results.length).toBe(1);
      expect(details.results[0].url).toContain('example1.com');
    });

    it('should exclude blocked domains', async () => {
      const result = await tool.execute({
        query: 'test query',
        blockedDomains: ['example1.com'],
      });

      const details = result.details as any;
      // example1.com should be excluded
      expect(details.results.every((r: any) => !r.url.includes('example1.com'))).toBe(true);
    });
  });

  describe('API key handling', () => {
    it('should fail gracefully when API key is missing', () => {
      expect(() => new WebSearchTool({ apiKey: '' })).toThrow();
    });

    it('should send API key in request header', async () => {
      await tool.execute({ query: 'test' });

      const options = mockFetch.mock.calls[0][1] as RequestInit;
      expect((options.headers as Record<string, string>)['X-Subscription-Token']).toBe(
        'test-brave-api-key'
      );
    });
  });

  describe('result format', () => {
    it('should format results as readable list', async () => {
      const result = await tool.execute({ query: 'test query' });

      // Should be formatted in a readable way
      expect(result.content).toContain('Result 1');
      expect(result.content).toContain('example1.com');
    });

    it('should include query in details', async () => {
      const result = await tool.execute({ query: 'test query' });

      expect(result.details).toHaveProperty('query', 'test query');
    });

    it('should include total results count', async () => {
      const result = await tool.execute({ query: 'test query' });

      expect(result.details).toHaveProperty('totalResults');
    });

    it('should include result array in details', async () => {
      const result = await tool.execute({ query: 'test query' });

      expect(result.details).toHaveProperty('results');
      expect(Array.isArray((result.details as any).results)).toBe(true);
    });
  });
});
