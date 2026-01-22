/**
 * @fileoverview File Completion Tests
 *
 * Tests for file path auto-completion with @ prefix.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import * as fs from 'fs/promises';
import * as path from 'path';
import {
  FileCompletion,
  fuzzyMatch,
  scoreMatch,
} from '../../src/utils/file-completion.js';

// Mock fs module
vi.mock('fs/promises');

describe('File Completion', () => {
  describe('fuzzyMatch', () => {
    it('matches exact string', () => {
      expect(fuzzyMatch('test', 'test')).toBe(true);
    });

    it('matches case insensitively', () => {
      expect(fuzzyMatch('TEST', 'test')).toBe(true);
      expect(fuzzyMatch('test', 'TEST')).toBe(true);
    });

    it('matches subsequences', () => {
      expect(fuzzyMatch('tst', 'test')).toBe(true);
      expect(fuzzyMatch('src', 'source')).toBe(true);
      expect(fuzzyMatch('abc', 'aXbXc')).toBe(true);
    });

    it('rejects non-matching patterns', () => {
      expect(fuzzyMatch('xyz', 'test')).toBe(false);
      expect(fuzzyMatch('ba', 'abc')).toBe(false);
    });

    it('handles empty query', () => {
      expect(fuzzyMatch('', 'anything')).toBe(true);
    });
  });

  describe('scoreMatch', () => {
    it('scores exact match highest', () => {
      const exactScore = scoreMatch('test', 'test');
      const partialScore = scoreMatch('test', 'testing');
      expect(exactScore).toBeGreaterThan(partialScore);
    });

    it('scores prefix match higher than middle match', () => {
      const prefixScore = scoreMatch('src', 'src/file.ts');
      const middleScore = scoreMatch('src', 'my-src/file.ts');
      expect(prefixScore).toBeGreaterThan(middleScore);
    });

    it('scores shorter paths higher', () => {
      const shortScore = scoreMatch('test', 'test.ts');
      const longScore = scoreMatch('test', 'a/b/c/test.ts');
      expect(shortScore).toBeGreaterThan(longScore);
    });

    it('returns 0 for non-matches', () => {
      expect(scoreMatch('xyz', 'test')).toBe(0);
    });
  });

  describe('FileCompletion', () => {
    let completion: FileCompletion;
    const mockFiles = [
      'src/index.ts',
      'src/utils/helpers.ts',
      'src/components/Button.tsx',
      'package.json',
      'README.md',
      'tests/unit/test.ts',
    ];

    beforeEach(() => {
      completion = new FileCompletion('/project');

      // Mock readdirSync to return mock files
      vi.mocked(fs.readdir).mockImplementation(async (dir) => {
        const dirStr = String(dir);
        if (dirStr === '/project') {
          return ['src', 'tests', 'package.json', 'README.md'] as unknown as fs.Dirent[];
        }
        if (dirStr === '/project/src') {
          return ['index.ts', 'utils', 'components'] as unknown as fs.Dirent[];
        }
        if (dirStr === '/project/src/utils') {
          return ['helpers.ts'] as unknown as fs.Dirent[];
        }
        if (dirStr === '/project/src/components') {
          return ['Button.tsx'] as unknown as fs.Dirent[];
        }
        if (dirStr === '/project/tests') {
          return ['unit'] as unknown as fs.Dirent[];
        }
        if (dirStr === '/project/tests/unit') {
          return ['test.ts'] as unknown as fs.Dirent[];
        }
        return [];
      });

      vi.mocked(fs.stat).mockImplementation(async (filePath) => {
        const pathStr = String(filePath);
        const isDir = !pathStr.includes('.');
        return {
          isDirectory: () => isDir,
          isFile: () => !isDir,
        } as fs.Stats;
      });
    });

    afterEach(() => {
      vi.clearAllMocks();
    });

    describe('search', () => {
      it('returns matching files', async () => {
        completion.setFiles(mockFiles);

        const results = await completion.search('helpers');

        expect(results).toContain('src/utils/helpers.ts');
      });

      it('returns multiple matches', async () => {
        completion.setFiles(mockFiles);

        const results = await completion.search('ts');

        expect(results.length).toBeGreaterThan(1);
        expect(results.every((r) => r.includes('ts'))).toBe(true);
      });

      it('limits results', async () => {
        completion.setFiles(mockFiles);

        const results = await completion.search('', 3);

        expect(results.length).toBeLessThanOrEqual(3);
      });

      it('returns empty for no matches', async () => {
        completion.setFiles(mockFiles);

        const results = await completion.search('xyz123');

        expect(results).toHaveLength(0);
      });
    });

    describe('trigger', () => {
      it('has @ as trigger character', () => {
        expect(completion.trigger).toBe('@');
      });
    });
  });
});
