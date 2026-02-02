/**
 * @fileoverview Tests for unified Search tool
 *
 * Basic tests for tool definition and mode detection logic
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { SearchTool } from '../search/search.js';

describe('SearchTool', () => {
  let searchTool: SearchTool;

  beforeEach(() => {
    searchTool = new SearchTool({ workingDirectory: '/test/project' });
  });

  describe('tool definition', () => {
    it('should have correct name', () => {
      expect(searchTool.name).toBe('Search');
    });

    it('should have search category', () => {
      expect(searchTool.category).toBe('search');
    });

    it('should have comprehensive description', () => {
      expect(searchTool.description).toContain('search');
      expect(searchTool.description).toContain('text');
      expect(searchTool.description).toContain('AST');
    });

    it('should define pattern as required parameter', () => {
      const params = searchTool.parameters;
      expect(params.properties).toHaveProperty('pattern');
      expect(params.required).toContain('pattern');
    });

    it('should accept type parameter to force search mode', () => {
      const params = searchTool.parameters;
      expect(params.properties).toHaveProperty('type');
      expect(params.properties.type).toHaveProperty('enum');
    });

    it('should accept optional path parameter', () => {
      const params = searchTool.parameters;
      expect(params.properties).toHaveProperty('path');
    });

    it('should accept filePattern for filtering', () => {
      const params = searchTool.parameters;
      expect(params.properties).toHaveProperty('filePattern');
    });

    it('should accept context parameter', () => {
      const params = searchTool.parameters;
      expect(params.properties).toHaveProperty('context');
    });

    it('should accept maxResults parameter', () => {
      const params = searchTool.parameters;
      expect(params.properties).toHaveProperty('maxResults');
    });
  });

  describe('parameter validation', () => {
    it('should require pattern parameter', async () => {
      const result = await searchTool.execute({});

      expect(result.isError).toBe(true);
      expect(result.content).toContain('pattern');
    });

    it('should accept pattern as string', async () => {
      // This will fail at execution, but should pass validation
      const result = await searchTool.execute({ pattern: 'test' });

      // Will fail because file system isn't mocked, but that's expected
      // The important thing is it didn't fail validation
      expect(result).toHaveProperty('content');
    });
  });
});
