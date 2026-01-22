/**
 * @fileoverview Context Compactor
 *
 * Manages context window size by monitoring token usage and compacting
 * conversation history when approaching limits. Key features:
 *
 * - Token estimation for messages
 * - Configurable compaction thresholds (default: 25k tokens)
 * - Summary generation for compacted context
 * - Preservation of system messages and recent context
 *
 * @example
 * ```typescript
 * const compactor = createContextCompactor({
 *   maxTokens: 25000,
 *   compactionThreshold: 0.85,
 *   targetTokens: 10000,
 * });
 *
 * if (compactor.shouldCompact(messages)) {
 *   const result = await compactor.compact(messages);
 *   // Use result.messages and result.summary
 * }
 * ```
 */
import type { Message } from '../types/index.js';
import { getSettings } from '../settings/index.js';

// Get compactor settings (loaded lazily on first access)
function getCompactorSettings() {
  return getSettings().context.compactor;
}

// =============================================================================
// Types
// =============================================================================

export interface CompactorConfig {
  /** Maximum tokens before compaction is forced (default: 25000) */
  maxTokens: number;
  /** Threshold ratio to trigger compaction (default: 0.85 = 85%) */
  compactionThreshold: number;
  /** Target token count after compaction (default: 10000) */
  targetTokens: number;
  /** Number of recent message pairs to preserve verbatim (default: 2) */
  preserveRecentCount: number;
  /** Characters per token estimate (default: 4) */
  charsPerToken: number;
  /** Callback before compaction */
  onBeforeCompact?: (info: BeforeCompactInfo) => void;
  /** Callback after compaction */
  onAfterCompact?: (info: AfterCompactInfo) => void;
}

export interface BeforeCompactInfo {
  messageCount: number;
  estimatedTokens: number;
}

export interface AfterCompactInfo {
  originalTokens: number;
  newTokens: number;
  summary: string;
  messagesRemoved: number;
}

export interface CompactResult {
  /** Whether compaction was performed */
  compacted: boolean;
  /** Resulting messages after compaction */
  messages: Message[];
  /** Generated summary of compacted context */
  summary: string;
  /** Original token count before compaction */
  originalTokens: number;
  /** Token count after compaction */
  newTokens: number;
}

// =============================================================================
// Default Configuration
// =============================================================================

/** Get default compactor config from settings */
function getDefaultConfig(): CompactorConfig {
  const settings = getCompactorSettings();
  return {
    maxTokens: settings.maxTokens,
    compactionThreshold: settings.compactionThreshold,
    targetTokens: settings.targetTokens,
    preserveRecentCount: settings.preserveRecentCount,
    charsPerToken: settings.charsPerToken,
  };
}

// =============================================================================
// ContextCompactor Class
// =============================================================================

export class ContextCompactor {
  private config: CompactorConfig;

  constructor(config: Partial<CompactorConfig> = {}) {
    this.config = { ...getDefaultConfig(), ...config };
  }

  /**
   * Get current configuration
   */
  getConfig(): CompactorConfig {
    return { ...this.config };
  }

  /**
   * Estimate token count for messages
   */
  estimateTokens(messages: Message[]): number {
    let totalChars = 0;

    for (const message of messages) {
      totalChars += this.estimateMessageChars(message);
    }

    return Math.ceil(totalChars / this.config.charsPerToken);
  }

  /**
   * Check if compaction is needed based on token count
   */
  needsCompaction(currentTokens: number): boolean {
    return currentTokens >= this.config.maxTokens * this.config.compactionThreshold;
  }

  /**
   * Check if messages should be compacted
   */
  shouldCompact(messages: Message[]): boolean {
    const tokens = this.estimateTokens(messages);
    return this.needsCompaction(tokens);
  }

  /**
   * Compact messages, generating summary and preserving recent context
   */
  async compact(messages: Message[]): Promise<CompactResult> {
    if (messages.length === 0) {
      return {
        compacted: false,
        messages: [],
        summary: '',
        originalTokens: 0,
        newTokens: 0,
      };
    }

    const originalTokens = this.estimateTokens(messages);

    // Check if compaction is needed
    if (!this.needsCompaction(originalTokens)) {
      return {
        compacted: false,
        messages,
        summary: '',
        originalTokens,
        newTokens: originalTokens,
      };
    }

    // Call before callback
    this.config.onBeforeCompact?.({
      messageCount: messages.length,
      estimatedTokens: originalTokens,
    });

    // Preserve recent messages (pairs)
    const preserveCount = this.config.preserveRecentCount * 2; // user + assistant pairs
    const recentMessages = messages.slice(-preserveCount);
    const oldMessages = messages.slice(0, -preserveCount);

    // Generate summary of old messages
    const summary = this.generateSummary(oldMessages.length > 0 ? oldMessages : messages);

    // Build compacted message list
    const compactedMessages: Message[] = [];

    // Add summary as context if there were old messages to summarize
    if (oldMessages.length > 0 && summary) {
      const contextMessage: Message = {
        role: 'user',
        content: `[Context from earlier in this conversation]\n${summary}`,
      };
      compactedMessages.push(contextMessage);

      const ackMessage: Message = {
        role: 'assistant',
        content: [{ type: 'text', text: 'I understand the previous context. Let me continue helping you.' }],
      };
      compactedMessages.push(ackMessage);
    }

    // Add recent messages
    compactedMessages.push(...recentMessages);

    const newTokens = this.estimateTokens(compactedMessages);

    // Call after callback
    this.config.onAfterCompact?.({
      originalTokens,
      newTokens,
      summary,
      messagesRemoved: messages.length - compactedMessages.length,
    });

    return {
      compacted: true,
      messages: compactedMessages,
      summary,
      originalTokens,
      newTokens,
    };
  }

