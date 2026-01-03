/**
 * @fileoverview Markdown Text Renderer
 *
 * Renders markdown content for terminal display using Ink.
 * Supports: headers, bold, italic, code, code blocks, lists, horizontal rules.
 */
import React from 'react';
import { Box, Text } from 'ink';
import { inkColors, icons } from '../theme.js';

// =============================================================================
// Types
// =============================================================================

interface MarkdownTextProps {
  /** Markdown content to render */
  content: string;
  /** Optional base color for text */
  color?: string;
}

interface ParsedLine {
  type: 'header' | 'code-block-start' | 'code-block-end' | 'code-block-content' | 'list-item' | 'hr' | 'paragraph' | 'table-row' | 'table-separator';
  level?: number;      // For headers (1-6)
  content: string;
  language?: string;   // For code blocks
  indent?: number;     // For nested lists
  cells?: string[];    // For table rows
}

// =============================================================================
// Parsing Helpers
// =============================================================================

/**
 * Parse inline formatting (bold, italic, code)
 */
function parseInlineFormatting(text: string, baseColor?: string): React.ReactNode[] {
  const nodes: React.ReactNode[] = [];
  let remaining = text;
  let keyIndex = 0;

  while (remaining.length > 0) {
    // Code (backticks) - must come before bold/italic
    const codeMatch = remaining.match(/^`([^`]+)`/);
    if (codeMatch && codeMatch[0] && codeMatch[1]) {
      nodes.push(
        <Text key={keyIndex++} color={inkColors.mint} backgroundColor="#1a2e23">
          {codeMatch[1]}
        </Text>
      );
      remaining = remaining.slice(codeMatch[0].length);
      continue;
    }

    // Bold (**text** or __text__)
    const boldMatch = remaining.match(/^(\*\*|__)([^*_]+)\1/);
    if (boldMatch && boldMatch[0] && boldMatch[2]) {
      nodes.push(
        <Text key={keyIndex++} bold color={baseColor}>
          {boldMatch[2]}
        </Text>
      );
      remaining = remaining.slice(boldMatch[0].length);
      continue;
    }

    // Italic (*text* or _text_) - single asterisk/underscore
    const italicMatch = remaining.match(/^(\*|_)([^*_]+)\1/);
    if (italicMatch && italicMatch[0] && italicMatch[2]) {
      nodes.push(
        <Text key={keyIndex++} italic color={baseColor}>
          {italicMatch[2]}
        </Text>
      );
      remaining = remaining.slice(italicMatch[0].length);
      continue;
    }

    // Link [text](url) - just show the text part
    const linkMatch = remaining.match(/^\[([^\]]+)\]\([^)]+\)/);
    if (linkMatch && linkMatch[0] && linkMatch[1]) {
      nodes.push(
        <Text key={keyIndex++} color={inkColors.accent} underline>
          {linkMatch[1]}
        </Text>
      );
      remaining = remaining.slice(linkMatch[0].length);
      continue;
    }

    // Plain text - find next special character or end
    const nextSpecial = remaining.search(/[`*_\[]/);
    if (nextSpecial === -1) {
      // No more special characters
      nodes.push(<Text key={keyIndex++} color={baseColor}>{remaining}</Text>);
      break;
    } else if (nextSpecial === 0) {
      // Special character but didn't match patterns - treat as literal
      nodes.push(<Text key={keyIndex++} color={baseColor}>{remaining[0]}</Text>);
      remaining = remaining.slice(1);
    } else {
      // Plain text until next special character
      nodes.push(<Text key={keyIndex++} color={baseColor}>{remaining.slice(0, nextSpecial)}</Text>);
      remaining = remaining.slice(nextSpecial);
    }
  }

  return nodes;
}

/**
 * Parse a single line to determine its type
 */
