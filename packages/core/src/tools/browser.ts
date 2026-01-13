/**
 * @fileoverview Browser automation tool using Playwright
 */

import type { TronTool, TronToolResult, ToolResultContentType } from '../types/index.js';

export interface BrowserToolConfig {
  workingDirectory?: string;
  delegate?: BrowserDelegate;
}

/**
 * Delegate interface for BrowserTool to interact with BrowserService
 */
export interface BrowserDelegate {
  execute(
    sessionId: string,
    action: string,
    params: Record<string, unknown>
  ): Promise<{
    success: boolean;
    data?: Record<string, unknown>;
    error?: string;
  }>;
  ensureSession(sessionId: string): Promise<void>;
  hasSession(sessionId: string): boolean;
}

interface BrowserSession {
  sessionId: string;
  elementRefs: Map<string, string>;
  lastSnapshot?: any;
}

/**
 * Browser automation tool for controlling browsers via Playwright
 */
export class BrowserTool implements TronTool {
  readonly name = 'browser';
  readonly description = `Control a web browser with automation capabilities.

CRITICAL: Execute actions ONE AT A TIME sequentially - do not call multiple browser tools in parallel.

Actions: navigate, snapshot, screenshot, click, fill, type, select, wait, scroll, close

Reference @browser skill for detailed usage, examples, and workflow.`;

  readonly parameters = {
    type: 'object' as const,
    properties: {
      action: {
        type: 'string' as const,
        description: 'The browser action to perform (navigate, click, fill, type, select, screenshot, snapshot, wait, scroll, close)',
      },
      url: {
        type: 'string' as const,
        description: 'URL for navigate action',
      },
      selector: {
        type: 'string' as const,
        description: 'CSS selector or element reference (e.g., "e1") for click, fill, type, select actions',
      },
      value: {
        type: 'string' as const,
        description: 'Value for fill or select actions',
      },
      text: {
        type: 'string' as const,
        description: 'Text for type action',
      },
      direction: {
        type: 'string' as const,
        description: 'Scroll direction: up, down, left, right',
      },
      amount: {
        type: 'number' as const,
        description: 'Scroll amount in pixels',
      },
      timeout: {
        type: 'number' as const,
        description: 'Timeout in milliseconds for wait action',
      },
    },
    required: ['action'],
  };

  private delegate?: BrowserDelegate;
  private session?: BrowserSession;

  constructor(config: BrowserToolConfig = {}) {
    this.delegate = config.delegate;
  }

  async execute(params: Record<string, unknown>): Promise<TronToolResult> {
    if (!this.delegate) {
      return {
        content: [
          {
            type: 'text',
            text: 'Browser tool is not available (no delegate configured)',
          },
        ],
      };
    }

    const action = params.action as string;
    if (!action) {
      return {
        content: [
          {
            type: 'text',
            text: 'Error: "action" parameter is required',
          },
        ],
      };
    }

    try {
      // Ensure session exists (creates if needed)
      await this.ensureSession();

      // Convert selectors if needed
      const processedParams = this.processParams(params);

      // Execute the action via delegate
      const result = await this.delegate.execute(
        this.session!.sessionId,
        action,
        processedParams
      );

      if (!result.success) {
        return {
          content: [
            {
              type: 'text',
              text: `Browser action failed: ${result.error ?? 'Unknown error'}`,
            },
          ],
        };
      }

      // Format the response
      // Include full data in details for clients (e.g., iOS) that need raw binary data
      // The text content is kept concise for Claude's context window
      const formattedContent = this.formatResult(action, result.data ?? {});
      const toolResult: TronToolResult = { content: formattedContent };

      // For screenshot action, include full base64 in details for client access
      if (action === 'screenshot' && result.data?.screenshot) {
        toolResult.details = {
          screenshot: result.data.screenshot,
          format: result.data.format ?? 'png',
        };
      }

      return toolResult;
    } catch (error) {
      return {
        content: [
          {
            type: 'text',
            text: `Browser error: ${error instanceof Error ? error.message : 'Unknown error'}`,
          },
        ],
      };
    }
  }

