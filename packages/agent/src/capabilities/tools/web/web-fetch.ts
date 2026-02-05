/**
 * @fileoverview WebFetch Tool
 *
 * Fetches web pages and uses a Haiku subagent to answer questions about the content.
 * Provides 88-98% token savings compared to including raw web content in context.
 */

import type { TronTool, TronToolResult } from '@core/types/index.js';
import { createLogger } from '@infrastructure/logging/index.js';
import { validateUrl } from './url-validator.js';
import { parseHtml } from './html-parser.js';
import { truncateContent } from './content-truncator.js';
import { WebCache } from './cache.js';
import type {
  WebFetchParams,
  WebFetchResult,
  WebFetchToolConfig,
  CachedFetchResult,
} from './types.js';

const logger = createLogger('tool:web-fetch');

const DEFAULT_TIMEOUT = 30000; // 30 seconds
const DEFAULT_USER_AGENT = 'TronAgent/1.0 (+https://github.com/tron-agent)';
const DEFAULT_MAX_RESPONSE_SIZE = 10 * 1024 * 1024; // 10MB
const HAIKU_MODEL = 'claude-haiku-4-5-20251001';
const MAX_SUMMARIZER_TURNS = 3;

/**
 * WebFetch tool for fetching and analyzing web content
 */
export class WebFetchTool implements TronTool<WebFetchParams, WebFetchResult> {
  readonly name = 'WebFetch';
  readonly description = `Fetch a web page and answer a question about its content.

The tool fetches the URL, extracts the main content, and uses a Haiku subagent to answer your question.
This is much more efficient than including raw web content in context.

Parameters:
- **url**: The URL to fetch (required). HTTP is auto-upgraded to HTTPS.
- **prompt**: Your question about the content (required). Be specific for better answers.

Returns:
- Answer to your question based on the page content
- Source metadata (URL, title, fetch time)
- Subagent session ID for debugging

Note: Results are cached for 15 minutes. Same URL + same prompt = instant cached response.`;

  readonly parameters = {
    type: 'object' as const,
    properties: {
      url: {
        type: 'string' as const,
        description: 'The URL to fetch. Must be a valid HTTPS URL (HTTP is auto-upgraded).',
      },
      prompt: {
        type: 'string' as const,
        description: 'Your question or what to extract from the page content.',
      },
      maxContentSize: {
        type: 'number' as const,
        description: 'Maximum content size in bytes before truncation (default: 100KB).',
      },
    },
    required: ['url', 'prompt'] as string[],
  };

  readonly category = 'network' as const;
  readonly label = 'Web Fetch';

  private config: WebFetchToolConfig;
  private cache: WebCache;

  constructor(config: WebFetchToolConfig) {
    this.config = config;
    this.cache = new WebCache(config.cache);
  }

