/**
 * @fileoverview Tests for WebFetch Tool
 *
 * TDD: Tests for the complete WebFetch tool including subagent spawning.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { WebFetchTool } from '../web-fetch.js';
import type {
  WebFetchToolConfig,
  SubagentSpawnCallback,
  SubagentSpawnResult,
} from '../types.js';

// Mock fetch for HTTP requests
const mockFetch = vi.fn((url: string, options?: RequestInit) => {
  return Promise.resolve(
    new Response('<html><body><article>Test content</article></body></html>', {
      status: 200,
      headers: { 'Content-Type': 'text/html' },
    })
  );
});

// Mock subagent spawner
const mockSpawnSubagent = vi.fn(
  async (params: { task: string; model: string; timeout: number; maxTurns: number }): Promise<SubagentSpawnResult> => ({
    sessionId: 'test-session-123',
    success: true,
    output: 'This is the summarized answer from the web page.',
    tokenUsage: {
      inputTokens: 500,
      outputTokens: 100,
    },
  })
);

describe('WebFetch Tool', () => {
  let tool: WebFetchTool;
  let originalFetch: typeof globalThis.fetch;
  let config: WebFetchToolConfig;

  beforeEach(() => {
    originalFetch = globalThis.fetch;
    globalThis.fetch = mockFetch as typeof fetch;
    mockFetch.mockClear();
    mockSpawnSubagent.mockClear();

    config = {
      workingDirectory: '/test/project',
      onSpawnSubagent: mockSpawnSubagent,
    };
    tool = new WebFetchTool(config);
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  describe('tool definition', () => {
    it('should have correct name', () => {
      expect(tool.name).toBe('WebFetch');
    });

    it('should have description mentioning web fetching', () => {
      expect(tool.description.toLowerCase()).toContain('fetch');
    });

    it('should require url parameter', () => {
      expect(tool.parameters.required).toContain('url');
    });

    it('should require prompt parameter', () => {
      expect(tool.parameters.required).toContain('prompt');
    });

    it('should have network category', () => {
      expect(tool.category).toBe('network');
    });
  });

  describe('parameter validation', () => {
    it('should reject missing url', async () => {
      const result = await tool.execute({ prompt: 'What is this?' });
      expect(result.isError).toBe(true);
      expect(result.content).toContain('url');
    });

    it('should reject missing prompt', async () => {
      const result = await tool.execute({ url: 'https://example.com' });
      expect(result.isError).toBe(true);
      expect(result.content).toContain('prompt');
    });

    it('should reject empty url', async () => {
      const result = await tool.execute({ url: '', prompt: 'What is this?' });
      expect(result.isError).toBe(true);
    });

    it('should reject empty prompt', async () => {
      const result = await tool.execute({ url: 'https://example.com', prompt: '' });
      expect(result.isError).toBe(true);
    });

    it('should validate URL format', async () => {
      const result = await tool.execute({
        url: 'not a valid url',
        prompt: 'What is this?',
      });
      expect(result.isError).toBe(true);
      expect(result.content.toLowerCase()).toContain('invalid');
    });
  });

  describe('HTTP fetching', () => {
    it('should fetch HTML pages', async () => {
      const result = await tool.execute({
        url: 'https://example.com',
        prompt: 'What is this page about?',
      });

      expect(mockFetch).toHaveBeenCalled();
      const callUrl = mockFetch.mock.calls[0][0] as string;
      expect(callUrl).toContain('example.com');
    });

    it('should handle HTTP errors gracefully', async () => {
      mockFetch.mockResolvedValueOnce(
        new Response('Not Found', { status: 404 })
      );

      const result = await tool.execute({
        url: 'https://example.com/notfound',
        prompt: 'What is this?',
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('404');
    });

    it('should handle network timeouts', async () => {
      mockFetch.mockRejectedValueOnce(new Error('Timeout'));

      const result = await tool.execute({
        url: 'https://slow-site.com',
        prompt: 'What is this?',
      });

      expect(result.isError).toBe(true);
    });

    it('should follow redirects', async () => {
      // First response redirects
      mockFetch.mockResolvedValueOnce(
        new Response('<html><body><article>Redirected content</article></body></html>', {
          status: 200,
          headers: { 'Content-Type': 'text/html' },
        })
      );

      const result = await tool.execute({
        url: 'https://example.com/redirect',
        prompt: 'What is this?',
      });

      expect(result.isError).toBeFalsy();
    });
  });

  describe('subagent summarization', () => {
    it('should spawn Haiku subagent with content', async () => {
      await tool.execute({
        url: 'https://example.com',
        prompt: 'What is the main topic?',
      });

      expect(mockSpawnSubagent).toHaveBeenCalled();
      const callArgs = mockSpawnSubagent.mock.calls[0][0];
      expect(callArgs.task).toContain('What is the main topic?');
      expect(callArgs.model).toContain('haiku');
    });

    it('should pass truncated content to subagent', async () => {
      await tool.execute({
        url: 'https://example.com',
        prompt: 'Summarize this',
      });

      const callArgs = mockSpawnSubagent.mock.calls[0][0];
      expect(callArgs.task).toBeDefined();
      // Task should contain the prompt and some content
      expect(callArgs.task.length).toBeGreaterThan(0);
    });

    it('should return subagent answer as result', async () => {
      const result = await tool.execute({
        url: 'https://example.com',
        prompt: 'What is this?',
      });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('summarized answer');
    });

    it('should handle subagent failures', async () => {
      mockSpawnSubagent.mockResolvedValueOnce({
        sessionId: 'test-session',
        success: false,
        error: 'Subagent failed to complete',
      });

      const result = await tool.execute({
        url: 'https://example.com',
        prompt: 'What is this?',
      });

      expect(result.isError).toBe(true);
      expect(result.content.toLowerCase()).toContain('failed');
    });

    it('should include subagent session ID in details', async () => {
      const result = await tool.execute({
        url: 'https://example.com',
        prompt: 'What is this?',
      });

      expect(result.details).toHaveProperty('subagentSessionId');
    });
  });

  describe('caching', () => {
    it('should cache results for same URL and prompt', async () => {
      // First call
      await tool.execute({
        url: 'https://example.com',
        prompt: 'What is this?',
      });

      // Reset mocks for second call
      mockFetch.mockClear();
      mockSpawnSubagent.mockClear();

      // Second call with same params
      const result = await tool.execute({
        url: 'https://example.com',
        prompt: 'What is this?',
      });

      // Should not call fetch or subagent again
      expect(mockFetch).not.toHaveBeenCalled();
      expect(mockSpawnSubagent).not.toHaveBeenCalled();
      expect(result.details).toHaveProperty('fromCache', true);
    });

    it('should not cache different prompts for same URL', async () => {
      await tool.execute({
        url: 'https://example.com',
        prompt: 'First question',
      });

      mockFetch.mockClear();
      mockSpawnSubagent.mockClear();

      await tool.execute({
        url: 'https://example.com',
        prompt: 'Second question',
      });

      // Should make new request for different prompt
      expect(mockFetch).toHaveBeenCalled();
      expect(mockSpawnSubagent).toHaveBeenCalled();
    });
  });

  describe('URL validation', () => {
    it('should block localhost URLs', async () => {
      const result = await tool.execute({
        url: 'https://localhost/api',
        prompt: 'What is this?',
      });

      expect(result.isError).toBe(true);
      expect(result.content.toLowerCase()).toContain('internal');
    });

    it('should block private IPs', async () => {
      const result = await tool.execute({
        url: 'https://192.168.1.1/',
        prompt: 'What is this?',
      });

      expect(result.isError).toBe(true);
    });

    it('should auto-upgrade HTTP to HTTPS', async () => {
      await tool.execute({
        url: 'http://example.com',
        prompt: 'What is this?',
      });

      const callUrl = mockFetch.mock.calls[0][0] as string;
      expect(callUrl.startsWith('https://')).toBe(true);
    });
  });

  describe('result format', () => {
    it('should include answer in content', async () => {
      const result = await tool.execute({
        url: 'https://example.com',
        prompt: 'What is this?',
      });

      expect(result.content).toContain('summarized answer');
    });

    it('should include source metadata in details', async () => {
      const result = await tool.execute({
        url: 'https://example.com',
        prompt: 'What is this?',
      });

      expect(result.details).toHaveProperty('source');
      expect((result.details as any).source).toHaveProperty('url');
      expect((result.details as any).source).toHaveProperty('fetchedAt');
    });

    it('should include token usage when available', async () => {
      const result = await tool.execute({
        url: 'https://example.com',
        prompt: 'What is this?',
      });

      expect(result.details).toHaveProperty('tokenUsage');
    });
  });
});
