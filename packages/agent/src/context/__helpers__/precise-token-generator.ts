/**
 * @fileoverview Precise Token Generator for Compaction Testing
 *
 * Generates messages to hit exact token counts for boundary testing.
 * Unlike ContextSimulator which has variance, this is precise and matches
 * the ContextManager's token estimation algorithm exactly.
 *
 * @example
 * ```typescript
 * // Generate messages for exactly 140,000 tokens
 * const messages = PreciseTokenGenerator.generateForTokens(140_000);
 *
 * // Verify token count
 * const tokens = PreciseTokenGenerator.estimateTokens(messages);
 * console.log(tokens); // 140,000
 * ```
 */

import type {
  Message,
  UserMessage,
  AssistantMessage,
  ToolResultMessage,
} from '../../types/index.js';

// =============================================================================
// Types
// =============================================================================

export interface GeneratorOptions {
  /** Random seed for reproducibility (default: 42) */
  seed?: number;
  /** Include tool calls in messages (default: true) */
  includeToolCalls?: boolean;
  /** Number of recent turns to preserve for testing (default: 3) */
  preserveRecentTurns?: number;
  /** Average tokens per message pair (default: 300) */
  avgTokensPerPair?: number;
}

// =============================================================================
// Constants (match ContextManager)
// =============================================================================

const CHARS_PER_TOKEN = 4;
const MESSAGE_OVERHEAD = 10; // Role + structure overhead

// =============================================================================
// Simple PRNG for reproducibility
// =============================================================================

class SeededRandom {
  private seed: number;

  constructor(seed: number) {
    this.seed = seed;
  }

  random(): number {
    this.seed = (this.seed * 1664525 + 1013904223) % 2147483648;
    return this.seed / 2147483648;
  }

  randomInt(min: number, max: number): number {
    return Math.floor(this.random() * (max - min + 1)) + min;
  }
}

// =============================================================================
// PreciseTokenGenerator
// =============================================================================

/**
 * Generates messages to hit exact token counts.
 * Token estimation matches ContextManager's algorithm exactly.
 */
export class PreciseTokenGenerator {
  /**
   * Generate messages for exact token count.
   * The returned messages will have exactly the specified token count.
   */
  static generateForTokens(
    targetTokens: number,
    options: GeneratorOptions = {}
  ): Message[] {
    const {
      seed = 42,
      includeToolCalls = true,
      avgTokensPerPair = 300,
    } = options;

    const rng = new SeededRandom(seed);
    const messages: Message[] = [];
    let currentTokens = 0;

    // Generate message pairs until we're close to target
    while (currentTokens < targetTokens - avgTokensPerPair) {
      const turnIndex = messages.length / 2;

      // User message (roughly 1/4 of pair tokens)
      const userTokens = Math.floor(avgTokensPerPair * 0.25);
      const userMsg = this.createUserMessage(userTokens, turnIndex, rng);
      messages.push(userMsg);
      currentTokens += this.estimateMessageTokens(userMsg);

      // Assistant message (roughly 3/4 of pair tokens)
      const assistantTokens = Math.floor(avgTokensPerPair * 0.75);
      const hasToolCall = includeToolCalls && rng.random() < 0.3;
      const assistantMsg = this.createAssistantMessage(
        assistantTokens,
        turnIndex,
        hasToolCall,
        rng
      );
      messages.push(assistantMsg);
      currentTokens += this.estimateMessageTokens(assistantMsg);

      // Add tool result if there was a tool call
      if (hasToolCall) {
        const toolResultMsg = this.createToolResultMessage(
          Math.floor(avgTokensPerPair * 0.2),
          turnIndex,
          rng
        );
        messages.push(toolResultMsg);
        currentTokens += this.estimateMessageTokens(toolResultMsg);
      }
    }

    // Fine-tune by padding the last message to hit exact target
    const remaining = targetTokens - currentTokens;
    if (remaining > 0 && messages.length > 0) {
      const lastMsg = messages[messages.length - 1];
      if (lastMsg) {
        this.padMessage(lastMsg, remaining);
        currentTokens = this.estimateTokens(messages);
      }
    }

    // If we overshot, trim the last message
    if (currentTokens > targetTokens && messages.length > 0) {
      const overshoot = currentTokens - targetTokens;
      const lastMsg = messages[messages.length - 1];
      if (lastMsg) {
        this.trimMessage(lastMsg, overshoot);
      }
    }

    return messages;
  }

