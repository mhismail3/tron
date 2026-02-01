/**
 * @fileoverview Tests for BraveProvider
 *
 * TDD: Tests for Brave search provider wrapper.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import { BraveProvider } from '../../providers/brave-provider.js';
import { BraveMultiClient, type BraveSearchResult } from '../../brave-multi-client.js';
import { BraveKeyRotator } from '../../brave-key-rotator.js';
import type { BraveWebSearchResponse, BraveNewsSearchResponse } from '../../brave-types.js';
import type { ProviderSearchParams, Freshness } from '../../providers/types.js';

// Mock BraveMultiClient
vi.mock('../../brave-multi-client.js', () => ({
  BraveMultiClient: vi.fn().mockImplementation(() => ({
    search: vi.fn(),
  })),
}));

// Mock BraveKeyRotator
vi.mock('../../brave-key-rotator.js', () => ({
  BraveKeyRotator: vi.fn().mockImplementation(() => ({})),
}));

describe('BraveProvider', () => {
  let provider: BraveProvider;
  let mockSearch: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    mockSearch = vi.fn();
    (BraveMultiClient as unknown as ReturnType<typeof vi.fn>).mockImplementation(() => ({
      search: mockSearch,
    }));
    provider = new BraveProvider({ apiKeys: ['test-key'] });
  });

  describe('constructor', () => {
    it('should create provider with API keys', () => {
      expect(provider).toBeDefined();
      expect(provider.name).toBe('brave');
    });

    it('should accept multiple API keys', () => {
      const provider = new BraveProvider({ apiKeys: ['key1', 'key2', 'key3'] });
      expect(provider).toBeDefined();
    });
  });

  describe('capabilities', () => {
    it('should NOT report hour freshness support', () => {
      expect(provider.capabilities.supportsHourFreshness).toBe(false);
    });

    it('should NOT report exact date range support', () => {
      expect(provider.capabilities.supportsExactDateRange).toBe(false);
    });

    it('should support web, news, images, and videos content types', () => {
      expect(provider.capabilities.supportedContentTypes).toContain('web');
      expect(provider.capabilities.supportedContentTypes).toContain('news');
      expect(provider.capabilities.supportedContentTypes).toContain('images');
      expect(provider.capabilities.supportedContentTypes).toContain('videos');
    });

    it('should NOT support social or research', () => {
      expect(provider.capabilities.supportedContentTypes).not.toContain('social');
      expect(provider.capabilities.supportedContentTypes).not.toContain('research');
    });

    it('should have maxResults of 200', () => {
      expect(provider.capabilities.maxResults).toBe(200);
    });
  });

  describe('search - basic', () => {
    it('should execute search with query', async () => {
      const mockResponse: BraveSearchResult = {
        endpoint: 'web',
        data: {
          query: { original: 'test query' },
          web: {
            results: [
              {
                title: 'Test Result',
                url: 'https://example.com',
                description: 'A test description',
                age: '2 days ago',
              },
            ],
          },
        },
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      const results = await provider.search({ query: 'test query' });

      expect(mockSearch).toHaveBeenCalledWith(
        expect.objectContaining({ query: 'test query' })
      );
      expect(results).toHaveLength(1);
      expect(results[0].title).toBe('Test Result');
      expect(results[0].source).toBe('brave');
    });

    it('should normalize results to UnifiedResult format', async () => {
      const mockResponse: BraveSearchResult = {
        endpoint: 'web',
        data: {
          query: { original: 'test' },
          web: {
            results: [
              {
                title: 'Test Article',
                url: 'https://example.com/article',
                description: 'Article description',
                age: '3 hours ago',
                page_age: '2025-01-31T10:00:00Z',
              },
            ],
          },
        },
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      const results = await provider.search({ query: 'test' });

      expect(results[0]).toEqual({
        title: 'Test Article',
        url: 'https://example.com/article',
        snippet: 'Article description',
        publishedDate: '2025-01-31T10:00:00Z',
        age: '3 hours ago',
        source: 'brave',
        contentType: 'web',
        author: undefined,
        domain: 'example.com',
        score: undefined,
      });
    });
  });

  describe('search - freshness', () => {
    it('should convert hour to pd (fallback to day)', async () => {
      const mockResponse: BraveSearchResult = {
        endpoint: 'web',
        data: {
          query: { original: 'test' },
          web: { results: [] },
        },
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      await provider.search({ query: 'test', freshness: 'hour' });

      expect(mockSearch).toHaveBeenCalledWith(
        expect.objectContaining({ freshness: 'pd' })
      );
    });

    it.each([
      ['day', 'pd'],
      ['week', 'pw'],
      ['month', 'pm'],
      ['year', 'py'],
    ] as [Freshness, string][])(
      'should convert %s freshness to %s',
      async (freshness, braveFreshness) => {
        const mockResponse: BraveSearchResult = {
          endpoint: 'web',
          data: {
            query: { original: 'test' },
            web: { results: [] },
          },
        };

        mockSearch.mockResolvedValueOnce(mockResponse);

        await provider.search({ query: 'test', freshness });

        expect(mockSearch).toHaveBeenCalledWith(
          expect.objectContaining({ freshness: braveFreshness })
        );
      }
    );
  });

  describe('search - content type mapping', () => {
    it('should use web endpoint for web contentType', async () => {
      const mockResponse: BraveSearchResult = {
        endpoint: 'web',
        data: {
          query: { original: 'test' },
          web: { results: [] },
        },
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      await provider.search({ query: 'test', contentType: 'web' });

      expect(mockSearch).toHaveBeenCalledWith(
        expect.objectContaining({ endpoint: 'web' })
      );
    });

    it('should use news endpoint for news contentType', async () => {
      const mockResponse: BraveSearchResult = {
        endpoint: 'news',
        data: {
          query: { original: 'test' },
          results: [],
        },
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      await provider.search({ query: 'test', contentType: 'news' });

      expect(mockSearch).toHaveBeenCalledWith(
        expect.objectContaining({ endpoint: 'news' })
      );
    });

    it('should use images endpoint for images contentType', async () => {
      const mockResponse: BraveSearchResult = {
        endpoint: 'images',
        data: {
          query: { original: 'test' },
          results: [],
        },
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      await provider.search({ query: 'test', contentType: 'images' });

      expect(mockSearch).toHaveBeenCalledWith(
        expect.objectContaining({ endpoint: 'images' })
      );
    });

    it('should use videos endpoint for videos contentType', async () => {
      const mockResponse: BraveSearchResult = {
        endpoint: 'videos',
        data: {
          query: { original: 'test' },
          results: [],
        },
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      await provider.search({ query: 'test', contentType: 'videos' });

      expect(mockSearch).toHaveBeenCalledWith(
        expect.objectContaining({ endpoint: 'videos' })
      );
    });

    it('should return empty array for unsupported contentType (social)', async () => {
      const results = await provider.search({ query: 'test', contentType: 'social' });

      expect(results).toEqual([]);
      expect(mockSearch).not.toHaveBeenCalled();
    });

    it('should return empty array for unsupported contentType (research)', async () => {
      const results = await provider.search({ query: 'test', contentType: 'research' });

      expect(results).toEqual([]);
      expect(mockSearch).not.toHaveBeenCalled();
    });
  });

  describe('search - news results', () => {
    it('should normalize news results correctly', async () => {
      const mockResponse: BraveSearchResult = {
        endpoint: 'news',
        data: {
          query: { original: 'test' },
          results: [
            {
              title: 'Breaking News',
              url: 'https://news.com/article',
              description: 'News description',
              age: '1 hour ago',
              source: 'News Source',
            },
          ],
        },
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      const results = await provider.search({ query: 'test', contentType: 'news' });

      expect(results[0].title).toBe('Breaking News');
      expect(results[0].contentType).toBe('news');
      expect(results[0].age).toBe('1 hour ago');
    });
  });

  describe('search - images results', () => {
    it('should normalize image results correctly', async () => {
      const mockResponse: BraveSearchResult = {
        endpoint: 'images',
        data: {
          query: { original: 'test' },
          results: [
            {
              title: 'Test Image',
              url: 'https://example.com/page',
              src: 'https://example.com/image.jpg',
              width: 1920,
              height: 1080,
            },
          ],
        },
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      const results = await provider.search({ query: 'test', contentType: 'images' });

      expect(results[0].title).toBe('Test Image');
      expect(results[0].contentType).toBe('images');
      expect(results[0].snippet).toBe('https://example.com/image.jpg');
    });
  });

  describe('search - videos results', () => {
    it('should normalize video results correctly', async () => {
      const mockResponse: BraveSearchResult = {
        endpoint: 'videos',
        data: {
          query: { original: 'test' },
          results: [
            {
              title: 'Test Video',
              url: 'https://youtube.com/watch?v=123',
              description: 'Video description',
              duration: '10:30',
              age: '2 days ago',
            },
          ],
        },
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      const results = await provider.search({ query: 'test', contentType: 'videos' });

      expect(results[0].title).toBe('Test Video');
      expect(results[0].contentType).toBe('videos');
      expect(results[0].age).toBe('2 days ago');
    });
  });

  describe('search - error handling', () => {
    it('should propagate client errors', async () => {
      mockSearch.mockRejectedValueOnce(new Error('Brave API error: 429 - Rate limited'));

      await expect(provider.search({ query: 'test' })).rejects.toThrow('Rate limited');
    });
  });

  describe('domain extraction', () => {
    it('should extract domain from URL', async () => {
      const mockResponse: BraveSearchResult = {
        endpoint: 'web',
        data: {
          query: { original: 'test' },
          web: {
            results: [
              {
                title: 'Test',
                url: 'https://subdomain.example.com/path',
                description: 'Test',
              },
            ],
          },
        },
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      const results = await provider.search({ query: 'test' });

      expect(results[0].domain).toBe('subdomain.example.com');
    });
  });
});
