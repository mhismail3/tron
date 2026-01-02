/**
 * @fileoverview Markdown Parser Tests
 *
 * Simple, focused tests for the markdown parser.
 */
import { describe, it, expect } from 'vitest';
import { parseMarkdown, tokenize } from '../../src/components/markdown.js';

describe('parseMarkdown', () => {
  describe('empty input', () => {
    it('returns empty array for empty string', () => {
      expect(parseMarkdown('')).toEqual([]);
    });

    it('returns empty array for whitespace', () => {
      expect(parseMarkdown('   ')).toEqual([]);
    });
  });

  describe('paragraphs', () => {
    it('parses single paragraph', () => {
      const result = parseMarkdown('Hello world');
      expect(result).toHaveLength(1);
      expect(result[0]!.type).toBe('paragraph');
      expect(result[0]!.content).toBe('Hello world');
    });

    it('parses multiple paragraphs', () => {
      const result = parseMarkdown('First\n\nSecond');
      expect(result).toHaveLength(2);
      expect(result[0]!.content).toBe('First');
      expect(result[1]!.content).toBe('Second');
    });
  });

  describe('headings', () => {
    it('parses h1', () => {
      const result = parseMarkdown('# Title');
      expect(result[0]!).toEqual({ type: 'heading', level: 1, content: 'Title' });
    });

    it('parses h2', () => {
      const result = parseMarkdown('## Subtitle');
      expect(result[0]!.level).toBe(2);
    });

    it('parses h3', () => {
      const result = parseMarkdown('### Section');
      expect(result[0]!.level).toBe(3);
    });
  });

  describe('code blocks', () => {
    it('parses code block without language', () => {
      const input = '```\nconst x = 1;\n```';
      const result = parseMarkdown(input);
      expect(result[0]!.type).toBe('codeblock');
      expect(result[0]!.content).toBe('const x = 1;');
      expect(result[0]!.language).toBeUndefined();
    });

    it('parses code block with language', () => {
      const input = '```typescript\nconst x: number = 1;\n```';
      const result = parseMarkdown(input);
      expect(result[0]!.language).toBe('typescript');
    });

    it('parses multiline code block', () => {
      const input = '```\nline1\nline2\nline3\n```';
      const result = parseMarkdown(input);
      expect(result[0]!.content).toBe('line1\nline2\nline3');
    });
  });

  describe('lists', () => {
    it('parses unordered list with dash', () => {
      const result = parseMarkdown('- one\n- two');
      expect(result[0]!.type).toBe('list');
      expect(result[0]!.ordered).toBe(false);
      expect(result[0]!.items).toEqual(['one', 'two']);
    });

    it('parses unordered list with asterisk', () => {
      const result = parseMarkdown('* one\n* two');
      expect(result[0]!.ordered).toBe(false);
    });

    it('parses ordered list', () => {
      const result = parseMarkdown('1. first\n2. second');
      expect(result[0]!.ordered).toBe(true);
      expect(result[0]!.items).toEqual(['first', 'second']);
    });
  });

  describe('blockquotes', () => {
    it('parses single line quote', () => {
      const result = parseMarkdown('> Quote text');
      expect(result[0]!.type).toBe('blockquote');
      expect(result[0]!.content).toBe('Quote text');
    });

    it('parses multiline quote', () => {
      const result = parseMarkdown('> Line 1\n> Line 2');
      expect(result[0]!.content).toBe('Line 1\nLine 2');
    });
  });

  describe('horizontal rules', () => {
    it('parses ---', () => {
      const result = parseMarkdown('---');
      expect(result[0]!.type).toBe('hr');
    });

    it('parses ***', () => {
      const result = parseMarkdown('***');
      expect(result[0]!.type).toBe('hr');
    });

    it('parses ___', () => {
      const result = parseMarkdown('___');
      expect(result[0]!.type).toBe('hr');
    });
  });

  describe('mixed content', () => {
    it('parses heading followed by paragraph', () => {
      const result = parseMarkdown('# Title\nSome text');
      expect(result).toHaveLength(2);
      expect(result[0]!.type).toBe('heading');
      expect(result[1]!.type).toBe('paragraph');
    });

    it('parses paragraph before code block', () => {
      const result = parseMarkdown('Text\n```\ncode\n```');
      expect(result).toHaveLength(2);
      expect(result[0]!.type).toBe('paragraph');
      expect(result[1]!.type).toBe('codeblock');
    });
  });
});

describe('tokenize', () => {
  it('returns empty for empty string', () => {
    expect(tokenize('')).toEqual([]);
  });

  it('returns single text token for plain text', () => {
    const tokens = tokenize('Hello');
    expect(tokens).toEqual([{ type: 'text', content: 'Hello' }]);
  });

  it('parses inline code', () => {
    const tokens = tokenize('use `const` here');
    expect(tokens).toHaveLength(3);
    expect(tokens[1]).toEqual({ type: 'code', content: 'const' });
  });

  it('parses bold text', () => {
    const tokens = tokenize('this is **bold** text');
    const bold = tokens.find(t => t.type === 'bold');
    expect(bold?.content).toBe('bold');
  });

  it('parses italic text', () => {
    const tokens = tokenize('this is *italic* text');
    const italic = tokens.find(t => t.type === 'italic');
    expect(italic?.content).toBe('italic');
  });

  it('parses multiple inline elements', () => {
    const tokens = tokenize('`code` and **bold**');
    const code = tokens.find(t => t.type === 'code');
    const bold = tokens.find(t => t.type === 'bold');
    expect(code?.content).toBe('code');
    expect(bold?.content).toBe('bold');
  });
});
