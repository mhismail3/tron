/**
 * @fileoverview StreamingContent Component
 *
 * Displays text content with animated cursor when streaming.
 * Comprehensive markdown rendering with tables, lists, headers, etc.
 */

import { useMemo } from 'react';
import './StreamingContent.css';

// =============================================================================
// Types
// =============================================================================

export interface StreamingContentProps {
  /** The content to display */
  content: string;
  /** Whether content is still streaming */
  isStreaming: boolean;
  /** Additional CSS class */
  className?: string;
}

// =============================================================================
// Markdown Rendering
// =============================================================================

type NodeType =
  | 'text'
  | 'bold'
  | 'italic'
  | 'code'
  | 'codeblock'
  | 'paragraph'
  | 'heading'
  | 'list'
  | 'listitem'
  | 'blockquote'
  | 'table'
  | 'hr'
  | 'link';

interface ParsedNode {
  type: NodeType;
  content: string;
  level?: number; // for headings (1-6) and lists (nesting depth)
  language?: string; // for code blocks
  ordered?: boolean; // for lists
  children?: ParsedNode[];
  href?: string; // for links
  rows?: string[][]; // for tables
  header?: string[]; // for table header
}

/**
 * Comprehensive markdown parser for streaming content
 */
function parseMarkdown(text: string): ParsedNode[] {
  const nodes: ParsedNode[] = [];
  const lines = text.split('\n');
  let i = 0;

  while (i < lines.length) {
    const line = lines[i] ?? '';

    // Code block (fenced)
    if (line.startsWith('```')) {
      const language = line.slice(3).trim();
      const codeLines: string[] = [];
      i++;

      while (i < lines.length) {
        const currentLine = lines[i] ?? '';
        if (currentLine.startsWith('```')) break;
        codeLines.push(currentLine);
        i++;
      }

      nodes.push({
        type: 'codeblock',
        content: codeLines.join('\n'),
        language: language || undefined,
      });

      i++; // skip closing ```
      continue;
    }

    // Horizontal rule
    if (/^(-{3,}|\*{3,}|_{3,})$/.test(line.trim())) {
      nodes.push({ type: 'hr', content: '' });
      i++;
      continue;
    }

    // Heading (# ## ### etc)
    const headingMatch = line.match(/^(#{1,6})\s+(.+)$/);
    if (headingMatch && headingMatch[1] && headingMatch[2]) {
      nodes.push({
        type: 'heading',
        level: headingMatch[1].length,
        content: headingMatch[2],
        children: parseInline(headingMatch[2]),
      });
      i++;
      continue;
    }

    // Blockquote
    if (line.startsWith('>')) {
      const quoteLines: string[] = [];
      while (i < lines.length && (lines[i]?.startsWith('>') || lines[i]?.trim() === '')) {
        const qLine = lines[i] ?? '';
        if (qLine.trim() === '' && quoteLines.length > 0) break;
        quoteLines.push(qLine.replace(/^>\s?/, ''));
        i++;
      }
      nodes.push({
        type: 'blockquote',
        content: quoteLines.join('\n'),
        children: parseMarkdown(quoteLines.join('\n')),
      });
      continue;
    }

    // Table (pipes)
    if (line.includes('|') && line.trim().startsWith('|')) {
      const tableLines: string[] = [];
      while (i < lines.length && lines[i]?.includes('|')) {
        tableLines.push(lines[i] ?? '');
        i++;
      }

      if (tableLines.length >= 2) {
        const parseRow = (row: string) =>
          row
            .split('|')
            .map((cell) => cell.trim())
            .filter((cell, idx, arr) => idx > 0 && idx < arr.length - 1 || cell);

        const header = parseRow(tableLines[0] ?? '');
        // Skip separator row (|---|---|)
        const dataRows = tableLines.slice(2).map(parseRow);

        nodes.push({
          type: 'table',
          content: '',
          header,
          rows: dataRows,
        });
      }
      continue;
    }

    // Unordered list (- or * at start)
    if (/^[\s]*[-*]\s/.test(line)) {
      const listItems: ParsedNode[] = [];
      while (i < lines.length && /^[\s]*[-*]\s/.test(lines[i] ?? '')) {
        const itemLine = lines[i] ?? '';
        const itemContent = itemLine.replace(/^[\s]*[-*]\s/, '');
        listItems.push({
          type: 'listitem',
          content: itemContent,
          children: parseInline(itemContent),
        });
        i++;
      }
      nodes.push({
        type: 'list',
        content: '',
        ordered: false,
        children: listItems,
      });
      continue;
    }

    // Ordered list (1. 2. etc)
    if (/^[\s]*\d+\.\s/.test(line)) {
      const listItems: ParsedNode[] = [];
      while (i < lines.length && /^[\s]*\d+\.\s/.test(lines[i] ?? '')) {
        const itemLine = lines[i] ?? '';
        const itemContent = itemLine.replace(/^[\s]*\d+\.\s/, '');
        listItems.push({
          type: 'listitem',
          content: itemContent,
          children: parseInline(itemContent),
        });
        i++;
      }
      nodes.push({
        type: 'list',
        content: '',
        ordered: true,
        children: listItems,
      });
      continue;
    }

    // Empty line
    if (line.trim() === '') {
      i++;
      continue;
    }

    // Regular paragraph with inline formatting
    nodes.push({
      type: 'paragraph',
      content: line,
      children: parseInline(line),
    });

    i++;
  }

  return nodes;
}

/**
 * Parse inline markdown (bold, italic, code, links)
 */
function parseInline(text: string): ParsedNode[] {
  const nodes: ParsedNode[] = [];
  let remaining = text;

  while (remaining.length > 0) {
    // Link [text](url)
    const linkMatch = remaining.match(/^\[([^\]]+)\]\(([^)]+)\)/);
    if (linkMatch && linkMatch[1] && linkMatch[2]) {
      nodes.push({ type: 'link', content: linkMatch[1], href: linkMatch[2] });
      remaining = remaining.slice(linkMatch[0].length);
      continue;
    }

    // Inline code (backticks)
    const codeMatch = remaining.match(/^`([^`]+)`/);
    if (codeMatch && codeMatch[1]) {
      nodes.push({ type: 'code', content: codeMatch[1] });
      remaining = remaining.slice(codeMatch[0].length);
      continue;
    }

    // Bold (**text** or __text__)
    const boldMatch = remaining.match(/^(\*\*|__)([^*_]+)\1/);
    if (boldMatch && boldMatch[2]) {
      nodes.push({ type: 'bold', content: boldMatch[2] });
      remaining = remaining.slice(boldMatch[0].length);
      continue;
    }

    // Italic (*text* or _text_)
    const italicMatch = remaining.match(/^(\*|_)([^*_]+)\1/);
    if (italicMatch && italicMatch[2]) {
      nodes.push({ type: 'italic', content: italicMatch[2] });
      remaining = remaining.slice(italicMatch[0].length);
      continue;
    }

    // Plain text until next special char
    const textMatch = remaining.match(/^[^`*_\[]+/);
    if (textMatch && textMatch[0]) {
      nodes.push({ type: 'text', content: textMatch[0] });
      remaining = remaining.slice(textMatch[0].length);
      continue;
    }

    // Single special character (not part of pattern)
    nodes.push({ type: 'text', content: remaining[0] ?? '' });
    remaining = remaining.slice(1);
  }

  return nodes;
}