  /**
   * Calculate tokens for given messages using same algorithm as ContextManager.
   */
  static estimateTokens(messages: Message[]): number {
    let total = 0;
    for (const msg of messages) {
      total += this.estimateMessageTokens(msg);
    }
    return total;
  }

  /**
   * Add padding to reach exact token count.
   */
  static padToTokens(messages: Message[], targetTokens: number): Message[] {
    const result = [...messages];
    const currentTokens = this.estimateTokens(result);
    const needed = targetTokens - currentTokens;

    if (needed <= 0) {
      return result;
    }

    // Add padding messages
    const paddingChars = needed * CHARS_PER_TOKEN - MESSAGE_OVERHEAD;
    if (paddingChars > 0) {
      result.push({
        role: 'user',
        content: 'x'.repeat(Math.max(0, paddingChars)),
      });
    }

    return result;
  }

  /**
   * Estimate tokens for a single message (matches ContextManager algorithm).
   */
  static estimateMessageTokens(message: Message): number {
    let chars = (message.role?.length ?? 0) + MESSAGE_OVERHEAD;

    if (message.role === 'toolResult') {
      chars += (message as ToolResultMessage).toolCallId.length;
      const content = (message as ToolResultMessage).content;
      if (typeof content === 'string') {
        chars += content.length;
      } else if (Array.isArray(content)) {
        for (const block of content) {
          chars += this.estimateBlockChars(block);
        }
      }
    } else if (typeof message.content === 'string') {
      chars += message.content.length;
    } else if (Array.isArray(message.content)) {
      for (const block of message.content) {
        chars += this.estimateBlockChars(block);
      }
    }

    return Math.ceil(chars / CHARS_PER_TOKEN);
  }

  // ===========================================================================
  // Message Creation Helpers
  // ===========================================================================

  private static createUserMessage(
    targetTokens: number,
    turnIndex: number,
    rng: SeededRandom
  ): UserMessage {
    const targetChars = targetTokens * CHARS_PER_TOKEN - MESSAGE_OVERHEAD - 4; // 4 for 'user'
    const content = `Turn ${turnIndex}: ` + 'q'.repeat(Math.max(0, targetChars - 10));

    return {
      role: 'user',
      content,
    };
  }

  private static createAssistantMessage(
    targetTokens: number,
    turnIndex: number,
    includeToolCall: boolean,
    rng: SeededRandom
  ): AssistantMessage {
    const content: AssistantMessage['content'] = [];

    // Calculate target chars for text
    let targetChars = targetTokens * CHARS_PER_TOKEN - MESSAGE_OVERHEAD - 9; // 9 for 'assistant'

    // Reserve chars for tool call if needed
    const toolCallChars = includeToolCall ? 100 : 0;
    targetChars -= toolCallChars;

    // Add text content
    content.push({
      type: 'text',
      text: `Response ${turnIndex}: ` + 'r'.repeat(Math.max(0, targetChars - 15)),
    });

    // Add tool call if requested
    if (includeToolCall) {
      content.push({
        type: 'tool_use',
        id: `tool_${turnIndex}_${rng.randomInt(1000, 9999)}`,
        name: 'Read',
        arguments: { file_path: '/src/test.ts' },
      });
    }

    return {
      role: 'assistant',
      content,
    };
  }