function parseLine(line: string, inCodeBlock: boolean): ParsedLine {
  // Code block boundaries
  if (line.startsWith('```')) {
    if (inCodeBlock) {
      return { type: 'code-block-end', content: '' };
    }
    const language = line.slice(3).trim();
    return { type: 'code-block-start', content: '', language };
  }

  // Inside code block - preserve as-is
  if (inCodeBlock) {
    return { type: 'code-block-content', content: line };
  }

  // Headers (# to ######)
  const headerMatch = line.match(/^(#{1,6})\s+(.+)$/);
  if (headerMatch && headerMatch[1] && headerMatch[2]) {
    return {
      type: 'header',
      level: headerMatch[1].length,
      content: headerMatch[2],
    };
  }

  // Horizontal rule (---, ***, ___)
  if (/^[-*_]{3,}\s*$/.test(line)) {
    return { type: 'hr', content: '' };
  }

  // List items (-, *, +, or numbered)
  const listMatch = line.match(/^(\s*)[-*+•]\s+(.+)$/);
  if (listMatch && listMatch[1] !== undefined && listMatch[2]) {
    return {
      type: 'list-item',
      content: listMatch[2],
      indent: listMatch[1].length,
    };
  }

  // Numbered list
  const numberedMatch = line.match(/^(\s*)\d+[.)]\s+(.+)$/);
  if (numberedMatch && numberedMatch[1] !== undefined && numberedMatch[2]) {
    return {
      type: 'list-item',
      content: numberedMatch[2],
      indent: numberedMatch[1].length,
    };
  }

  // Table separator row (|---|---|)
  if (/^\|[\s\-:]+\|/.test(line) && /^[\|\s\-:]+$/.test(line)) {
    return { type: 'table-separator', content: line };
  }

  // Table row (| cell | cell |)
  if (/^\|.+\|$/.test(line.trim())) {
    const cells = line.trim().slice(1, -1).split('|').map(c => c.trim());
    return { type: 'table-row', content: line, cells };
  }

  // Regular paragraph
  return { type: 'paragraph', content: line };
}

// =============================================================================
// Component
// =============================================================================

export function MarkdownText({ content, color }: MarkdownTextProps): React.ReactElement {
  const lines = content.split('\n');
  const elements: React.ReactNode[] = [];
  let inCodeBlock = false;
  let codeBlockContent: string[] = [];
  let codeLanguage = '';
  let keyIndex = 0;

  for (const line of lines) {
    const parsed = parseLine(line, inCodeBlock);

    switch (parsed.type) {
      case 'code-block-start':
        inCodeBlock = true;
        codeBlockContent = [];
        codeLanguage = parsed.language || '';
        break;

      case 'code-block-end':
        inCodeBlock = false;
        // Render accumulated code block
        elements.push(
          <Box key={keyIndex++} flexDirection="column" marginY={0}>
            {codeLanguage && (
              <Text color={inkColors.dim}>{`─── ${codeLanguage} ───`}</Text>
            )}
            <Box flexDirection="column" paddingLeft={1}>
              {codeBlockContent.map((codeLine, i) => (
                <Text key={i} color={inkColors.mint}>
                  {codeLine || ' '}
                </Text>
              ))}
            </Box>
            {codeLanguage && (
              <Text color={inkColors.dim}>{'─'.repeat(codeLanguage.length + 8)}</Text>
            )}
          </Box>
        );
        codeBlockContent = [];
        codeLanguage = '';
        break;

      case 'code-block-content':
        codeBlockContent.push(parsed.content);
        break;

      case 'header': {
        const headerColors = [
          inkColors.accent,      // H1
          inkColors.accent,      // H2
          inkColors.highlight,   // H3
          inkColors.highlight,   // H4
          inkColors.value,       // H5
          inkColors.value,       // H6
        ];
        const headerColor = headerColors[(parsed.level || 1) - 1] || inkColors.value;
        elements.push(
          <Box key={keyIndex++} marginTop={parsed.level === 1 ? 1 : 0}>
            <Text color={headerColor} bold>
              {parseInlineFormatting(parsed.content, headerColor)}
            </Text>
          </Box>
        );
        break;
      }

      case 'hr':
        elements.push(
          <Box key={keyIndex++} marginY={0}>
            <Text color={inkColors.dim}>{'─'.repeat(40)}</Text>
          </Box>
        );
        break;

      case 'list-item': {
        const indentLevel = Math.floor((parsed.indent || 0) / 2);
        const indentStr = '  '.repeat(indentLevel);
        elements.push(
          <Box key={keyIndex++} flexDirection="row">
            <Text color={inkColors.accent}>{indentStr}{icons.bullet} </Text>
            <Text color={color}>{parseInlineFormatting(parsed.content, color)}</Text>
          </Box>
        );
        break;
      }

      case 'table-row':
        if (parsed.cells) {
          elements.push(
            <Box key={keyIndex++} flexDirection="row">
              <Text color={inkColors.dim}>│ </Text>
              {parsed.cells.map((cell, i) => (
                <React.Fragment key={i}>
                  <Text color={color}>{parseInlineFormatting(cell, color)}</Text>
                  <Text color={inkColors.dim}> │ </Text>
                </React.Fragment>
              ))}
            </Box>
          );
        }
        break;

      case 'table-separator':
        // Render a simple horizontal line for table separator
        elements.push(
          <Box key={keyIndex++}>
            <Text color={inkColors.dim}>├{'─'.repeat(38)}┤</Text>
          </Box>
        );
        break;

      case 'paragraph':
        if (parsed.content.trim()) {
          elements.push(
            <Text key={keyIndex++} color={color} wrap="wrap">
              {parseInlineFormatting(parsed.content, color)}
            </Text>
          );
        } else {
          // Empty line - add small gap
          elements.push(<Box key={keyIndex++} height={1} />);
        }
        break;
    }
  }

  // Handle unclosed code block
  if (inCodeBlock && codeBlockContent.length > 0) {
    elements.push(
      <Box key={keyIndex++} flexDirection="column" paddingLeft={1}>
        {codeBlockContent.map((codeLine, i) => (
          <Text key={i} color={inkColors.mint}>
            {codeLine || ' '}
          </Text>
        ))}
      </Box>
    );
  }

  return (
    <Box flexDirection="column">
      {elements}
    </Box>
  );
}

export default MarkdownText;