/**
 * Render parsed nodes to React elements
 */
function renderNodes(nodes: ParsedNode[], key = 0): React.ReactNode[] {
  return nodes.map((node, i) => {
    const nodeKey = `${key}-${i}`;

    switch (node.type) {
      case 'codeblock':
        return (
          <pre key={nodeKey} className="md-codeblock">
            {node.language && (
              <span className="md-codeblock-lang">{node.language}</span>
            )}
            <code className={node.language ? `language-${node.language}` : ''}>
              {node.content}
            </code>
          </pre>
        );

      case 'heading': {
        const HeadingTag = `h${node.level}` as keyof JSX.IntrinsicElements;
        return (
          <HeadingTag key={nodeKey} className={`md-heading md-h${node.level}`}>
            {node.children ? renderNodes(node.children, i) : node.content}
          </HeadingTag>
        );
      }

      case 'paragraph':
        return (
          <p key={nodeKey} className="md-paragraph">
            {node.children ? renderNodes(node.children, i) : node.content}
          </p>
        );

      case 'blockquote':
        return (
          <blockquote key={nodeKey} className="md-blockquote">
            {node.children ? renderNodes(node.children, i) : node.content}
          </blockquote>
        );

      case 'list':
        const ListTag = node.ordered ? 'ol' : 'ul';
        return (
          <ListTag key={nodeKey} className={`md-list ${node.ordered ? 'md-list-ordered' : 'md-list-unordered'}`}>
            {node.children?.map((item, j) => (
              <li key={`${nodeKey}-${j}`} className="md-list-item">
                {item.children ? renderNodes(item.children, j) : item.content}
              </li>
            ))}
          </ListTag>
        );

      case 'table':
        return (
          <div key={nodeKey} className="md-table-wrapper">
            <table className="md-table">
              {node.header && node.header.length > 0 && (
                <thead>
                  <tr>
                    {node.header.map((cell, j) => (
                      <th key={`${nodeKey}-h-${j}`}>
                        {renderNodes(parseInline(cell), j)}
                      </th>
                    ))}
                  </tr>
                </thead>
              )}
              <tbody>
                {node.rows?.map((row, j) => (
                  <tr key={`${nodeKey}-r-${j}`}>
                    {row.map((cell, k) => (
                      <td key={`${nodeKey}-r-${j}-c-${k}`}>
                        {renderNodes(parseInline(cell), k)}
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        );

      case 'hr':
        return <hr key={nodeKey} className="md-hr" />;

      case 'link':
        return (
          <a
            key={nodeKey}
            href={node.href}
            className="md-link"
            target="_blank"
            rel="noopener noreferrer"
          >
            {node.content}
          </a>
        );

      case 'bold':
        return (
          <strong key={nodeKey} className="md-bold">
            {node.content}
          </strong>
        );

      case 'italic':
        return (
          <em key={nodeKey} className="md-italic">
            {node.content}
          </em>
        );

      case 'code':
        return (
          <code key={nodeKey} className="md-code">
            {node.content}
          </code>
        );

      case 'text':
      default:
        return <span key={nodeKey}>{node.content}</span>;
    }
  });
}

// =============================================================================
// Component
// =============================================================================

export function StreamingContent({
  content,
  isStreaming,
  className = '',
}: StreamingContentProps) {
  const parsed = useMemo(() => parseMarkdown(content), [content]);

  const contentClasses = [
    'streaming-content',
    isStreaming && 'is-streaming',
    className,
  ]
    .filter(Boolean)
    .join(' ');

  return (
    <div
      className={contentClasses}
      role="status"
      aria-busy={isStreaming}
      aria-live="polite"
    >
      <div className="streaming-text">
        {renderNodes(parsed)}
        {isStreaming && (
          <span
            className="streaming-cursor"
            style={{ animationName: 'cursor-blink' }}
            aria-hidden="true"
          />
        )}
      </div>
    </div>
  );
}
