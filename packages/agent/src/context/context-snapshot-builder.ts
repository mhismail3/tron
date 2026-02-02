/**
 * @fileoverview Context Snapshot Builder
 *
 * Generates snapshots of context state for monitoring and debugging:
 * - Basic snapshots with token breakdown
 * - Detailed snapshots with per-message information
 * - Threshold level determination
 *
 * Extracted from ContextManager to provide focused snapshot operations.
 */

import type { Message, Tool } from '@core/types/index.js';
import {
  THRESHOLDS,
  type ThresholdLevel,
  type ContextSnapshot,
  type DetailedContextSnapshot,
  type DetailedMessageInfo,
} from './types.js';

// =============================================================================
// Types
// =============================================================================

/**
 * Dependencies injected from ContextManager.
 * Allows ContextSnapshotBuilder to access context state without direct coupling.
 */
export interface SnapshotDeps {
  /** Get current token count (API-reported) */
  getCurrentTokens: () => number;
  /** Get model's context limit */
  getContextLimit: () => number;
  /** Get current messages */
  getMessages: () => Message[];
  /** Estimate system prompt tokens */
  estimateSystemPromptTokens: () => number;
  /** Estimate tools tokens */
  estimateToolsTokens: () => number;
  /** Estimate rules tokens */
  estimateRulesTokens: () => number;
  /** Get total messages tokens */
  getMessagesTokens: () => number;
  /** Get token count for a specific message */
  getMessageTokens: (msg: Message) => number;
  /** Get system prompt */
  getSystemPrompt: () => string;
  /** Get tool clarification message (for Codex providers) */
  getToolClarificationMessage: () => string | null;
  /** Get tools */
  getTools: () => Tool[];
}

// =============================================================================
// ContextSnapshotBuilder
// =============================================================================

/**
 * Generates snapshots of context state.
 *
 * Responsibilities:
 * - Build basic snapshots with token breakdown
 * - Build detailed snapshots with per-message information
 * - Determine threshold levels
 */
export class ContextSnapshotBuilder {
  constructor(private deps: SnapshotDeps) {}

  /**
   * Get threshold level for a token count.
   */
  getThresholdLevel(tokens: number): ThresholdLevel {
    const ratio = tokens / this.deps.getContextLimit();
    if (ratio >= THRESHOLDS.exceeded) return 'exceeded';
    if (ratio >= THRESHOLDS.critical) return 'critical';
    if (ratio >= THRESHOLDS.alert) return 'alert';
    if (ratio >= THRESHOLDS.warning) return 'warning';
    return 'normal';
  }

  /**
   * Build a basic snapshot of current context state.
   */
  build(): ContextSnapshot {
    const currentTokens = this.deps.getCurrentTokens();
    const contextLimit = this.deps.getContextLimit();

    return {
      currentTokens,
      contextLimit,
      usagePercent: currentTokens / contextLimit,
      thresholdLevel: this.getThresholdLevel(currentTokens),
      breakdown: {
        systemPrompt: this.deps.estimateSystemPromptTokens(),
        tools: this.deps.estimateToolsTokens(),
        rules: this.deps.estimateRulesTokens(),
        messages: this.deps.getMessagesTokens(),
      },
    };
  }

  /**
   * Build a detailed snapshot with per-message token breakdown.
   */
  buildDetailed(): DetailedContextSnapshot {
    const snapshot = this.build();
    const detailedMessages = this.buildDetailedMessages();

    // Use the effective system-level context: tool clarification for Codex, system prompt for others
    const systemPrompt = this.deps.getSystemPrompt();
    const toolClarification = this.deps.getToolClarificationMessage();
    const effectiveSystemContent = toolClarification || systemPrompt;

    return {
      ...snapshot,
      messages: detailedMessages,
      systemPromptContent: effectiveSystemContent,
      toolClarificationContent: toolClarification ?? undefined,
      toolsContent: this.deps.getTools().map(
        (t) => `${t.name}: ${t.description || 'No description'}`
      ),
    };
  }