  private static createToolResultMessage(
    targetTokens: number,
    turnIndex: number,
    rng: SeededRandom
  ): ToolResultMessage {
    const toolCallId = `tool_${turnIndex}_${rng.randomInt(1000, 9999)}`;
    const overhead = MESSAGE_OVERHEAD + 10 + toolCallId.length; // 10 for 'toolResult'
    const targetChars = targetTokens * CHARS_PER_TOKEN - overhead;

    return {
      role: 'toolResult',
      toolCallId,
      content: `Result: ` + 't'.repeat(Math.max(0, targetChars - 8)),
    };
  }

  // ===========================================================================
  // Padding/Trimming Helpers
  // ===========================================================================

  private static padMessage(message: Message, additionalTokens: number): void {
    const additionalChars = additionalTokens * CHARS_PER_TOKEN;

    if (message.role === 'user' && typeof message.content === 'string') {
      (message as UserMessage).content += 'p'.repeat(additionalChars);
    } else if (message.role === 'assistant' && Array.isArray(message.content)) {
      const textBlock = message.content.find(
        (b): b is { type: 'text'; text: string } =>
          typeof b === 'object' && b !== null && 'type' in b && b.type === 'text'
      );
      if (textBlock) {
        textBlock.text += 'p'.repeat(additionalChars);
      }
    } else if (message.role === 'toolResult' && typeof message.content === 'string') {
      (message as ToolResultMessage).content += 'p'.repeat(additionalChars);
    }
  }

  private static trimMessage(message: Message, tokensToRemove: number): void {
    const charsToRemove = tokensToRemove * CHARS_PER_TOKEN;

    if (message.role === 'user' && typeof message.content === 'string') {
      const content = (message as UserMessage).content;
      (message as UserMessage).content = content.slice(
        0,
        Math.max(10, content.length - charsToRemove)
      );
    } else if (message.role === 'assistant' && Array.isArray(message.content)) {
      const textBlock = message.content.find(
        (b): b is { type: 'text'; text: string } =>
          typeof b === 'object' && b !== null && 'type' in b && b.type === 'text'
      );
      if (textBlock) {
        textBlock.text = textBlock.text.slice(
          0,
          Math.max(10, textBlock.text.length - charsToRemove)
        );
      }
    } else if (message.role === 'toolResult' && typeof message.content === 'string') {
      const content = (message as ToolResultMessage).content;
      (message as ToolResultMessage).content = content.slice(
        0,
        Math.max(10, content.length - charsToRemove)
      );
    }
  }

  // ===========================================================================
  // Block Estimation (matches ContextManager)
  // ===========================================================================

  private static estimateBlockChars(block: unknown): number {
    if (typeof block !== 'object' || block === null) {
      return 0;
    }

    const b = block as Record<string, unknown>;

    if (b.type === 'text' && typeof b.text === 'string') {
      return b.text.length;
    }

    if (b.type === 'thinking' && typeof b.thinking === 'string') {
      return b.thinking.length;
    }

    if (b.type === 'tool_use') {
      let size = 0;
      if (typeof b.id === 'string') size += b.id.length;
      if (typeof b.name === 'string') size += b.name.length;
      if (b.input || b.arguments) {
        size += JSON.stringify(b.input ?? b.arguments).length;
      }
      return size;
    }

    if (b.type === 'tool_result') {
      let size = 0;
      if (typeof b.tool_use_id === 'string') size += b.tool_use_id.length;
      if (typeof b.content === 'string') size += b.content.length;
      return size;
    }

    return JSON.stringify(block).length;
  }
}

// =============================================================================
// Factory Functions
// =============================================================================

/**
 * Generate messages for exact token count.
 */
export function generateMessagesForTokens(
  targetTokens: number,
  options?: GeneratorOptions
): Message[] {
  return PreciseTokenGenerator.generateForTokens(targetTokens, options);
}

/**
 * Estimate tokens for messages.
 */
export function estimateMessageTokens(messages: Message[]): number {
  return PreciseTokenGenerator.estimateTokens(messages);
}
