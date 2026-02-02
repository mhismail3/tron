/**
 * @fileoverview Tests for UnifiedSearchTool
 *
 * TDD: Tests for the unified multi-provider search tool.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import { UnifiedSearchTool, type UnifiedSearchConfig } from '../unified-search.js';
import type { SearchProvider, UnifiedResult, ProviderSearchParams } from '@llm/providers/types.js';

// Create mock providers
function createMockBraveProvider(): SearchProvider {
  return {
    name: 'brave',
    capabilities: {
      supportsHourFreshness: false,
      supportsExactDateRange: false,
      supportedContentTypes: ['web', 'news', 'images', 'videos'],
      maxResults: 200,
    },
    search: vi.fn(),
  };
}

function createMockExaProvider(): SearchProvider {
  return {
    name: 'exa',
    capabilities: {
      supportsHourFreshness: true,
      supportsExactDateRange: true,
      supportedContentTypes: ['web', 'news', 'social', 'research'],
      maxResults: 100,
    },
    search: vi.fn(),
  };
}

describe('UnifiedSearchTool', () => {
  describe('constructor', () => {
    it('should create tool with brave provider only', () => {
      const brave = createMockBraveProvider();
      const tool = new UnifiedSearchTool({ providers: { brave } });

      expect(tool).toBeDefined();
      expect(tool.name).toBe('WebSearch');
    });

    it('should create tool with exa provider only', () => {
      const exa = createMockExaProvider();
      const tool = new UnifiedSearchTool({ providers: { exa } });

      expect(tool).toBeDefined();
    });

    it('should create tool with both providers', () => {
      const brave = createMockBraveProvider();
      const exa = createMockExaProvider();
      const tool = new UnifiedSearchTool({ providers: { brave, exa } });

      expect(tool).toBeDefined();
    });

    it('should throw if no providers configured', () => {
      expect(() => new UnifiedSearchTool({ providers: {} })).toThrow();
    });
  });

  describe('tool metadata', () => {
    it('should have correct name', () => {
      const brave = createMockBraveProvider();
      const tool = new UnifiedSearchTool({ providers: { brave } });

      expect(tool.name).toBe('WebSearch');
    });

    it('should have description mentioning both providers', () => {
      const brave = createMockBraveProvider();
      const exa = createMockExaProvider();
      const tool = new UnifiedSearchTool({ providers: { brave, exa } });

      expect(tool.description).toContain('brave');
      expect(tool.description).toContain('exa');
    });

    it('should have required query parameter', () => {
      const brave = createMockBraveProvider();
      const tool = new UnifiedSearchTool({ providers: { brave } });

      expect(tool.parameters.required).toContain('query');
    });
  });

  describe('single provider search', () => {
    it('should search with brave only', async () => {
      const brave = createMockBraveProvider();
      const results: UnifiedResult[] = [
        {
          title: 'Brave Result',
          url: 'https://example.com',
          snippet: 'Test snippet',
          source: 'brave',
          contentType: 'web',
        },
      ];
      (brave.search as ReturnType<typeof vi.fn>).mockResolvedValueOnce(results);

      const tool = new UnifiedSearchTool({ providers: { brave } });
      const result = await tool.execute({ query: 'test query' });

      expect(brave.search).toHaveBeenCalled();
      expect(result.isError).toBe(false);
      expect(result.content).toContain('Brave Result');
    });

    it('should search with exa only', async () => {
      const exa = createMockExaProvider();
      const results: UnifiedResult[] = [
        {
          title: 'Exa Result',
          url: 'https://example.com',
          snippet: 'Test snippet',
          source: 'exa',
          contentType: 'web',
        },
      ];
      (exa.search as ReturnType<typeof vi.fn>).mockResolvedValueOnce(results);

      const tool = new UnifiedSearchTool({ providers: { exa } });
      const result = await tool.execute({ query: 'test query' });

      expect(exa.search).toHaveBeenCalled();
      expect(result.isError).toBe(false);
      expect(result.content).toContain('Exa Result');
    });
  });

  describe('multi-provider search', () => {
    it('should query both providers by default', async () => {
      const brave = createMockBraveProvider();
      const exa = createMockExaProvider();

      const braveResults: UnifiedResult[] = [
        {
          title: 'Brave Result',
          url: 'https://brave.example.com',
          snippet: 'From Brave',
          source: 'brave',
          contentType: 'web',
        },
      ];
      const exaResults: UnifiedResult[] = [
        {
          title: 'Exa Result',
          url: 'https://exa.example.com',
          snippet: 'From Exa',
          source: 'exa',
          contentType: 'web',
        },
      ];

      (brave.search as ReturnType<typeof vi.fn>).mockResolvedValueOnce(braveResults);
      (exa.search as ReturnType<typeof vi.fn>).mockResolvedValueOnce(exaResults);

      const tool = new UnifiedSearchTool({ providers: { brave, exa } });
      const result = await tool.execute({ query: 'test query' });

      expect(brave.search).toHaveBeenCalled();
      expect(exa.search).toHaveBeenCalled();
      expect(result.content).toContain('Brave Result');
      expect(result.content).toContain('Exa Result');
    });

    it('should query only specified providers', async () => {
      const brave = createMockBraveProvider();
      const exa = createMockExaProvider();

      const exaResults: UnifiedResult[] = [
        {
          title: 'Exa Result',
          url: 'https://exa.example.com',
          snippet: 'From Exa',
          source: 'exa',
          contentType: 'web',
        },
      ];

      (exa.search as ReturnType<typeof vi.fn>).mockResolvedValueOnce(exaResults);

      const tool = new UnifiedSearchTool({ providers: { brave, exa } });
      const result = await tool.execute({
        query: 'test query',
        providers: ['exa'],
      });

      expect(brave.search).not.toHaveBeenCalled();
      expect(exa.search).toHaveBeenCalled();
    });

    it('should run providers in parallel', async () => {
      const brave = createMockBraveProvider();
      const exa = createMockExaProvider();

      let braveStarted = false;
      let exaStarted = false;

      (brave.search as ReturnType<typeof vi.fn>).mockImplementation(async () => {
        braveStarted = true;
        // Check that exa has also started (parallel execution)
        expect(exaStarted).toBe(true);
        return [];
      });

      (exa.search as ReturnType<typeof vi.fn>).mockImplementation(async () => {
        exaStarted = true;
        // Check that brave has also started (parallel execution)
        expect(braveStarted).toBe(true);
        return [];
      });

      const tool = new UnifiedSearchTool({ providers: { brave, exa } });
      await tool.execute({ query: 'test query' });
    });
  });

  describe('provider selection based on capabilities', () => {
    it('should use exa for hour freshness', async () => {
      const brave = createMockBraveProvider();
      const exa = createMockExaProvider();

      (brave.search as ReturnType<typeof vi.fn>).mockResolvedValueOnce([]);
      (exa.search as ReturnType<typeof vi.fn>).mockResolvedValueOnce([]);

      const tool = new UnifiedSearchTool({ providers: { brave, exa } });
      await tool.execute({ query: 'test', freshness: 'hour' });

      // Both should be called, but exa should have hour freshness
      const exaCall = (exa.search as ReturnType<typeof vi.fn>).mock.calls[0][0] as ProviderSearchParams;
      expect(exaCall.freshness).toBe('hour');

      // Brave should still get the call with fallback to day
      const braveCall = (brave.search as ReturnType<typeof vi.fn>).mock.calls[0][0] as ProviderSearchParams;
      expect(braveCall.freshness).toBe('hour'); // Provider handles the translation
    });

    it('should only use exa for social contentType', async () => {
      const brave = createMockBraveProvider();
      const exa = createMockExaProvider();

      (exa.search as ReturnType<typeof vi.fn>).mockResolvedValueOnce([]);

      const tool = new UnifiedSearchTool({ providers: { brave, exa } });
      await tool.execute({ query: 'test', contentType: 'social' });

      // Brave doesn't support social, so it shouldn't be called
      expect(brave.search).not.toHaveBeenCalled();
      expect(exa.search).toHaveBeenCalled();
    });

    it('should only use exa for research contentType', async () => {
      const brave = createMockBraveProvider();
      const exa = createMockExaProvider();

      (exa.search as ReturnType<typeof vi.fn>).mockResolvedValueOnce([]);

      const tool = new UnifiedSearchTool({ providers: { brave, exa } });
      await tool.execute({ query: 'test', contentType: 'research' });

      expect(brave.search).not.toHaveBeenCalled();
      expect(exa.search).toHaveBeenCalled();
    });

    it('should only use brave for images contentType', async () => {
      const brave = createMockBraveProvider();
      const exa = createMockExaProvider();

      (brave.search as ReturnType<typeof vi.fn>).mockResolvedValueOnce([]);

      const tool = new UnifiedSearchTool({ providers: { brave, exa } });
      await tool.execute({ query: 'test', contentType: 'images' });

      expect(brave.search).toHaveBeenCalled();
      expect(exa.search).not.toHaveBeenCalled();
    });

    it('should only use brave for videos contentType', async () => {
      const brave = createMockBraveProvider();
      const exa = createMockExaProvider();

      (brave.search as ReturnType<typeof vi.fn>).mockResolvedValueOnce([]);

      const tool = new UnifiedSearchTool({ providers: { brave, exa } });
      await tool.execute({ query: 'test', contentType: 'videos' });

      expect(brave.search).toHaveBeenCalled();
      expect(exa.search).not.toHaveBeenCalled();
    });
  });

  describe('result merging and deduplication', () => {
    it('should merge results from multiple providers', async () => {
      const brave = createMockBraveProvider();
      const exa = createMockExaProvider();

      const braveResults: UnifiedResult[] = [
        { title: 'Result 1', url: 'https://a.com', snippet: 'A', source: 'brave', contentType: 'web' },
        { title: 'Result 2', url: 'https://b.com', snippet: 'B', source: 'brave', contentType: 'web' },
      ];
      const exaResults: UnifiedResult[] = [
        { title: 'Result 3', url: 'https://c.com', snippet: 'C', source: 'exa', contentType: 'web' },
      ];

      (brave.search as ReturnType<typeof vi.fn>).mockResolvedValueOnce(braveResults);
      (exa.search as ReturnType<typeof vi.fn>).mockResolvedValueOnce(exaResults);

      const tool = new UnifiedSearchTool({ providers: { brave, exa } });
      const result = await tool.execute({ query: 'test' });

      // All 3 results should be present
      expect(result.content).toContain('Result 1');
      expect(result.content).toContain('Result 2');
      expect(result.content).toContain('Result 3');
    });

    it('should deduplicate results by URL', async () => {
      const brave = createMockBraveProvider();
      const exa = createMockExaProvider();

      const braveResults: UnifiedResult[] = [
        { title: 'Brave Version', url: 'https://same.com/page', snippet: 'From Brave', source: 'brave', contentType: 'web' },
      ];
      const exaResults: UnifiedResult[] = [
        { title: 'Exa Version', url: 'https://same.com/page', snippet: 'From Exa', source: 'exa', contentType: 'web' },
      ];

      (brave.search as ReturnType<typeof vi.fn>).mockResolvedValueOnce(braveResults);
      (exa.search as ReturnType<typeof vi.fn>).mockResolvedValueOnce(exaResults);

      const tool = new UnifiedSearchTool({ providers: { brave, exa } });
      const result = await tool.execute({ query: 'test' });

      // Should only have one entry for the URL
      const matches = (result.content.match(/same\.com\/page/g) || []).length;
      expect(matches).toBe(1);
    });
  });

  describe('domain filtering', () => {
    it('should filter results by includeDomains', async () => {
      const brave = createMockBraveProvider();

      const braveResults: UnifiedResult[] = [
        { title: 'Allowed', url: 'https://allowed.com/page', snippet: 'A', source: 'brave', contentType: 'web', domain: 'allowed.com' },
        { title: 'Blocked', url: 'https://blocked.com/page', snippet: 'B', source: 'brave', contentType: 'web', domain: 'blocked.com' },
      ];

      (brave.search as ReturnType<typeof vi.fn>).mockResolvedValueOnce(braveResults);

      const tool = new UnifiedSearchTool({
        providers: { brave },
      });
      const result = await tool.execute({
        query: 'test',
        includeDomains: ['allowed.com'],
      });

      expect(result.content).toContain('Allowed');
      expect(result.content).not.toContain('Blocked');
    });

    it('should filter results by excludeDomains', async () => {
      const brave = createMockBraveProvider();

      const braveResults: UnifiedResult[] = [
        { title: 'Allowed', url: 'https://allowed.com/page', snippet: 'A', source: 'brave', contentType: 'web', domain: 'allowed.com' },
        { title: 'Blocked', url: 'https://blocked.com/page', snippet: 'B', source: 'brave', contentType: 'web', domain: 'blocked.com' },
      ];

      (brave.search as ReturnType<typeof vi.fn>).mockResolvedValueOnce(braveResults);

      const tool = new UnifiedSearchTool({
        providers: { brave },
      });
      const result = await tool.execute({
        query: 'test',
        excludeDomains: ['blocked.com'],
      });

      expect(result.content).toContain('Allowed');
      expect(result.content).not.toContain('Blocked');
    });

    it('should respect config blockedDomains', async () => {
      const brave = createMockBraveProvider();

      const braveResults: UnifiedResult[] = [
        { title: 'Allowed', url: 'https://allowed.com', snippet: 'A', source: 'brave', contentType: 'web', domain: 'allowed.com' },
        { title: 'Blocked', url: 'https://spam.com', snippet: 'B', source: 'brave', contentType: 'web', domain: 'spam.com' },
      ];

      (brave.search as ReturnType<typeof vi.fn>).mockResolvedValueOnce(braveResults);

      const tool = new UnifiedSearchTool({
        providers: { brave },
        blockedDomains: ['spam.com'],
      });
      const result = await tool.execute({ query: 'test' });

      expect(result.content).toContain('Allowed');
      expect(result.content).not.toContain('Blocked');
    });
  });

  describe('error handling', () => {
    it('should return error for missing query', async () => {
      const brave = createMockBraveProvider();
      const tool = new UnifiedSearchTool({ providers: { brave } });

      const result = await tool.execute({});

      expect(result.isError).toBe(true);
      expect(result.content).toContain('query');
    });

    it('should return error for empty query', async () => {
      const brave = createMockBraveProvider();
      const tool = new UnifiedSearchTool({ providers: { brave } });

      const result = await tool.execute({ query: '   ' });

      expect(result.isError).toBe(true);
    });

    it('should handle provider errors gracefully', async () => {
      const brave = createMockBraveProvider();
      const exa = createMockExaProvider();

      (brave.search as ReturnType<typeof vi.fn>).mockRejectedValueOnce(new Error('Brave failed'));
      (exa.search as ReturnType<typeof vi.fn>).mockResolvedValueOnce([
        { title: 'Exa Result', url: 'https://exa.com', snippet: 'Works', source: 'exa', contentType: 'web' },
      ]);

      const tool = new UnifiedSearchTool({ providers: { brave, exa } });
      const result = await tool.execute({ query: 'test' });

      // Should still return exa results
      expect(result.isError).toBe(false);
      expect(result.content).toContain('Exa Result');
    });

    it('should return error if all providers fail', async () => {
      const brave = createMockBraveProvider();
      const exa = createMockExaProvider();

      (brave.search as ReturnType<typeof vi.fn>).mockRejectedValueOnce(new Error('Brave failed'));
      (exa.search as ReturnType<typeof vi.fn>).mockRejectedValueOnce(new Error('Exa failed'));

      const tool = new UnifiedSearchTool({ providers: { brave, exa } });
      const result = await tool.execute({ query: 'test' });

      expect(result.isError).toBe(true);
    });
  });

  describe('parameter passthrough', () => {
    it('should pass count to providers', async () => {
      const brave = createMockBraveProvider();
      (brave.search as ReturnType<typeof vi.fn>).mockResolvedValueOnce([]);

      const tool = new UnifiedSearchTool({ providers: { brave } });
      await tool.execute({ query: 'test', count: 15 });

      const call = (brave.search as ReturnType<typeof vi.fn>).mock.calls[0][0] as ProviderSearchParams;
      expect(call.count).toBe(15);
    });

    it('should pass freshness to providers', async () => {
      const exa = createMockExaProvider();
      (exa.search as ReturnType<typeof vi.fn>).mockResolvedValueOnce([]);

      const tool = new UnifiedSearchTool({ providers: { exa } });
      await tool.execute({ query: 'test', freshness: 'week' });

      const call = (exa.search as ReturnType<typeof vi.fn>).mock.calls[0][0] as ProviderSearchParams;
      expect(call.freshness).toBe('week');
    });

    it('should pass startDate and endDate to providers', async () => {
      const exa = createMockExaProvider();
      (exa.search as ReturnType<typeof vi.fn>).mockResolvedValueOnce([]);

      const tool = new UnifiedSearchTool({ providers: { exa } });
      await tool.execute({
        query: 'test',
        startDate: '2025-01-31T08:00:00.000Z',
        endDate: '2025-01-31T12:00:00.000Z',
      });

      const call = (exa.search as ReturnType<typeof vi.fn>).mock.calls[0][0] as ProviderSearchParams;
      expect(call.startDate).toBe('2025-01-31T08:00:00.000Z');
      expect(call.endDate).toBe('2025-01-31T12:00:00.000Z');
    });
  });

  describe('no results', () => {
    it('should handle no results gracefully', async () => {
      const brave = createMockBraveProvider();
      (brave.search as ReturnType<typeof vi.fn>).mockResolvedValueOnce([]);

      const tool = new UnifiedSearchTool({ providers: { brave } });
      const result = await tool.execute({ query: 'very obscure query' });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('No results');
    });
  });

  describe('result formatting', () => {
    it('should format results with numbered list', async () => {
      const brave = createMockBraveProvider();
      const results: UnifiedResult[] = [
        { title: 'First', url: 'https://a.com', snippet: 'A', source: 'brave', contentType: 'web' },
        { title: 'Second', url: 'https://b.com', snippet: 'B', source: 'brave', contentType: 'web' },
      ];
      (brave.search as ReturnType<typeof vi.fn>).mockResolvedValueOnce(results);

      const tool = new UnifiedSearchTool({ providers: { brave } });
      const result = await tool.execute({ query: 'test' });

      expect(result.content).toMatch(/1\.\s+First/);
      expect(result.content).toMatch(/2\.\s+Second/);
    });

    it('should include source indicator', async () => {
      const brave = createMockBraveProvider();
      const results: UnifiedResult[] = [
        { title: 'Result', url: 'https://a.com', snippet: 'A', source: 'brave', contentType: 'web' },
      ];
      (brave.search as ReturnType<typeof vi.fn>).mockResolvedValueOnce(results);

      const tool = new UnifiedSearchTool({ providers: { brave } });
      const result = await tool.execute({ query: 'test' });

      expect(result.content).toContain('brave');
    });
  });
});