  // ===========================================================================
  // Private Helpers
  // ===========================================================================

  /**
   * Build detailed message information for all messages.
   */
  private buildDetailedMessages(): DetailedMessageInfo[] {
    const messages = this.deps.getMessages();
    const detailedMessages: DetailedMessageInfo[] = [];

    for (let i = 0; i < messages.length; i++) {
      const msg = messages[i];
      if (!msg) continue;

      const tokens = this.deps.getMessageTokens(msg);
      const detailedInfo = this.buildMessageInfo(msg, i, tokens);
      if (detailedInfo) {
        detailedMessages.push(detailedInfo);
      }
    }

    return detailedMessages;
  }

  /**
   * Build detailed info for a single message.
   */
  private buildMessageInfo(
    msg: Message,
    index: number,
    tokens: number
  ): DetailedMessageInfo | null {
    switch (msg.role) {
      case 'user':
        return this.buildUserMessageInfo(msg, index, tokens);
      case 'assistant':
        return this.buildAssistantMessageInfo(msg, index, tokens);
      case 'toolResult':
        return this.buildToolResultInfo(msg, index, tokens);
      default:
        return null;
    }
  }

  /**
   * Build detailed info for a user message.
   */
  private buildUserMessageInfo(
    msg: Extract<Message, { role: 'user' }>,
    index: number,
    tokens: number
  ): DetailedMessageInfo {
    const content =
      typeof msg.content === 'string'
        ? msg.content
        : msg.content
            .map((c) => (c.type === 'text' ? c.text : '[image]'))
            .join('\n');

    return {
      index,
      role: 'user',
      tokens,
      summary: content.length > 100 ? content.slice(0, 100) + '...' : content,
      content,
    };
  }

  /**
   * Build detailed info for an assistant message.
   */
  private buildAssistantMessageInfo(
    msg: Extract<Message, { role: 'assistant' }>,
    index: number,
    tokens: number
  ): DetailedMessageInfo {
    const textParts: string[] = [];
    const toolCalls: NonNullable<DetailedMessageInfo['toolCalls']> = [];

    for (const block of msg.content) {
      if (block.type === 'text') {
        textParts.push(block.text);
      } else if (block.type === 'tool_use') {
        const argsStr = block.arguments
          ? JSON.stringify(block.arguments, null, 2)
          : '{}';
        const toolTokens = Math.ceil((block.name.length + argsStr.length) / 4);
        toolCalls.push({
          id: block.id,
          name: block.name,
          tokens: toolTokens,
          arguments: argsStr,
        });
      }
    }

    const content = textParts.join('\n');
    const summary =
      toolCalls.length > 0
        ? `${toolCalls.map((t) => t.name).join(', ')}${content ? ' + text' : ''}`
        : content.length > 100
          ? content.slice(0, 100) + '...'
          : content;

    return {
      index,
      role: 'assistant',
      tokens,
      summary,
      content,
      toolCalls: toolCalls.length > 0 ? toolCalls : undefined,
    };
  }

  /**
   * Build detailed info for a tool result message.
   */
  private buildToolResultInfo(
    msg: Extract<Message, { role: 'toolResult' }>,
    index: number,
    tokens: number
  ): DetailedMessageInfo {
    const content =
      typeof msg.content === 'string'
        ? msg.content
        : msg.content
            .map((c) => (c.type === 'text' ? c.text : '[image]'))
            .join('\n');

    return {
      index,
      role: 'toolResult',
      tokens,
      summary: content.length > 100 ? content.slice(0, 100) + '...' : content,
      content,
      toolCallId: msg.toolCallId,
      isError: msg.isError,
    };
  }
}

// =============================================================================
// Factory
// =============================================================================

/**
 * Create a new ContextSnapshotBuilder instance.
 */
export function createContextSnapshotBuilder(
  deps: SnapshotDeps
): ContextSnapshotBuilder {
  return new ContextSnapshotBuilder(deps);
}
