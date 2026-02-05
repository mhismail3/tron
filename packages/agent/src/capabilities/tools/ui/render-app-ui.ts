/**
 * @fileoverview RenderAppUI Tool
 *
 * Enables the agent to render native iOS UI interfaces in real-time.
 * The UI definition is sent to the iOS app which renders it as a
 * native SwiftUI sheet with liquid glass styling.
 *
 * ASYNC MODEL: Similar to AskUserQuestion, the tool returns immediately
 * with stopTurn: true. The user can interact with the rendered UI,
 * and their actions (button taps, state changes) come back as new
 * prompts or via the tool.result RPC method.
 */

import { randomUUID } from 'crypto';
import type { TronTool, TronToolResult } from '@core/types/index.js';
import type { RenderAppUIParams } from '@interface/ui/components.js';
import { validateRenderAppUIParams } from '@interface/ui/validators.js';
import { UI_COMPONENT_SCHEMA } from '@interface/ui/schema.js';
import { createLogger } from '@infrastructure/logging/index.js';

const logger = createLogger('tool:render-app-ui');

/**
 * Generate a unique canvas ID based on title or root component type.
 * Format: <descriptive-slug>-<8-char-random>
 */
function generateCanvasId(title?: string, ui?: { $tag?: string }): string {
  const suffix = randomUUID().replace(/-/g, '').slice(0, 8);

  // Extract words from title if available
  if (title) {
    const words = title
      .toLowerCase()
      .replace(/[^a-z0-9\s]/g, '')
      .split(/\s+/)
      .filter(w => w.length > 0)
      .slice(0, 3);
    if (words.length > 0) {
      return `${words.join('-')}-${suffix}`;
    }
  }

  // Fall back to root component type
  const rootTag = ui?.$tag?.toLowerCase() || 'canvas';
  return `canvas-${rootTag}-${suffix}`;
}

/**
 * Configuration for RenderAppUI tool
 */
export interface RenderAppUIConfig {
  workingDirectory: string;
}

export class RenderAppUITool implements TronTool<RenderAppUIParams> {
  readonly name = 'RenderAppUI';
  readonly executionContract = 'options' as const;

  /**
   * Retry tracking per canvasId to prevent infinite loops on validation failure.
   * Key is canvasId, value is current retry count.
   */
  private retryCount: Map<string, number> = new Map();

  /**
   * Maximum number of automatic retries before giving up.
   * After this many failures, we return a real error.
   */
  private readonly MAX_RETRIES = 3;

  readonly description = `Render a native iOS UI interface for the user to interact with.

Use this tool to create custom interfaces when you need to:
- Build interactive forms or settings screens
- Display structured data with charts, lists, or tables
- Create multi-step wizards or workflows
- Present options with buttons, toggles, or sliders
- Show progress or status dashboards

The UI renders as a native SwiftUI sheet on iOS with liquid glass styling. You define
the interface using a component tree structure.
${UI_COMPONENT_SCHEMA}

## Usage Pattern

1. Call RenderAppUI with your UI definition
2. The iOS app renders the UI as a sheet
3. When user interacts (button tap, toggle change, etc.):
   - Button taps: actionId is returned in next turn
   - State changes: bindingId and value are returned
4. You can update the UI by calling RenderAppUI again with the same canvasId

## Tips

- Use semantic colors: "primary", "secondary", "accent", "destructive"
- Keep UIs simple and focused on the task
- Provide clear labels and feedback
- Use Sections to group related controls
- Test complex layouts incrementally

IMPORTANT: After calling this tool, do NOT output additional text. The UI will be
presented to the user, and their response will come back as a new message.`;

  readonly parameters = {
    type: 'object' as const,
    properties: {
      canvasId: {
        type: 'string' as const,
        description: 'Unique identifier for this canvas. Auto-generated if not provided. Provide the same canvasId to update an existing canvas.',
      },
      title: {
        type: 'string' as const,
        description: 'Optional title shown in the sheet toolbar',
      },
      ui: {
        type: 'object' as const,
        description: 'Root UI component tree (see schema in tool description)',
      },
      state: {
        type: 'object' as const,
        description: 'Initial state values for bound controls (keys are bindingIds)',
      },
    },
    required: ['ui'] as string[],
  };

  readonly label = 'Render App UI';
  readonly category = 'custom' as const;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  constructor(_config: RenderAppUIConfig) {
    // Config accepted for API compatibility
  }