  /**
   * Generate a summary from messages
   */
  generateSummary(messages: Message[]): string {
    if (messages.length === 0) return '';

    const topics: string[] = [];
    const toolsUsed: string[] = [];
    const keyPoints: string[] = [];

    for (const message of messages) {
      const content = this.extractTextContent(message);

      // Extract topics (simple keyword extraction)
      const words = content.toLowerCase().split(/\s+/);
      for (const word of words) {
        // Look for meaningful words (longer than 4 chars, not common words)
        if (word.length > 4 && !COMMON_WORDS.has(word)) {
          topics.push(word);
        }
      }

      // Extract tool names
      if (Array.isArray(message.content)) {
        for (const block of message.content) {
          if (typeof block === 'object' && 'type' in block && block.type === 'tool_use') {
            const toolUse = block as { name: string };
            if (toolUse.name) {
              toolsUsed.push(toolUse.name);
            }
          }
        }
      }

      // Extract key points from assistant messages
      if (message.role === 'assistant' && content.length > 20) {
        // Take first sentence or first 100 chars
        const sentence = content.split(/[.!?]/).filter(s => s.trim())[0];
        if (sentence) {
          keyPoints.push(sentence.trim().slice(0, 100));
        }
      }
    }

    // Build summary
    const parts: string[] = [];

    // Topic summary (unique, top 5)
    const uniqueTopics = [...new Set(topics)].slice(0, 5);
    if (uniqueTopics.length > 0) {
      parts.push(`Topics discussed: ${uniqueTopics.join(', ')}`);
    }

    // Tools used (unique)
    const uniqueTools = [...new Set(toolsUsed)];
    if (uniqueTools.length > 0) {
      parts.push(`Tools used: ${uniqueTools.join(', ')}`);
    }

    // Key points (first 3)
    if (keyPoints.length > 0) {
      parts.push(`Key points: ${keyPoints.slice(0, 3).join('; ')}`);
    }

    // Message count
    parts.push(`(${messages.length} messages summarized)`);

    return parts.join('\n');
  }

  // ===========================================================================
  // Private Helpers
  // ===========================================================================

  private estimateMessageChars(message: Message): number {
    let chars = 0;

    // Add role overhead
    chars += (message.role?.length ?? 0) + 10;

    // Handle content
    if (typeof message.content === 'string') {
      chars += message.content.length;
    } else if (Array.isArray(message.content)) {
      for (const block of message.content) {
        chars += this.estimateBlockChars(block);
      }
    }

    return chars;
  }

  private estimateBlockChars(block: unknown): number {
    if (typeof block === 'string') {
      return block.length;
    }

    if (typeof block !== 'object' || block === null) {
      return 0;
    }

    const b = block as Record<string, unknown>;

    if (b.type === 'text' && typeof b.text === 'string') {
      return b.text.length;
    }

    if (b.type === 'tool_use') {
      // Tool use: name + serialized input
      let chars = (b.name as string)?.length ?? 0;
      chars += JSON.stringify(b.input ?? {}).length;
      return chars + 20; // overhead
    }

    if (b.type === 'tool_result') {
      // Tool result: content
      if (typeof b.content === 'string') {
        return b.content.length + 20;
      }
      return JSON.stringify(b.content ?? '').length + 20;
    }

    // Fallback: serialize
    return JSON.stringify(block).length;
  }

  private extractTextContent(message: Message): string {
    if (typeof message.content === 'string') {
      return message.content;
    }

    if (Array.isArray(message.content)) {
      return message.content
        .filter((b: unknown): b is { type: 'text'; text: string } =>
          typeof b === 'object' && b !== null && 'type' in b && (b as { type: string }).type === 'text' && 'text' in b
        )
        .map((b: { type: 'text'; text: string }) => b.text)
        .join(' ');
    }

    return '';
  }
}

// =============================================================================
// Common Words Filter
// =============================================================================

const COMMON_WORDS = new Set([
  'about', 'after', 'again', 'being', 'could', 'would', 'should', 'these',
  'their', 'there', 'where', 'which', 'while', 'other', 'under', 'thing',
  'things', 'thank', 'thanks', 'please', 'right', 'going', 'really',
  'doing', 'using', 'those', 'before', 'between', 'through', 'during',
  'without', 'within', 'something', 'anything', 'everything', 'nothing',
]);

// =============================================================================
// Factory Function
// =============================================================================

export function createContextCompactor(config: Partial<CompactorConfig> = {}): ContextCompactor {
  return new ContextCompactor(config);
}
