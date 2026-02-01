/**
 * @fileoverview Tests for ExaProvider
 *
 * TDD: Tests for Exa search provider wrapper.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import { ExaProvider } from '../../providers/exa-provider.js';
import { ExaClient } from '../../exa-client.js';
import type { ExaSearchResponse } from '../../exa-types.js';
import type { ProviderSearchParams, ContentType, Freshness } from '../../providers/types.js';

// Mock ExaClient
vi.mock('../../exa-client.js', () => ({
  ExaClient: vi.fn().mockImplementation(() => ({
    search: vi.fn(),
  })),
}));

describe('ExaProvider', () => {
  let provider: ExaProvider;
  let mockSearch: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    mockSearch = vi.fn();
    (ExaClient as unknown as ReturnType<typeof vi.fn>).mockImplementation(() => ({
      search: mockSearch,
    }));
    provider = new ExaProvider({ apiKey: 'test-key' });
  });

  describe('constructor', () => {
    it('should create provider with API key', () => {
      expect(provider).toBeDefined();
      expect(provider.name).toBe('exa');
    });
  });

  describe('capabilities', () => {
    it('should report hour freshness support', () => {
      expect(provider.capabilities.supportsHourFreshness).toBe(true);
    });

    it('should report exact date range support', () => {
      expect(provider.capabilities.supportsExactDateRange).toBe(true);
    });

    it('should support web, news, social, and research content types', () => {
      expect(provider.capabilities.supportedContentTypes).toContain('web');
      expect(provider.capabilities.supportedContentTypes).toContain('news');
      expect(provider.capabilities.supportedContentTypes).toContain('social');
      expect(provider.capabilities.supportedContentTypes).toContain('research');
    });

    it('should NOT support images or videos', () => {
      expect(provider.capabilities.supportedContentTypes).not.toContain('images');
      expect(provider.capabilities.supportedContentTypes).not.toContain('videos');
    });

    it('should have maxResults of 100', () => {
      expect(provider.capabilities.maxResults).toBe(100);
    });
  });

  describe('search - basic', () => {
    it('should execute search with query', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [
          {
            id: 'result-1',
            url: 'https://example.com',
            title: 'Test Result',
            publishedDate: '2025-01-31T10:00:00.000Z',
          },
        ],
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      const results = await provider.search({ query: 'test query' });

      expect(mockSearch).toHaveBeenCalledWith(
        expect.objectContaining({ query: 'test query' })
      );
      expect(results).toHaveLength(1);
      expect(results[0].title).toBe('Test Result');
      expect(results[0].source).toBe('exa');
    });

    it('should map count to numResults', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [],
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      await provider.search({ query: 'test', count: 20 });

      expect(mockSearch).toHaveBeenCalledWith(
        expect.objectContaining({ numResults: 20 })
      );
    });

    it('should normalize results to UnifiedResult format', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [
          {
            id: 'result-1',
            url: 'https://example.com/article',
            title: 'Test Article',
            publishedDate: '2025-01-31T10:00:00.000Z',
            author: 'John Doe',
            score: 0.95,
          },
        ],
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      const results = await provider.search({ query: 'test' });

      expect(results[0]).toEqual({
        title: 'Test Article',
        url: 'https://example.com/article',
        snippet: '', // No text/highlights in response
        publishedDate: '2025-01-31T10:00:00.000Z',
        age: undefined,
        source: 'exa',
        contentType: 'web',
        author: 'John Doe',
        domain: 'example.com',
        score: 0.95,
      });
    });

    it('should use text or highlights as snippet', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [
          {
            id: 'result-1',
            url: 'https://example.com',
            title: 'Test',
            highlights: ['This is a highlight.', 'Another highlight.'],
          },
        ],
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      const results = await provider.search({ query: 'test' });

      expect(results[0].snippet).toBe('This is a highlight. Another highlight.');
    });
  });

  describe('search - freshness', () => {
    it.each([
      ['hour', 1],
      ['day', 24],
      ['week', 7 * 24],
      ['month', 31 * 24],
      ['year', 365 * 24],
    ] as [Freshness, number][])(
      'should convert %s freshness to startPublishedDate',
      async (freshness, hoursAgo) => {
        const mockResponse: ExaSearchResponse = {
          requestId: 'req-123',
          results: [],
        };

        mockSearch.mockResolvedValueOnce(mockResponse);

        // Freeze time for predictable test
        const now = Date.now();
        vi.spyOn(Date, 'now').mockReturnValue(now);

        await provider.search({ query: 'test', freshness });

        const expectedDate = new Date(now - hoursAgo * 60 * 60 * 1000).toISOString();

        expect(mockSearch).toHaveBeenCalledWith(
          expect.objectContaining({
            startPublishedDate: expectedDate,
          })
        );

        vi.restoreAllMocks();
      }
    );
  });

  describe('search - exact date range', () => {
    it('should pass startDate as startPublishedDate', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [],
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      await provider.search({
        query: 'test',
        startDate: '2025-01-31T08:00:00.000Z',
      });

      expect(mockSearch).toHaveBeenCalledWith(
        expect.objectContaining({
          startPublishedDate: '2025-01-31T08:00:00.000Z',
        })
      );
    });

    it('should pass endDate as endPublishedDate', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [],
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      await provider.search({
        query: 'test',
        startDate: '2025-01-31T08:00:00.000Z',
        endDate: '2025-01-31T12:00:00.000Z',
      });

      expect(mockSearch).toHaveBeenCalledWith(
        expect.objectContaining({
          startPublishedDate: '2025-01-31T08:00:00.000Z',
          endPublishedDate: '2025-01-31T12:00:00.000Z',
        })
      );
    });

    it('should prefer exact dates over freshness', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [],
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      await provider.search({
        query: 'test',
        freshness: 'hour',
        startDate: '2025-01-31T08:00:00.000Z',
      });

      // Should use exact date, not freshness calculation
      expect(mockSearch).toHaveBeenCalledWith(
        expect.objectContaining({
          startPublishedDate: '2025-01-31T08:00:00.000Z',
        })
      );
    });
  });

  describe('search - content type mapping', () => {
    it('should map news contentType to news category', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [],
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      await provider.search({ query: 'test', contentType: 'news' });

      expect(mockSearch).toHaveBeenCalledWith(
        expect.objectContaining({ category: 'news' })
      );
    });

    it('should map social contentType to tweet category', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [],
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      await provider.search({ query: 'test', contentType: 'social' });

      expect(mockSearch).toHaveBeenCalledWith(
        expect.objectContaining({ category: 'tweet' })
      );
    });

    it('should map research contentType to research paper category', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [],
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      await provider.search({ query: 'test', contentType: 'research' });

      expect(mockSearch).toHaveBeenCalledWith(
        expect.objectContaining({ category: 'research paper' })
      );
    });

    it('should not set category for web contentType', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [],
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      await provider.search({ query: 'test', contentType: 'web' });

      expect(mockSearch).toHaveBeenCalledWith(
        expect.not.objectContaining({ category: expect.anything() })
      );
    });

    it('should set contentType in results based on request', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [
          {
            id: 'result-1',
            url: 'https://twitter.com/test',
            title: 'A Tweet',
          },
        ],
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      const results = await provider.search({ query: 'test', contentType: 'social' });

      expect(results[0].contentType).toBe('social');
    });
  });

  describe('search - domain filtering', () => {
    it('should pass includeDomains to client', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [],
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      await provider.search({
        query: 'test',
        includeDomains: ['example.com', 'test.com'],
      });

      expect(mockSearch).toHaveBeenCalledWith(
        expect.objectContaining({
          includeDomains: ['example.com', 'test.com'],
        })
      );
    });

    it('should pass excludeDomains to client', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [],
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      await provider.search({
        query: 'test',
        excludeDomains: ['spam.com'],
      });

      expect(mockSearch).toHaveBeenCalledWith(
        expect.objectContaining({
          excludeDomains: ['spam.com'],
        })
      );
    });
  });

  describe('search - error handling', () => {
    it('should propagate client errors', async () => {
      mockSearch.mockRejectedValueOnce(new Error('Exa API error: 429 - Rate limited'));

      await expect(provider.search({ query: 'test' })).rejects.toThrow('Rate limited');
    });
  });

  describe('domain extraction', () => {
    it('should extract domain from URL', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [
          {
            id: 'result-1',
            url: 'https://subdomain.example.com/path/to/page',
            title: 'Test',
          },
        ],
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      const results = await provider.search({ query: 'test' });

      expect(results[0].domain).toBe('subdomain.example.com');
    });

    it('should handle invalid URLs gracefully', async () => {
      const mockResponse: ExaSearchResponse = {
        requestId: 'req-123',
        results: [
          {
            id: 'result-1',
            url: 'not-a-valid-url',
            title: 'Test',
          },
        ],
      };

      mockSearch.mockResolvedValueOnce(mockResponse);

      const results = await provider.search({ query: 'test' });

      expect(results[0].domain).toBeUndefined();
    });
  });
});