  async execute(
    args: RenderAppUIParams,
    options?: {
      toolCallId?: string;
      sessionId?: string;
      signal?: AbortSignal;
    }
  ): Promise<TronToolResult> {
    const params = args;

    // Auto-generate canvasId if not provided
    if (!params.canvasId) {
      params.canvasId = generateCanvasId(params.title, params.ui as { $tag?: string });
    }

    // Validate parameters
    const validation = validateRenderAppUIParams(params);
    if (!validation.valid) {
      const canvasId = (params as { canvasId?: string }).canvasId || 'unknown';
      const currentRetries = this.retryCount.get(canvasId) || 0;

      // Check if we've exceeded max retries
      if (currentRetries >= this.MAX_RETRIES) {
        // Give up after max retries - return actual error
        this.retryCount.delete(canvasId);
        logger.error('Max retries exceeded for UI validation', {
          canvasId,
          attempts: currentRetries + 1,
          errors: validation.errors,
        });
        return {
          content: `Failed to render valid UI after ${this.MAX_RETRIES} attempts:\n${validation.errors.join('\n')}`,
          isError: true,
          stopTurn: true,
          details: {
            validation,
            canvasId,
            maxRetriesExceeded: true,
          },
        };
      }

      // Increment retry count
      this.retryCount.set(canvasId, currentRetries + 1);
      const attempt = currentRetries + 1;

      logger.warn('UI validation failed, allowing retry', {
        canvasId,
        attempt,
        maxRetries: this.MAX_RETRIES,
        errors: validation.errors,
      });

      // Return non-error result with stopTurn: false so turn continues
      // LLM will see the errors and can retry with corrections
      return {
        content: `UI validation failed (attempt ${attempt}/${this.MAX_RETRIES}). Fix these errors and call RenderAppUI again with the same canvasId:\n${validation.errors.join('\n')}\n\nKeep the iOS sheet open - user is waiting.`,
        isError: false,      // NOT an error - just needs retry
        stopTurn: false,     // Allow turn to continue so LLM can retry
        details: {
          validation,
          needsRetry: true,
          canvasId,
          attempt,
        },
      };
    }

    // Validation passed - clear any retry count for this canvas
    this.retryCount.delete(params.canvasId);

    // Log warnings if any
    if (validation.warnings.length > 0) {
      logger.warn('UI validation warnings', {
        canvasId: params.canvasId,
        warnings: validation.warnings,
      });
    }

    const toolCallId = options?.toolCallId;
    const sessionId = options?.sessionId;

    logger.info('Rendering UI canvas', {
      sessionId,
      toolCallId,
      canvasId: params.canvasId,
      title: params.title,
      hasState: !!params.state,
    });

    // ASYNC MODEL: Return immediately with summary.
    // The UI definition is captured in the tool.call event which
    // triggers the iOS app to render it. User actions will come
    // back via tool.result or as new prompts.
    const summary = this.formatSummary(params);

    return {
      content: summary,
      isError: false,
      // Stop the turn - user needs to interact with the UI
      stopTurn: true,
      details: {
        async: true,
        canvasId: params.canvasId,
        title: params.title,
        ui: params.ui,
        state: params.state,
      },
    };
  }

  /**
   * Format a summary of the rendered UI for the agent
   */
  private formatSummary(params: RenderAppUIParams): string {
    const lines: string[] = [];
    lines.push(`UI canvas "${params.canvasId}" rendered.`);

    if (params.title) {
      lines.push(`Title: ${params.title}`);
    }

    // Count component types
    const counts = this.countComponents(params.ui);
    const parts: string[] = [];
    if (counts.buttons > 0) parts.push(`${counts.buttons} button${counts.buttons > 1 ? 's' : ''}`);
    if (counts.toggles > 0) parts.push(`${counts.toggles} toggle${counts.toggles > 1 ? 's' : ''}`);
    if (counts.textFields > 0) parts.push(`${counts.textFields} text field${counts.textFields > 1 ? 's' : ''}`);
    if (counts.sliders > 0) parts.push(`${counts.sliders} slider${counts.sliders > 1 ? 's' : ''}`);
    if (counts.pickers > 0) parts.push(`${counts.pickers} picker${counts.pickers > 1 ? 's' : ''}`);

    if (parts.length > 0) {
      lines.push(`Contains: ${parts.join(', ')}`);
    }

    lines.push('');
    lines.push('Awaiting user interaction...');

    return lines.join('\n');
  }

  /**
   * Count interactive components in the UI tree
   */
  private countComponents(ui: unknown): {
    buttons: number;
    toggles: number;
    textFields: number;
    sliders: number;
    pickers: number;
  } {
    const counts = { buttons: 0, toggles: 0, textFields: 0, sliders: 0, pickers: 0 };

    const traverse = (node: unknown): void => {
      if (typeof node !== 'object' || node === null) return;

      const comp = node as { $tag?: string; $children?: unknown };
      switch (comp.$tag) {
        case 'Button': counts.buttons++; break;
        case 'Toggle': counts.toggles++; break;
        case 'TextField': counts.textFields++; break;
        case 'Slider': counts.sliders++; break;
        case 'Picker': counts.pickers++; break;
      }

      if (Array.isArray(comp.$children)) {
        for (const child of comp.$children) {
          traverse(child);
        }
      } else if (typeof comp.$children === 'object') {
        traverse(comp.$children);
      }
    };

    traverse(ui);
    return counts;
  }
}
