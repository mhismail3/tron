/**
 * @fileoverview AgentWebBrowser tool using agent-browser library
 */

import type { TronTool, TronToolResult, ToolResultContentType } from '../../types/index.js';

export interface AgentWebBrowserToolConfig {
  workingDirectory?: string;
  delegate?: BrowserDelegate;
  /** Tron session ID - used to key browser sessions so iOS can control them */
  sessionId?: string;
}

/**
 * Delegate interface for AgentWebBrowserTool to interact with BrowserService
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
 * Browser automation tool using agent-browser library
 *
 * NOTE: The description is intentionally verbose to ensure total tool + system
 * tokens exceed ~4096 for Anthropic prompt caching. Opus 4.5 requires this
 * minimum threshold. Shortening descriptions may break caching.
 * See anthropic.ts for caching implementation details.
 */
export class AgentWebBrowserTool implements TronTool {
  readonly name = 'AgentWebBrowser';
  readonly description = `Control a web browser with automation capabilities using agent-browser.

IMPORTANT: Execute browser actions ONE AT A TIME sequentially - wait for each action to complete before starting the next. Do NOT call multiple browser tools in parallel as this causes race conditions.

Recommended workflow:
1. navigate to URL → wait for result
2. snapshot to get page structure → wait for result
3. screenshot to see visual state → wait for result
4. interact (click/fill/etc.) → wait for result
5. repeat as needed

Actions:
- navigate: Go to a URL (wait for page to load before other actions)
  Required: url (string)
  Example: { "action": "navigate", "url": "https://example.com" }

- snapshot: Get accessibility tree with element references
  IMPORTANT: Call this AFTER navigate completes. Returns element references (e1, e2, etc.)
  Example: { "action": "snapshot" }

- screenshot: Capture visual screenshot of current viewport (1280x800)
  Example: { "action": "screenshot" }

- click: Click an element
  Required: selector (string) - CSS selector or element reference (e.g., "e1")
  Example: { "action": "click", "selector": "button.submit" }

- fill: Fill an input field (clears first, then fills)
  Required: selector (string), value (string)
  Example: { "action": "fill", "selector": "#email", "value": "test@example.com" }

- type: Type text character by character (triggers JS events)
  Required: selector (string), text (string)
  Example: { "action": "type", "selector": "#search", "text": "query" }

- select: Select dropdown option(s)
  Required: selector (string), value (string or string[])
  Example: { "action": "select", "selector": "#country", "value": "US" }

- wait: Wait for element or timeout
  Optional: selector (string), timeout (number in ms)
  Example: { "action": "wait", "selector": ".loading", "timeout": 5000 }

- scroll: Scroll page or element
  Required: direction ("up" | "down" | "left" | "right")
  Optional: amount (number in pixels), selector (string)
  Example: { "action": "scroll", "direction": "down", "amount": 500 }

- goBack: Navigate back in browser history
  Example: { "action": "goBack" }

- goForward: Navigate forward in browser history
  Example: { "action": "goForward" }

- reload: Reload the current page
  Example: { "action": "reload" }

- hover: Hover over an element (triggers hover states/tooltips)
  Required: selector (string)
  Example: { "action": "hover", "selector": "button.menu" }

- pressKey: Press a keyboard key
  Required: key (string) - key name (e.g., "Enter", "Tab", "Escape", "ArrowDown")
  Example: { "action": "pressKey", "key": "Enter" }

- getText: Get text content from an element
  Required: selector (string)
  Example: { "action": "getText", "selector": ".article-content" }

- getAttribute: Get an attribute value from an element
  Required: selector (string), attribute (string)
  Example: { "action": "getAttribute", "selector": "a.link", "attribute": "href" }

- pdf: Generate a PDF of the current page
  Optional: path (string) - file path to save PDF
  Example: { "action": "pdf", "path": "/tmp/page.pdf" }

- close: Close the browser session
  Example: { "action": "close" }

Note: Selector conversion is automatic:
- :contains("text") → :has-text("text") (Playwright format)
- Element references from snapshot (e1, e2) are automatically resolved

Browser sessions are persistent - once created, you can perform multiple actions.
The browser runs headless by default and streams frames to the iOS app.`;

  readonly parameters = {
    type: 'object' as const,
    properties: {
      action: {
        type: 'string' as const,
        description: 'The browser action to perform (navigate, click, fill, type, select, screenshot, snapshot, wait, scroll, goBack, goForward, reload, hover, pressKey, getText, getAttribute, pdf, close)',
      },
      url: {
        type: 'string' as const,
        description: 'URL for navigate action',
      },
      selector: {
        type: 'string' as const,
        description: 'CSS selector or element reference (e.g., "e1") for click, fill, type, select, hover, getText, getAttribute actions',
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
      key: {
        type: 'string' as const,
        description: 'Key name for pressKey action (e.g., "Enter", "Tab", "Escape")',
      },
      attribute: {
        type: 'string' as const,
        description: 'Attribute name for getAttribute action',
      },
      path: {
        type: 'string' as const,
        description: 'File path for pdf action',
      },
    },
    required: ['action'],
  };

  private delegate?: BrowserDelegate;
  private session?: BrowserSession;
  private configuredSessionId?: string;

  constructor(config: AgentWebBrowserToolConfig = {}) {
    this.delegate = config.delegate;
    this.configuredSessionId = config.sessionId;
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
   * Uses configuredSessionId (Tron session ID) if available, allowing iOS to
   * control the browser session via RPC methods like browser.startStream
   */
  private async ensureSession(): Promise<void> {
    if (!this.session) {
      // Use Tron session ID if configured, otherwise generate a fallback
      const sessionId = this.configuredSessionId ?? `browser-${Date.now()}`;
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

      case 'goBack':
        return [
          {
            type: 'text',
            text: 'Navigated back in history',
          },
        ];

      case 'goForward':
        return [
          {
            type: 'text',
            text: 'Navigated forward in history',
          },
        ];

      case 'reload':
        return [
          {
            type: 'text',
            text: 'Page reloaded',
          },
        ];

      case 'hover':
        return [
          {
            type: 'text',
            text: `Hovered over: ${data.selector}`,
          },
        ];

      case 'pressKey':
        return [
          {
            type: 'text',
            text: `Pressed key: ${data.key}`,
          },
        ];

      case 'getText':
        return [
          {
            type: 'text',
            text: `Text content: ${data.text}`,
          },
        ];

      case 'getAttribute':
        return [
          {
            type: 'text',
            text: `Attribute ${data.attribute}: ${data.value}`,
          },
        ];

      case 'pdf':
        return [
          {
            type: 'text',
            text: data.path ? `PDF saved to: ${data.path}` : 'PDF generated',
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
