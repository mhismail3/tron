/**
 * @fileoverview Tests for Content Truncator
 *
 * TDD: Tests for smart content truncation that preserves structure.
 */

import { describe, it, expect } from 'vitest';
import {
  truncateContent,
  ContentTruncator,
  estimateTokens,
} from '../content-truncator.js';
import type { ContentTruncatorConfig } from '../types.js';

describe('Content Truncator', () => {
  describe('estimateTokens function', () => {
    it('should estimate tokens from character count', () => {
      // ~4 chars per token
      expect(estimateTokens(100)).toBe(25);
      expect(estimateTokens(400)).toBe(100);
    });

    it('should round up token estimates', () => {
      expect(estimateTokens(10)).toBe(3); // 10/4 = 2.5 -> 3
    });

    it('should handle empty string', () => {
      expect(estimateTokens(0)).toBe(0);
    });
  });

  describe('truncateContent function', () => {
    describe('content under limit', () => {
      it('should return content unchanged if under token limit', () => {
        const content = 'Short content that fits.';
        const result = truncateContent(content, { maxTokens: 1000 });
        expect(result.truncated).toBe(false);
        expect(result.content).toBe(content);
      });

      it('should report original and final tokens as equal when not truncated', () => {
        const content = 'Short content.';
        const result = truncateContent(content);
        expect(result.originalTokens).toBe(result.finalTokens);
      });
    });

    describe('basic truncation', () => {
      it('should truncate content exceeding token limit', () => {
        const content = 'x'.repeat(1000); // ~250 tokens
        const result = truncateContent(content, { maxTokens: 50 }); // ~200 chars
        expect(result.truncated).toBe(true);
        expect(result.finalTokens).toBeLessThanOrEqual(50);
      });

      it('should add truncation marker', () => {
        const content = 'x'.repeat(1000);
        const result = truncateContent(content, { maxTokens: 50 });
        expect(result.content).toContain('[Content truncated');
      });

      it('should report token counts correctly', () => {
        const content = 'x'.repeat(400); // ~100 tokens
        const result = truncateContent(content, { maxTokens: 25 });
        expect(result.originalTokens).toBe(100);
        expect(result.truncated).toBe(true);
      });
    });

    describe('structure preservation', () => {
      it('should preserve first N lines', () => {
        const lines = Array.from({ length: 200 }, (_, i) => `Line ${i + 1}`);
        const content = lines.join('\n');
        const result = truncateContent(content, {
          maxTokens: 100,
          preserveStartLines: 10,
        });

        expect(result.content).toContain('Line 1');
        expect(result.content).toContain('Line 5');
        expect(result.content).toContain('Line 10');
      });

      it('should preserve markdown headers when possible', () => {
        const content = `# Main Title

This is the introduction paragraph with some content.

## Section 1

Content for section 1 that goes on and on and on with lots of detail.

## Section 2

Content for section 2 with even more detail that continues.

## Section 3

Yet more content here.`;

        const result = truncateContent(content, { maxTokens: 50 });
        // Should preserve the title at minimum
        expect(result.content).toContain('# Main Title');
      });

      it('should preserve code blocks when possible', () => {
        const content = `# Documentation

\`\`\`javascript
function example() {
  return 'Hello';
}
\`\`\`

More content here that continues on and on.

${'Extra content. '.repeat(100)}`;

        const result = truncateContent(content, { maxTokens: 100 });
        // Should try to preserve the code block
        expect(result.content).toContain('```');
      });

      it('should track lines preserved', () => {
        const lines = Array.from({ length: 100 }, (_, i) => `Line ${i + 1}`);
        const content = lines.join('\n');
        const result = truncateContent(content, { maxTokens: 50 });
        expect(result.linesPreserved).toBeGreaterThan(0);
        expect(result.linesPreserved).toBeLessThan(100);
      });
    });

    describe('configuration options', () => {
      it('should respect custom maxTokens', () => {
        const content = 'x'.repeat(400); // ~100 tokens
        const result = truncateContent(content, { maxTokens: 10 });
        expect(result.finalTokens).toBeLessThanOrEqual(15); // Allow some overhead for marker
      });

      it('should respect custom charsPerToken', () => {
        const content = 'x'.repeat(100);
        // With 2 chars per token, 100 chars = 50 tokens
        const result = truncateContent(content, {
          maxTokens: 20,
          charsPerToken: 2,
        });
        expect(result.truncated).toBe(true);
      });

      it('should handle preserveStartLines of 0', () => {
        const content = 'Line 1\nLine 2\nLine 3';
        const result = truncateContent(content, {
          maxTokens: 1000,
          preserveStartLines: 0,
        });
        expect(result.content).toContain('Line 1');
      });
    });

    describe('edge cases', () => {
      it('should handle empty content', () => {
        const result = truncateContent('');
        expect(result.truncated).toBe(false);
        expect(result.content).toBe('');
        expect(result.originalTokens).toBe(0);
        expect(result.finalTokens).toBe(0);
      });

      it('should handle single line content', () => {
        const content = 'Single line of text.';
        const result = truncateContent(content, { maxTokens: 1000 });
        expect(result.content).toBe(content);
        expect(result.linesPreserved).toBe(1);
      });

      it('should handle content with only whitespace', () => {
        const result = truncateContent('   \n\n  \t  ');
        expect(result.content).toBe('');
      });

      it('should handle very low token limit', () => {
        const content = 'Some content here.';
        const result = truncateContent(content, { maxTokens: 1 });
        expect(result.truncated).toBe(true);
        expect(result.content.length).toBeGreaterThan(0);
      });
    });
  });

  describe('ContentTruncator class', () => {
    it('should create truncator with default config', () => {
      const truncator = new ContentTruncator();
      expect(truncator).toBeDefined();
    });

    it('should truncate using instance method', () => {
      const truncator = new ContentTruncator({ maxTokens: 50 });
      const content = 'x'.repeat(1000);
      const result = truncator.truncate(content);
      expect(result.truncated).toBe(true);
    });

    it('should allow config override per call', () => {
      const truncator = new ContentTruncator({ maxTokens: 1000 });
      const content = 'x'.repeat(200);
      const result = truncator.truncate(content, { maxTokens: 10 });
      expect(result.truncated).toBe(true);
    });

    it('should update config', () => {
      const truncator = new ContentTruncator({ maxTokens: 1000 });
      truncator.updateConfig({ maxTokens: 10 });
      const content = 'x'.repeat(200);
      const result = truncator.truncate(content);
      expect(result.truncated).toBe(true);
    });

    it('should get current config', () => {
      const truncator = new ContentTruncator({ maxTokens: 100 });
      const config = truncator.getConfig();
      expect(config.maxTokens).toBe(100);
    });
  });
});