  /**
   * Ensure browser session exists
   */
  private async ensureSession(): Promise<void> {
    if (!this.session) {
      const sessionId = `browser-${Date.now()}`;
      this.session = {
        sessionId,
        elementRefs: new Map(),
      };
    }

    // Create session via delegate if it doesn't exist
    if (!this.delegate!.hasSession(this.session.sessionId)) {
      await this.delegate!.ensureSession(this.session.sessionId);
    }
  }

  /**
   * Process parameters, converting selectors if needed
   */
  private processParams(params: Record<string, unknown>): Record<string, unknown> {
    const processed = { ...params };

    // Convert selector if present
    if (processed.selector && typeof processed.selector === 'string') {
      processed.selector = this.resolveSelector(processed.selector as string);
    }

    return processed;
  }

  /**
   * Convert jQuery-style selectors to Playwright equivalents
   * Also resolves element references (e1, e2, etc.) from snapshots
   */
  private resolveSelector(selector: string): string {
    if (!selector) return '';

    // Check if it's an element reference (e1, e2, etc.)
    if (/^e\d+$/.test(selector) && this.session?.elementRefs.has(selector)) {
      return this.session.elementRefs.get(selector)!;
    }

    // Convert jQuery-style :contains() to Playwright :has-text()
    let converted = selector.replace(/:contains\(["']([^"']+)["']\)/g, ':has-text("$1")');
    converted = converted.replace(/:contains\(([^)]+)\)/g, ':has-text("$1")');

    return converted;
  }

  /**
   * Format the result for display
   */
  private formatResult(action: string, data: Record<string, unknown>): ToolResultContentType[] {
    switch (action) {
      case 'navigate':
        return [
          {
            type: 'text',
            text: `Navigated to: ${data.url}`,
          },
        ];

      case 'click':
        return [
          {
            type: 'text',
            text: `Clicked: ${data.selector}`,
          },
        ];

      case 'fill':
        return [
          {
            type: 'text',
            text: `Filled ${data.selector} with: ${data.value}`,
          },
        ];

      case 'type':
        return [
          {
            type: 'text',
            text: `Typed into ${data.selector}: ${data.text}`,
          },
        ];

      case 'select':
        return [
          {
            type: 'text',
            text: `Selected ${data.selector}: ${data.value}`,
          },
        ];

      case 'screenshot':
        return [
          {
            type: 'text',
            text: `Screenshot captured (base64): ${(data.screenshot as string).substring(0, 50)}...`,
          },
        ];

      case 'snapshot': {
        const snapshot = data.snapshot as any;
        const elementRefs = data.elementRefs as Array<{ ref: string; selector: string }>;

        // Store element refs in session for future use
        if (this.session && elementRefs) {
          this.session.elementRefs.clear();
          elementRefs.forEach(({ ref, selector }) => {
            this.session!.elementRefs.set(ref, selector);
          });
          this.session.lastSnapshot = snapshot;
        }

        return [
          {
            type: 'text',
            text: `Snapshot captured with ${elementRefs?.length ?? 0} element references\n${JSON.stringify(snapshot, null, 2)}`,
          },
        ];
      }

      case 'wait':
        return [
          {
            type: 'text',
            text: data.selector ? `Waited for: ${data.selector}` : `Waited: ${data.timeout}ms`,
          },
        ];

      case 'scroll':
        return [
          {
            type: 'text',
            text: `Scrolled ${data.direction}: ${data.amount}px`,
          },
        ];

      case 'close':
        if (this.session) {
          this.session = undefined;
        }
        return [
          {
            type: 'text',
            text: 'Browser session closed',
          },
        ];

      default:
        return [
          {
            type: 'text',
            text: JSON.stringify(data, null, 2),
          },
        ];
    }
  }
}
