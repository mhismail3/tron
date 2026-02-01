/**
 * @fileoverview Tests for WebSearchTool v2
 *
 * TDD: Tests for the comprehensive WebSearch tool with full Brave API support.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { WebSearchToolV2, type WebSearchV2Config } from '../web-search-v2.js';
import type {
  BraveWebSearchResponse,
  BraveNewsSearchResponse,
  BraveImageSearchResponse,
  BraveVideoSearchResponse,
} from '../brave-types.js';

// Mock fetch
const mockFetch = vi.fn();

describe('WebSearchToolV2', () => {
  let tool: WebSearchToolV2;
  let originalFetch: typeof globalThis.fetch;

  beforeEach(() => {
    originalFetch = globalThis.fetch;
    globalThis.fetch = mockFetch as unknown as typeof fetch;
    mockFetch.mockClear();
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  describe('constructor', () => {
    it('should throw error when no API keys provided', () => {
      expect(
        () => new WebSearchToolV2({ apiKeys: [] })
      ).toThrow('WebSearch requires at least one Brave Search API key');
    });

    it('should accept single API key', () => {
      const tool = new WebSearchToolV2({ apiKeys: ['key1'] });
      expect(tool.name).toBe('WebSearch');
    });

    it('should accept multiple API keys', () => {
      const tool = new WebSearchToolV2({ apiKeys: ['key1', 'key2', 'key3'] });
      expect(tool.name).toBe('WebSearch');
    });

    it('should have correct tool metadata', () => {
      const tool = new WebSearchToolV2({ apiKeys: ['key1'] });
      expect(tool.name).toBe('WebSearch');
      expect(tool.category).toBe('network');
      expect(tool.label).toBe('Web Search');
      expect(tool.description).toContain('Brave Search API');
    });
  });

  describe('parameters schema', () => {
    beforeEach(() => {
      tool = new WebSearchToolV2({ apiKeys: ['test-key'] });
    });

    it('should require query parameter', () => {
      expect(tool.parameters.required).toContain('query');
    });

    it('should have endpoint enum', () => {
      const endpointProp = tool.parameters.properties.endpoint;
      expect(endpointProp.enum).toEqual(['web', 'news', 'images', 'videos']);
    });

    it('should have all documented parameters', () => {
      const props = Object.keys(tool.parameters.properties);
      expect(props).toContain('query');
      expect(props).toContain('endpoint');
      expect(props).toContain('count');
      expect(props).toContain('freshness');
      expect(props).toContain('country');
      expect(props).toContain('searchLang');
      expect(props).toContain('safesearch');
      expect(props).toContain('offset');
      expect(props).toContain('resultFilter');
      expect(props).toContain('extraSnippets');
      expect(props).toContain('allowedDomains');
      expect(props).toContain('blockedDomains');
    });
  });

  describe('execute - validation', () => {
    beforeEach(() => {
      tool = new WebSearchToolV2({ apiKeys: ['test-key'] });
    });

    it('should return error for missing query', async () => {
      const result = await tool.execute({});
      expect(result.isError).toBe(true);
      expect(result.content).toContain('query');
    });

    it('should return error for empty query', async () => {
      const result = await tool.execute({ query: '   ' });
      expect(result.isError).toBe(true);
      expect(result.content).toContain('query');
    });

    it('should return error for query exceeding 400 chars', async () => {
      const longQuery = 'a'.repeat(401);
      const result = await tool.execute({ query: longQuery });
      expect(result.isError).toBe(true);
      expect(result.content).toContain('400');
    });
  });

  describe('execute - web search', () => {
    beforeEach(() => {
      tool = new WebSearchToolV2({ apiKeys: ['test-key'] });
    });

    it('should execute web search successfully', async () => {
      const mockResponse: BraveWebSearchResponse = {
        query: { original: 'test query' },
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

      const result = await tool.execute({ query: 'test query' });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('Test Result');
      expect(result.content).toContain('https://example.com');
    });

    it('should use default endpoint (web) when not specified', async () => {
      const mockResponse: BraveWebSearchResponse = {
        query: { original: 'test' },
        web: { results: [] },
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      await tool.execute({ query: 'test' });

      const url = mockFetch.mock.calls[0][0] as string;
      expect(url).toContain('/res/v1/web/search');
    });

    it('should include web-specific parameters', async () => {
      const mockResponse: BraveWebSearchResponse = {
        query: { original: 'test' },
        web: { results: [] },
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      await tool.execute({
        query: 'test',
        endpoint: 'web',
        count: 15,
        freshness: 'pw',
        resultFilter: 'web,news',
        extraSnippets: true,
      });

      const url = mockFetch.mock.calls[0][0] as string;
      expect(url).toContain('count=15');
      expect(url).toContain('freshness=pw');
      expect(url).toContain('result_filter=web%2Cnews');
      expect(url).toContain('extra_snippets=true');
    });
  });

  describe('execute - news search', () => {
    beforeEach(() => {
      tool = new WebSearchToolV2({ apiKeys: ['test-key'] });
    });

    it('should execute news search successfully', async () => {
      const mockResponse: BraveNewsSearchResponse = {
        query: { original: 'breaking news' },
        results: [
          {
            title: 'Breaking News Story',
            url: 'https://news.example.com/story',
            description: 'Something happened',
            age: '1 hour ago',
            source: 'Example News',
          },
        ],
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      const result = await tool.execute({
        query: 'breaking news',
        endpoint: 'news',
      });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('Breaking News Story');
    });

    it('should use news endpoint path', async () => {
      const mockResponse: BraveNewsSearchResponse = {
        query: { original: 'test' },
        results: [],
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      await tool.execute({ query: 'test', endpoint: 'news' });

      const url = mockFetch.mock.calls[0][0] as string;
      expect(url).toContain('/res/v1/news/search');
    });
  });

  describe('execute - image search', () => {
    beforeEach(() => {
      tool = new WebSearchToolV2({ apiKeys: ['test-key'] });
    });

    it('should execute image search successfully', async () => {
      const mockResponse: BraveImageSearchResponse = {
        query: { original: 'cats' },
        results: [
          {
            title: 'Cute Cat',
            url: 'https://images.example.com/cat-page',
            src: 'https://images.example.com/cat.jpg',
            width: 800,
            height: 600,
          },
        ],
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      const result = await tool.execute({
        query: 'cats',
        endpoint: 'images',
      });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('Cute Cat');
    });
  });

  describe('execute - video search', () => {
    beforeEach(() => {
      tool = new WebSearchToolV2({ apiKeys: ['test-key'] });
    });

    it('should execute video search successfully', async () => {
      const mockResponse: BraveVideoSearchResponse = {
        query: { original: 'tutorials' },
        results: [
          {
            title: 'Tutorial Video',
            url: 'https://videos.example.com/tutorial',
            description: 'Learn something new',
            duration: '10:30',
          },
        ],
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      const result = await tool.execute({
        query: 'tutorials',
        endpoint: 'videos',
      });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('Tutorial Video');
    });
  });

  describe('domain filtering', () => {
    beforeEach(() => {
      tool = new WebSearchToolV2({ apiKeys: ['test-key'] });
    });

    it('should filter by allowed domains', async () => {
      const mockResponse: BraveWebSearchResponse = {
        query: { original: 'test' },
        web: {
          results: [
            { title: 'GitHub', url: 'https://github.com/repo', description: 'Repo' },
            { title: 'GitLab', url: 'https://gitlab.com/repo', description: 'Repo' },
            { title: 'Other', url: 'https://other.com/page', description: 'Page' },
          ],
        },
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      const result = await tool.execute({
        query: 'test',
        allowedDomains: ['github.com'],
      });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('github.com');
      expect(result.content).not.toContain('gitlab.com');
      expect(result.content).not.toContain('other.com');
    });

    it('should filter out blocked domains', async () => {
      const mockResponse: BraveWebSearchResponse = {
        query: { original: 'test' },
        web: {
          results: [
            { title: 'Good', url: 'https://good.com/page', description: 'Good' },
            { title: 'Bad', url: 'https://bad.com/page', description: 'Bad' },
          ],
        },
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      const result = await tool.execute({
        query: 'test',
        blockedDomains: ['bad.com'],
      });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('good.com');
      expect(result.content).not.toContain('bad.com');
    });

    it('should respect config-level blocked domains', async () => {
      const toolWithBlocklist = new WebSearchToolV2({
        apiKeys: ['test-key'],
        blockedDomains: ['blocked.com'],
      });

      const mockResponse: BraveWebSearchResponse = {
        query: { original: 'test' },
        web: {
          results: [
            { title: 'Good', url: 'https://good.com/page', description: 'Good' },
            { title: 'Blocked', url: 'https://blocked.com/page', description: 'Blocked' },
          ],
        },
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      const result = await toolWithBlocklist.execute({ query: 'test' });

      expect(result.content).not.toContain('blocked.com');
    });
  });

  describe('error handling', () => {
    beforeEach(() => {
      tool = new WebSearchToolV2({ apiKeys: ['test-key'] });
    });

    it('should handle rate limiting gracefully', async () => {
      mockFetch.mockResolvedValueOnce(
        new Response('Rate limited', {
          status: 429,
          headers: { 'Retry-After': '60' },
        })
      );

      const result = await tool.execute({ query: 'test' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('rate limit');
    });

    it('should handle network errors', async () => {
      mockFetch.mockRejectedValueOnce(new Error('Network error'));

      const result = await tool.execute({ query: 'test' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('error');
    });

    it('should handle empty results', async () => {
      const mockResponse: BraveWebSearchResponse = {
        query: { original: 'obscure query' },
        web: { results: [] },
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      const result = await tool.execute({ query: 'obscure query' });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('No results');
    });
  });

  describe('backwards compatibility', () => {
    beforeEach(() => {
      tool = new WebSearchToolV2({ apiKeys: ['test-key'] });
    });

    it('should accept maxResults as alias for count', async () => {
      const mockResponse: BraveWebSearchResponse = {
        query: { original: 'test' },
        web: { results: [] },
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      // maxResults is the old parameter name
      await tool.execute({ query: 'test', maxResults: 5 });

      const url = mockFetch.mock.calls[0][0] as string;
      expect(url).toContain('count=5');
    });
  });

  describe('result formatting', () => {
    beforeEach(() => {
      tool = new WebSearchToolV2({ apiKeys: ['test-key'] });
    });

    it('should format web results with all fields', async () => {
      const mockResponse: BraveWebSearchResponse = {
        query: { original: 'test' },
        web: {
          results: [
            {
              title: 'Test Page',
              url: 'https://example.com/test',
              description: 'This is a test page',
              age: '3 days ago',
              extra_snippets: ['Additional context here'],
            },
          ],
        },
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      const result = await tool.execute({ query: 'test' });

      expect(result.content).toContain('Test Page');
      expect(result.content).toContain('https://example.com/test');
      expect(result.content).toContain('This is a test page');
    });

    it('should include result count in output', async () => {
      const mockResponse: BraveWebSearchResponse = {
        query: { original: 'test' },
        web: {
          results: [
            { title: 'R1', url: 'https://1.com', description: 'D1' },
            { title: 'R2', url: 'https://2.com', description: 'D2' },
            { title: 'R3', url: 'https://3.com', description: 'D3' },
          ],
        },
      };

      mockFetch.mockResolvedValueOnce(
        new Response(JSON.stringify(mockResponse), { status: 200 })
      );

      const result = await tool.execute({ query: 'test' });

      expect(result.content).toContain('3');
    });
  });
});