  async execute(args: WebFetchParams): Promise<TronToolResult<WebFetchResult>> {
    // Validate required parameters
    const url = args.url as string | undefined;
    const prompt = args.prompt as string | undefined;

    if (!url || typeof url !== 'string' || url.trim() === '') {
      return {
        content: 'Error: Missing required parameter "url". Please provide the URL to fetch.',
        isError: true,
        details: { error: 'Missing url parameter' } as any,
      };
    }

    if (!prompt || typeof prompt !== 'string' || prompt.trim() === '') {
      return {
        content: 'Error: Missing required parameter "prompt". Please provide a question about the content.',
        isError: true,
        details: { error: 'Missing prompt parameter' } as any,
      };
    }

    // Validate URL
    const urlValidation = validateUrl(url.trim(), this.config.urlValidator);
    if (!urlValidation.valid) {
      logger.debug('URL validation failed', {
        url: url.trim(),
        error: urlValidation.error?.code,
        message: urlValidation.error?.message,
      });
      return {
        content: `Error: Invalid URL - ${urlValidation.error?.message}`,
        isError: true,
        details: { error: urlValidation.error } as any,
      };
    }

    const normalizedUrl = urlValidation.url!;
    const trimmedPrompt = prompt.trim();

    logger.info('WebFetch starting', { url: normalizedUrl, promptLength: trimmedPrompt.length });
    logger.debug('URL validation passed', {
      originalUrl: url.trim(),
      normalizedUrl,
      wasUpgraded: url.trim() !== normalizedUrl,
    });

    // Check cache
    const cached = this.cache.get(normalizedUrl, trimmedPrompt);
    if (cached) {
      logger.debug('Cache hit', { url: normalizedUrl });
      return {
        content: cached.answer,
        isError: false,
        details: {
          answer: cached.answer,
          source: cached.source,
          subagentSessionId: cached.subagentSessionId,
          fromCache: true,
        },
      };
    }

    // Fetch the page
    const fetchStartTime = Date.now();
    const fetchResult = await this.fetchPage(normalizedUrl);
    const fetchDuration = Date.now() - fetchStartTime;

    if (fetchResult.error) {
      logger.warn('Fetch failed', {
        url: normalizedUrl,
        error: fetchResult.error,
        durationMs: fetchDuration,
      });
      return {
        content: `Error fetching URL: ${fetchResult.error}`,
        isError: true,
        details: { error: fetchResult.error } as any,
      };
    }

    logger.debug('Fetch completed', {
      url: normalizedUrl,
      durationMs: fetchDuration,
      contentLength: fetchResult.html?.length ?? 0,
      status: fetchResult.status,
      contentType: fetchResult.contentType,
    });

    // Parse HTML to Markdown
    const parseResult = parseHtml(fetchResult.html!, normalizedUrl);
    if (!parseResult.markdown) {
      return {
        content: 'Error: Could not extract content from the page. The page may be empty or use client-side rendering.',
        isError: true,
        details: { error: 'No content extracted', title: parseResult.title } as any,
      };
    }

    logger.debug('Content parsed', {
      url: normalizedUrl,
      title: parseResult.title,
      originalLength: parseResult.originalLength,
      parsedLength: parseResult.parsedLength,
    });

    // Truncate content for summarization
    const truncateResult = truncateContent(parseResult.markdown, this.config.truncator);

    logger.debug('Content truncation', {
      url: normalizedUrl,
      originalLength: parseResult.markdown.length,
      truncatedLength: truncateResult.content.length,
      wasTruncated: truncateResult.truncated,
      originalTokens: truncateResult.originalTokens,
      finalTokens: truncateResult.finalTokens,
      linesPreserved: truncateResult.linesPreserved,
    });

    // Build task for Haiku subagent
    const task = `Answer this question about the following web page content.

**Question**: ${trimmedPrompt}

**Page Title**: ${parseResult.title || 'Unknown'}

**Content**:
${truncateResult.content}

Instructions:
- Answer the question concisely based on the content provided
- If the content doesn't contain the answer, say so clearly
- Do not make up information not present in the content`;

    // Spawn Haiku subagent
    logger.debug('Spawning Haiku subagent for summarization', {
      url: normalizedUrl,
      model: HAIKU_MODEL,
      taskLength: task.length,
      maxTurns: MAX_SUMMARIZER_TURNS,
    });

    const subagentStartTime = Date.now();
    const spawnResult = await this.config.onSpawnSubagent({
      task,
      model: HAIKU_MODEL,
      timeout: this.config.http?.timeout ?? DEFAULT_TIMEOUT,
      maxTurns: MAX_SUMMARIZER_TURNS,
    });
    const subagentDuration = Date.now() - subagentStartTime;

    if (!spawnResult.success) {
      logger.error('Subagent summarization failed', {
        url: normalizedUrl,
        error: spawnResult.error,
        sessionId: spawnResult.sessionId,
        durationMs: subagentDuration,
      });
      return {
        content: `Error: Failed to analyze page content - ${spawnResult.error}`,
        isError: true,
        details: {
          error: spawnResult.error,
          subagentSessionId: spawnResult.sessionId,
        } as any,
      };
    }

    const answer = spawnResult.output || 'No answer generated';
    const fetchedAt = new Date().toISOString();

    // Cache the result
    const cacheEntry: CachedFetchResult = {
      answer,
      source: {
        url: normalizedUrl,
        title: parseResult.title || 'Unknown',
        fetchedAt,
      },
      subagentSessionId: spawnResult.sessionId,
      cachedAt: Date.now(),
      expiresAt: Date.now() + (this.config.cache?.ttl ?? 15 * 60 * 1000),
    };
    this.cache.set(normalizedUrl, trimmedPrompt, cacheEntry);

    logger.info('WebFetch completed', {
      url: normalizedUrl,
      title: parseResult.title,
      answerLength: answer.length,
      totalDurationMs: Date.now() - fetchStartTime,
      subagentDurationMs: subagentDuration,
      tokenUsage: spawnResult.tokenUsage,
      sessionId: spawnResult.sessionId,
    });

    return {
      content: answer,
      isError: false,
      details: {
        answer,
        source: cacheEntry.source,
        subagentSessionId: spawnResult.sessionId,
        fromCache: false,
        tokenUsage: spawnResult.tokenUsage,
      },
    };
  }

  /**
   * Fetch a web page
   */
  private async fetchPage(url: string): Promise<{
    html?: string;
    error?: string;
    status?: number;
    contentType?: string;
  }> {
    const timeout = this.config.http?.timeout ?? DEFAULT_TIMEOUT;
    const userAgent = this.config.http?.userAgent ?? DEFAULT_USER_AGENT;
    const maxSize = this.config.http?.maxResponseSize ?? DEFAULT_MAX_RESPONSE_SIZE;

    try {
      logger.trace('HTTP request starting', { url, timeout, userAgent: userAgent.split('/')[0] });

      const response = await fetch(url, {
        method: 'GET',
        headers: {
          'User-Agent': userAgent,
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'en-US,en;q=0.5',
        },
        redirect: 'follow',
        signal: AbortSignal.timeout(timeout),
      });

      const status = response.status;
      const contentType = response.headers.get('content-type') || '';

      logger.trace('HTTP response received', {
        url,
        status,
        contentType,
        headers: Object.fromEntries(response.headers.entries()),
      });

      if (!response.ok) {
        return { error: `HTTP ${status}: ${response.statusText}`, status, contentType };
      }

      // Check content type
      if (!contentType.includes('text/html') && !contentType.includes('application/xhtml')) {
        return { error: `Unsupported content type: ${contentType}`, status, contentType };
      }

      // Read response with size limit
      const text = await response.text();
      const wasTruncated = text.length > maxSize;

      if (wasTruncated) {
        logger.debug('Response truncated due to size limit', {
          url,
          originalSize: text.length,
          maxSize,
        });
        return { html: text.slice(0, maxSize), status, contentType };
      }

      return { html: text, status, contentType };
    } catch (error) {
      const err = error as Error;
      logger.debug('HTTP request error', { url, errorName: err.name, errorMessage: err.message });

      if (err.name === 'TimeoutError' || err.message.includes('timeout')) {
        return { error: `Request timed out after ${timeout}ms` };
      }
      return { error: err.message };
    }
  }

  /**
   * Get cache statistics
   */
  getCacheStats() {
    return this.cache.getStats();
  }

  /**
   * Clear the cache
   */
  clearCache() {
    this.cache.clear();
  }
}
