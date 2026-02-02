/**
 * @fileoverview Tests for OpenURL tool
 *
 * Tests for native Safari browser opening functionality
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { OpenURLTool } from '../browser/open-url.js';

describe('OpenURLTool', () => {
  let openBrowserTool: OpenURLTool;

  beforeEach(() => {
    openBrowserTool = new OpenURLTool({ workingDirectory: '/test/project' });
  });

  describe('tool definition', () => {
    it('should have correct name', () => {
      expect(openBrowserTool.name).toBe('OpenURL');
    });

    it('should have description mentioning Safari', () => {
      expect(openBrowserTool.description).toContain('Safari');
    });

    it('should define url as required parameter', () => {
      const params = openBrowserTool.parameters;
      expect(params.properties).toHaveProperty('url');
      expect(params.required).toContain('url');
    });

    it('should have custom category', () => {
      expect(openBrowserTool.category).toBe('custom');
    });
  });

  describe('execute - URL validation', () => {
    it('should accept valid https URL', async () => {
      const result = await openBrowserTool.execute({ url: 'https://example.com' });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('Opening');
      expect(result.content).toContain('https://example.com');
    });

    it('should accept valid http URL', async () => {
      const result = await openBrowserTool.execute({ url: 'http://example.com' });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('Opening');
    });

    it('should accept URL with path', async () => {
      const result = await openBrowserTool.execute({
        url: 'https://example.com/path/to/page',
      });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('https://example.com/path/to/page');
    });

    it('should accept URL with query parameters', async () => {
      const result = await openBrowserTool.execute({
        url: 'https://example.com/search?q=test&page=1',
      });

      expect(result.isError).toBeFalsy();
    });

    it('should reject missing url parameter', async () => {
      const result = await openBrowserTool.execute({});

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Missing required parameter');
    });

    it('should reject empty url', async () => {
      const result = await openBrowserTool.execute({ url: '' });

      expect(result.isError).toBe(true);
      // Empty string is treated as missing parameter
      expect(result.content).toContain('Missing required parameter');
    });

    it('should reject whitespace-only url', async () => {
      const result = await openBrowserTool.execute({ url: '   ' });

      expect(result.isError).toBe(true);
    });

    it('should reject invalid URL format', async () => {
      const result = await openBrowserTool.execute({ url: 'not-a-valid-url' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Invalid URL');
    });

    it('should reject file:// URLs', async () => {
      const result = await openBrowserTool.execute({ url: 'file:///etc/passwd' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Invalid URL scheme');
    });

    it('should reject javascript: URLs', async () => {
      const result = await openBrowserTool.execute({ url: 'javascript:alert(1)' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Invalid URL scheme');
    });

    it('should reject ftp:// URLs', async () => {
      const result = await openBrowserTool.execute({ url: 'ftp://example.com' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Invalid URL scheme');
    });

    it('should trim whitespace from URL', async () => {
      const result = await openBrowserTool.execute({
        url: '  https://example.com  ',
      });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('https://example.com');
    });
  });

  describe('execute - result details', () => {
    it('should return url in details', async () => {
      const result = await openBrowserTool.execute({
        url: 'https://example.com',
      });

      expect(result.details).toHaveProperty('url', 'https://example.com');
    });

    it('should return action type in details', async () => {
      const result = await openBrowserTool.execute({
        url: 'https://example.com',
      });

      expect(result.details).toHaveProperty('action', 'open_safari');
    });
  });
});
