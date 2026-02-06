/**
 * @fileoverview HTML Parser
 *
 * Converts HTML content to clean Markdown using Mozilla Readability
 * and Turndown for article extraction and conversion.
 */

import { Readability } from '@mozilla/readability';
import TurndownService from 'turndown';
import { parseHTML } from 'linkedom';
import type { HtmlParseResult, HtmlParserConfig } from './types.js';

type LinkedomDocument = ReturnType<typeof parseHTML>['document'];

const DEFAULT_MAX_CONTENT_LENGTH = 500000; // 500KB

/**
 * Parse HTML content and convert to clean Markdown
 *
 * @param html - Raw HTML string
 * @param url - Original URL (used for resolving relative links)
 * @param config - Optional parser configuration
 * @returns Parsed result with markdown content and metadata
 */
export function parseHtml(
  html: string,
  url: string,
  config: HtmlParserConfig = {}
): HtmlParseResult {
  const { maxContentLength = DEFAULT_MAX_CONTENT_LENGTH } = config;

  // Handle empty input
  const trimmedHtml = html?.trim() ?? '';
  if (!trimmedHtml) {
    return {
      markdown: '',
      title: '',
      description: undefined,
      originalLength: 0,
      parsedLength: 0,
    };
  }

  const originalLength = trimmedHtml.length;

  // Truncate if too large
  const processedHtml =
    trimmedHtml.length > maxContentLength
      ? trimmedHtml.slice(0, maxContentLength)
      : trimmedHtml;

  // Parse HTML with linkedom (inject <base> tag for URL resolution)
  const htmlWithBase = `<head><base href="${url}"></head>${processedHtml}`;
  const { document } = parseHTML(htmlWithBase);

  // Extract metadata before Readability modifies the DOM
  const title = extractTitle(document);
  const description = extractDescription(document);

  // Use Readability to extract main content, fall back to raw HTML for fragments
  const reader = new Readability(document as any, {
    charThreshold: 0, // Allow short content
  });
  const article = reader.parse();

  const turndown = createTurndownService();
  const articleHtml = article?.content || processedHtml;
  const markdown = turndown.turndown(articleHtml).trim();

  if (!markdown) {
    return {
      markdown: '',
      title,
      description,
      originalLength,
      parsedLength: 0,
    };
  }

  return {
    markdown,
    title: article?.title || title,
    description: article?.excerpt || description,
    originalLength,
    parsedLength: markdown.length,
  };
}

/**
 * Extract title from document
 */
function extractTitle(document: LinkedomDocument): string {
  // Try <title> tag first
  const titleElement = document.querySelector('title');
  if (titleElement?.textContent) {
    return titleElement.textContent.trim();
  }

  // Try og:title
  const ogTitle = document.querySelector('meta[property="og:title"]');
  if (ogTitle?.getAttribute('content')) {
    return ogTitle.getAttribute('content')!.trim();
  }

  // Try h1
  const h1 = document.querySelector('h1');
  if (h1?.textContent) {
    return h1.textContent.trim();
  }

  return '';
}

/**
 * Extract description from document
 */
function extractDescription(document: LinkedomDocument): string | undefined {
  // Try meta description
  const metaDesc = document.querySelector('meta[name="description"]');
  if (metaDesc?.getAttribute('content')) {
    return metaDesc.getAttribute('content')!.trim();
  }

  // Try og:description
  const ogDesc = document.querySelector('meta[property="og:description"]');
  if (ogDesc?.getAttribute('content')) {
    return ogDesc.getAttribute('content')!.trim();
  }

  return undefined;
}

/**
 * Create and configure Turndown service for Markdown conversion
 */
function createTurndownService(): TurndownService {
  const turndown = new TurndownService({
    headingStyle: 'atx', // Use # style headings
    codeBlockStyle: 'fenced', // Use ``` for code blocks
    bulletListMarker: '-', // Use - for unordered lists
    emDelimiter: '*', // Use * for italic
    strongDelimiter: '**', // Use ** for bold
    linkStyle: 'inlined', // Use [text](url) style links
  });

  // Custom rule for code blocks with language detection
  turndown.addRule('fencedCodeBlock', {
    filter: (node, _options) => {
      return (
        node.nodeName === 'PRE' &&
        node.firstChild?.nodeName === 'CODE'
      );
    },
    replacement: (content, node, _options) => {
      const codeNode = (node as any).querySelector('code');
      if (!codeNode) return content;

      // Try to detect language from class
      const classList = codeNode.className;
      const langMatch = classList.match(/language-(\w+)/);
      const lang = langMatch ? langMatch[1] : '';

      const code = codeNode.textContent || '';
      return `\n\n\`\`\`${lang}\n${code}\n\`\`\`\n\n`;
    },
  });

  // Remove script and style content (shouldn't be there after Readability, but just in case)
  turndown.remove(['script', 'style', 'noscript']);

  return turndown;
}

/**
 * HTML Parser class for reusable parsing with configuration
 */
export class HtmlParser {
  private config: HtmlParserConfig;

  constructor(config: HtmlParserConfig = {}) {
    this.config = config;
  }

  /**
   * Parse HTML and return Markdown
   */
  parse(html: string, url: string): HtmlParseResult {
    return parseHtml(html, url, this.config);
  }

  /**
   * Update configuration
   */
  updateConfig(config: Partial<HtmlParserConfig>): void {
    this.config = { ...this.config, ...config };
  }

  /**
   * Get current configuration
   */
  getConfig(): HtmlParserConfig {
    return { ...this.config };
  }
}
