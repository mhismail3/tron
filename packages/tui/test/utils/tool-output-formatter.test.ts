/**
 * @fileoverview Tool Output Formatter Tests (TDD)
 *
 * These tests define the expected behavior for tool-specific output formatting.
 * Tool outputs should show concise summaries similar to Claude Code:
 * - Read: "Found X lines"
 * - Write: "Wrote X lines"
 * - Edit: "Added X lines, removed Y lines"
 * - Bash: First few lines of output
 */
import { describe, it, expect } from 'vitest';
import {
  formatToolOutput,
  formatReadOutput,
  formatWriteOutput,
  formatEditOutput,
  formatBashOutput,
  formatGlobOutput,
  formatGrepOutput,
  truncateOutput,
  countLines,
} from '../../src/utils/tool-output-formatter.js';

describe('Tool Output Formatter Utilities', () => {
  describe('countLines', () => {
    it('should count lines in a string', () => {
      expect(countLines('line1\nline2\nline3')).toBe(3);
    });

    it('should return 1 for single line', () => {
      expect(countLines('single line')).toBe(1);
    });

    it('should return 0 for empty string', () => {
      expect(countLines('')).toBe(0);
    });

    it('should handle trailing newlines', () => {
      expect(countLines('line1\nline2\n')).toBe(2);
    });
  });

  describe('truncateOutput', () => {
    it('should truncate long output to specified lines', () => {
      const output = 'line1\nline2\nline3\nline4\nline5';
      const result = truncateOutput(output, 3);
      expect(result.lines).toEqual(['line1', 'line2', 'line3']);
      expect(result.totalLines).toBe(5);
      expect(result.truncated).toBe(true);
    });

    it('should not truncate short output', () => {
      const output = 'line1\nline2';
      const result = truncateOutput(output, 3);
      expect(result.lines).toEqual(['line1', 'line2']);
      expect(result.truncated).toBe(false);
    });

    it('should filter empty lines', () => {
      const output = 'line1\n\nline2\n\n';
      const result = truncateOutput(output, 5);
      expect(result.lines).toEqual(['line1', 'line2']);
    });

    it('should truncate long lines', () => {
      const longLine = 'x'.repeat(100);
      const result = truncateOutput(longLine, 3, 50);
      expect(result.lines[0]?.length).toBeLessThanOrEqual(53); // 50 + '...'
      expect(result.lines[0]).toContain('...');
    });
  });

  describe('formatReadOutput', () => {
    it('should format read output with line count', () => {
      const content = 'line1\nline2\nline3\nline4\nline5';
      const result = formatReadOutput(content);
      expect(result.summary).toBe('Read 5 lines');
      expect(result.preview).toBeDefined();
    });

    it('should use singular "line" for 1 line', () => {
      const content = 'single line';
      const result = formatReadOutput(content);
      expect(result.summary).toBe('Read 1 line');
    });

    it('should include file path in summary if provided', () => {
      const content = 'content';
      const result = formatReadOutput(content, '/path/to/file.ts');
      expect(result.summary).toContain('Read 1 line');
    });

    it('should handle binary/empty content', () => {
      const result = formatReadOutput('');
      expect(result.summary).toBe('Empty file');
    });

    it('should provide preview of first few lines', () => {
      const content = 'line1\nline2\nline3\nline4\nline5\nline6';
      const result = formatReadOutput(content);
      expect(result.preview.length).toBeLessThanOrEqual(3);
    });
  });

  describe('formatWriteOutput', () => {
    it('should format write output with line count', () => {
      const content = 'line1\nline2\nline3';
      const result = formatWriteOutput(content);
      expect(result.summary).toBe('Wrote 3 lines');
    });

    it('should include file path if provided', () => {
      const content = 'content';
      const result = formatWriteOutput(content, '/path/to/file.ts');
      expect(result.summary).toBe('Wrote 1 line');
    });

    it('should handle new file creation', () => {
      const content = 'new content';
      const result = formatWriteOutput(content, '/path/to/file.ts', true);
      expect(result.summary).toBe('Created file with 1 line');
    });
  });

  describe('formatEditOutput', () => {
    it('should format edit output with added/removed lines', () => {
      const result = formatEditOutput({
        added: 5,
        removed: 3,
      });
      expect(result.summary).toBe('+5 lines, -3 lines');
    });

    it('should show only added when no lines removed', () => {
      const result = formatEditOutput({
        added: 3,
        removed: 0,
      });
      expect(result.summary).toBe('+3 lines');
    });

    it('should show only removed when no lines added', () => {
      const result = formatEditOutput({
        added: 0,
        removed: 2,
      });
      expect(result.summary).toBe('-2 lines');
    });

    it('should handle replace_all flag', () => {
      const result = formatEditOutput({
        added: 5,
        removed: 5,
        replaceAll: true,
        occurrences: 3,
      });
      expect(result.summary).toContain('3 occurrences');
    });

    it('should parse diff-style output', () => {
      const diffOutput = `--- old
+++ new
@@ -1,3 +1,4 @@
 unchanged
-removed line
+added line 1
+added line 2
 unchanged`;
      const result = formatEditOutput({ diffOutput });
      expect(result.summary).toBe('+2 lines, -1 line');
    });
  });

  describe('formatBashOutput', () => {
    it('should truncate long bash output', () => {
      const output = Array.from({ length: 20 }, (_, i) => `line ${i + 1}`).join('\n');
      const result = formatBashOutput(output);
      expect(result.preview.length).toBeLessThanOrEqual(3);
      expect(result.truncated).toBe(true);
    });

    it('should show exit code when provided', () => {
      const result = formatBashOutput('output', { exitCode: 1 });
      expect(result.summary).toContain('exit 1');
    });

    it('should indicate success for exit code 0', () => {
      const result = formatBashOutput('output', { exitCode: 0 });
      expect(result.summary).not.toContain('exit');
    });

    it('should handle empty output', () => {
      const result = formatBashOutput('');
      expect(result.summary).toBe('No output');
    });

    it('should show line count in summary', () => {
      const output = 'line1\nline2\nline3\nline4\nline5';
      const result = formatBashOutput(output);
      expect(result.summary).toBe('5 lines');
    });
  });

  describe('formatGlobOutput', () => {
    it('should show file count', () => {
      const files = '/path/to/file1.ts\n/path/to/file2.ts\n/path/to/file3.ts';
      const result = formatGlobOutput(files);
      expect(result.summary).toBe('Found 3 files');
    });

    it('should use singular "file" for 1 file', () => {
      const files = '/path/to/file.ts';
      const result = formatGlobOutput(files);
      expect(result.summary).toBe('Found 1 file');
    });

    it('should handle no matches', () => {
      const result = formatGlobOutput('');
      expect(result.summary).toBe('No files found');
    });
  });

  describe('formatGrepOutput', () => {
    it('should show match count', () => {
      const matches = 'file1.ts:10:match\nfile1.ts:20:match\nfile2.ts:5:match';
      const result = formatGrepOutput(matches);
      expect(result.summary).toBe('Found 3 matches');
    });

    it('should use singular "match" for 1 match', () => {
      const matches = 'file.ts:10:match';
      const result = formatGrepOutput(matches);
      expect(result.summary).toBe('Found 1 match');
    });

    it('should handle no matches', () => {
      const result = formatGrepOutput('');
      expect(result.summary).toBe('No matches found');
    });
  });

  describe('formatToolOutput (unified entry point)', () => {
    it('should route to correct formatter based on tool name', () => {
      const content = 'line1\nline2\nline3';

      const readResult = formatToolOutput('read', content);
      expect(readResult.summary).toBe('Read 3 lines');

      const writeResult = formatToolOutput('write', content);
      expect(writeResult.summary).toBe('Wrote 3 lines');

      const bashResult = formatToolOutput('bash', content);
      expect(bashResult.summary).toBe('3 lines');
    });

    it('should handle case-insensitive tool names', () => {
      const content = 'line1\nline2';

      expect(formatToolOutput('Read', content).summary).toBe('Read 2 lines');
      expect(formatToolOutput('READ', content).summary).toBe('Read 2 lines');
    });

    it('should provide fallback for unknown tools', () => {
      const content = 'some output';
      const result = formatToolOutput('unknown_tool', content);
      expect(result.summary).toBeDefined();
      expect(result.preview).toBeDefined();
    });

    it('should handle error outputs', () => {
      const errorContent = 'Error: File not found';
      const result = formatToolOutput('read', errorContent, { isError: true });
      expect(result.summary).toContain('Error');
    });
  });

  describe('Edge cases', () => {
    it('should handle undefined/null content gracefully', () => {
      expect(() => formatToolOutput('read', undefined as unknown as string)).not.toThrow();
      expect(() => formatToolOutput('read', null as unknown as string)).not.toThrow();
    });

    it('should handle very long single lines', () => {
      const longLine = 'x'.repeat(10000);
      const result = formatToolOutput('bash', longLine);
      expect(result.preview[0]?.length).toBeLessThan(200);
    });

    it('should handle mixed line endings', () => {
      const content = 'line1\r\nline2\nline3\rline4';
      const result = formatReadOutput(content);
      expect(result.summary).toContain('lines');
    });
  });
});
