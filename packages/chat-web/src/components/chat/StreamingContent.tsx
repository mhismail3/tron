/**
 * @fileoverview StreamingContent Component
 *
 * Displays text content with animated cursor when streaming.
 * Supports basic markdown rendering.
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

interface ParsedNode {
  type: 'text' | 'bold' | 'italic' | 'code' | 'codeblock' | 'paragraph';
  content: string;
  language?: string;
  children?: ParsedNode[];
}

/**
 * Simple markdown parser for streaming content
 */
function parseMarkdown(text: string): ParsedNode[] {
  const nodes: ParsedNode[] = [];
  const lines = text.split('\n');
  let i = 0;

  while (i < lines.length) {
    const line = lines[i] ?? '';

    // Code block
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

    // Regular paragraph with inline formatting
    if (line.trim()) {
      nodes.push({
        type: 'paragraph',
        content: line,
        children: parseInline(line),
      });
    }

    i++;
  }

  return nodes;
}

/**
 * Parse inline markdown (bold, italic, code)
 */
function parseInline(text: string): ParsedNode[] {
  const nodes: ParsedNode[] = [];
  let remaining = text;

  while (remaining.length > 0) {
    // Inline code (backticks)
    const codeMatch = remaining.match(/^`([^`]+)`/);
    if (codeMatch && codeMatch[1]) {
      nodes.push({ type: 'code', content: codeMatch[1] });
      remaining = remaining.slice(codeMatch[0].length);
      continue;
    }

    // Bold (**text**)
    const boldMatch = remaining.match(/^\*\*([^*]+)\*\*/);
    if (boldMatch && boldMatch[1]) {
      nodes.push({ type: 'bold', content: boldMatch[1] });
      remaining = remaining.slice(boldMatch[0].length);
      continue;
    }

    // Italic (*text*)
    const italicMatch = remaining.match(/^\*([^*]+)\*/);
    if (italicMatch && italicMatch[1]) {
      nodes.push({ type: 'italic', content: italicMatch[1] });
      remaining = remaining.slice(italicMatch[0].length);
      continue;
    }

    // Plain text until next special char
    const textMatch = remaining.match(/^[^`*]+/);
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
          <pre key={nodeKey} className="code-block">
            <code className={node.language ? `language-${node.language}` : ''}>
              {node.content}
            </code>
          </pre>
        );

      case 'paragraph':
        return (
          <p key={nodeKey} className="markdown-paragraph">
            {node.children ? renderNodes(node.children, i) : node.content}
          </p>
        );

      case 'bold':
        return <strong key={nodeKey}>{node.content}</strong>;

      case 'italic':
        return <em key={nodeKey}>{node.content}</em>;

      case 'code':
        return (
          <code key={nodeKey} className="inline-code">
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
