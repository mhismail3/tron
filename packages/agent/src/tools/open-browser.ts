/**
 * @fileoverview OpenBrowser tool for opening URLs in native Safari
 *
 * This tool triggers the iOS app to open a URL in SFSafariViewController.
 * It's a fire-and-forget operation - returns immediately after validating the URL.
 */

import type { TronTool, TronToolResult } from '../types/index.js';
import { createLogger } from '../logging/logger.js';

const logger = createLogger('tool:open-browser');

export interface OpenBrowserConfig {
  workingDirectory?: string;
}

export class OpenBrowserTool implements TronTool {
  readonly name = 'OpenBrowser';
  readonly description = `Open a URL in the native iOS Safari browser for the user to view.

Use this tool when you want to:
- Show the user a webpage, documentation, or article
- Direct the user to a website for reference
- Open external links for the user to explore

The URL opens in Safari within the app. The user can browse, interact with the page,
and dismiss it when done. This is a fire-and-forget action - you don't need to wait
for the user to close the browser.

Examples:
- Open documentation: { "url": "https://docs.swift.org/swift-book/" }
- Show a reference: { "url": "https://developer.apple.com/documentation/swiftui" }`;

  readonly parameters = {
    type: 'object' as const,
    properties: {
      url: {
        type: 'string' as const,
        description: 'The URL to open (must be http:// or https://)',
      },
    },
    required: ['url'] as string[],
  };

  readonly label = 'Open Browser';
  readonly category = 'custom' as const;

  constructor(_config: OpenBrowserConfig = {}) {
    // Config accepted for API compatibility
  }

  async execute(args: Record<string, unknown>): Promise<TronToolResult> {
    const url = args.url as string | undefined;

    if (!url || typeof url !== 'string') {
      return {
        content: 'Missing required parameter: url',
        isError: true,
        details: { url },
      };
    }

    const trimmedUrl = url.trim();

    // Validate URL format
    const urlValidation = this.validateUrl(trimmedUrl);
    if (!urlValidation.valid) {
      return {
        content: urlValidation.error!,
        isError: true,
        details: { url: trimmedUrl },
      };
    }

    logger.info('Opening URL in Safari', { url: trimmedUrl });

    // Return immediately - iOS app will receive this via tool_execution_start event
    // and open Safari based on the tool name and arguments
    return {
      content: `Opening ${trimmedUrl} in Safari`,
      isError: false,
      details: {
        url: trimmedUrl,
        action: 'open_safari',
      },
    };
  }

  private validateUrl(url: string): { valid: boolean; error?: string } {
    // Check if URL is empty
    if (!url) {
      return { valid: false, error: 'URL cannot be empty' };
    }

    // Parse URL
    let parsed: URL;
    try {
      parsed = new URL(url);
    } catch {
      return {
        valid: false,
        error: `Invalid URL format: "${url}". Please provide a valid URL like "https://example.com"`,
      };
    }

    // Only allow http and https
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
      return {
        valid: false,
        error: `Invalid URL scheme: "${parsed.protocol}". Only http:// and https:// URLs are allowed`,
      };
    }

    return { valid: true };
  }
}
