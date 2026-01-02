/**
 * @fileoverview Markdown Parser for TUI
 *
 * Simple, focused markdown parser for terminal rendering.
 * Parses block elements (headers, code, lists) and inline formatting.
 */

// =============================================================================
// Types
// =============================================================================

export type NodeType = 'paragraph' | 'heading' | 'codeblock' | 'list' | 'blockquote' | 'hr';

export type TokenType = 'text' | 'code' | 'bold' | 'italic';

export interface Token {
  type: TokenType;
  content: string;
}

export interface Node {
  type: NodeType;
  content?: string;
  level?: number;
  language?: string;
  ordered?: boolean;
  items?: string[];
  tokens?: Token[];
}

// =============================================================================
// Main Parser
// =============================================================================

export function parseMarkdown(input: string): Node[] {
  const trimmed = input.trim();
  if (!trimmed) return [];

  const nodes: Node[] = [];
  const lines = trimmed.split('\n');
  let i = 0;

  while (i < lines.length) {
    const line = lines[i] ?? '';

    // Empty line - skip
    if (!line.trim()) {
      i++;
      continue;
    }

    // Fenced code block
    if (line.startsWith('```')) {
      const lang = line.slice(3).trim() || undefined;
      const codeLines: string[] = [];
      i++;
      while (i < lines.length && !(lines[i] ?? '').startsWith('```')) {
        codeLines.push(lines[i] ?? '');
        i++;
      }
      nodes.push({ type: 'codeblock', content: codeLines.join('\n'), language: lang });
      i++; // skip closing ```
      continue;
    }

    // Header
    const headerMatch = line.match(/^(#{1,6})\s+(.+)$/);
    if (headerMatch) {
      nodes.push({
        type: 'heading',
        level: (headerMatch[1] ?? '').length,
        content: (headerMatch[2] ?? '').trim(),
      });
      i++;
      continue;
    }

    // Horizontal rule
    if (/^[-*_]{3,}$/.test(line.trim())) {
      nodes.push({ type: 'hr' });
      i++;
      continue;
    }

    // Blockquote
    if (line.startsWith('> ')) {
      const quoteLines: string[] = [];
      while (i < lines.length && (lines[i] ?? '').startsWith('> ')) {
        quoteLines.push((lines[i] ?? '').slice(2));
        i++;
      }
      nodes.push({ type: 'blockquote', content: quoteLines.join('\n') });
      continue;
    }

    // Unordered list
    if (/^[-*]\s+/.test(line)) {
      const items: string[] = [];
      while (i < lines.length && /^[-*]\s+/.test(lines[i] ?? '')) {
        items.push((lines[i] ?? '').replace(/^[-*]\s+/, ''));
        i++;
      }
      nodes.push({ type: 'list', ordered: false, items });
      continue;
    }

    // Ordered list
    if (/^\d+\.\s+/.test(line)) {
      const items: string[] = [];
      while (i < lines.length && /^\d+\.\s+/.test(lines[i] ?? '')) {
        items.push((lines[i] ?? '').replace(/^\d+\.\s+/, ''));
        i++;
      }
      nodes.push({ type: 'list', ordered: true, items });
      continue;
    }

    // Paragraph - collect until empty line or block element
    const paraLines: string[] = [];
    while (i < lines.length) {
      const l = lines[i] ?? '';
      if (!l.trim() || l.startsWith('#') || l.startsWith('```') ||
          l.startsWith('> ') || /^[-*]\s+/.test(l) || /^\d+\.\s+/.test(l) ||
          /^[-*_]{3,}$/.test(l.trim())) {
        break;
      }
      paraLines.push(l);
      i++;
    }
    if (paraLines.length > 0) {
      const content = paraLines.join(' ').trim();
      nodes.push({ type: 'paragraph', content, tokens: tokenize(content) });
    }
  }

  return nodes;
}

// =============================================================================
// Inline Tokenizer
// =============================================================================

export function tokenize(text: string): Token[] {
  if (!text) return [];

  const tokens: Token[] = [];
  let pos = 0;

  while (pos < text.length) {
    const char = text[pos] ?? '';
    const nextChar = text[pos + 1] ?? '';

    // Inline code: `code`
    if (char === '`') {
      const end = text.indexOf('`', pos + 1);
      if (end !== -1) {
        tokens.push({ type: 'code', content: text.slice(pos + 1, end) });
        pos = end + 1;
        continue;
      }
    }

    // Bold: **text**
    if (char === '*' && nextChar === '*') {
      const end = text.indexOf('**', pos + 2);
      if (end !== -1) {
        tokens.push({ type: 'bold', content: text.slice(pos + 2, end) });
        pos = end + 2;
        continue;
      }
    }

    // Italic: *text* (but not **)
    if (char === '*' && nextChar !== '*') {
      const end = text.indexOf('*', pos + 1);
      if (end !== -1 && (text[end - 1] ?? '') !== '*') {
        tokens.push({ type: 'italic', content: text.slice(pos + 1, end) });
        pos = end + 1;
        continue;
      }
    }

    // Regular text until next special char
    let nextSpecial = pos + 1;
    while (nextSpecial < text.length && !'`*'.includes(text[nextSpecial] ?? ' ')) {
      nextSpecial++;
    }
    tokens.push({ type: 'text', content: text.slice(pos, nextSpecial) });
    pos = nextSpecial;
  }

  return tokens;
}

// Legacy exports for compatibility
export type MarkdownNode = Node;
export type MarkdownToken = Token;
