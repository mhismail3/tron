/**
 * @fileoverview Context Simulator for Testing
 *
 * Generates realistic conversation data to test compaction behavior
 * without consuming real API tokens. Supports:
 *
 * - Generating sessions at exact token counts
 * - Generating sessions at specific % of context limit
 * - Including tool calls with realistic arguments
 * - Generating test suites at all threshold levels
 *
 * @example
 * ```typescript
 * // Generate a session at 85% of 200k context
 * const simulator = new ContextSimulator({ targetTokens: 170000 });
 * const session = simulator.generateSession();
 *
 * // Generate at specific utilization
 * const session85 = simulator.generateAtUtilization(85, 200000);
 *
 * // Generate test suite for all thresholds
 * const suite = ContextSimulator.generateTestSuite(200000);
 * ```
 */

import type { Message, UserMessage, AssistantMessage, ToolResultMessage } from '../../types/index.js';

// =============================================================================
// Types
// =============================================================================

export interface SimulatorConfig {
  /** Target token count to generate */
  targetTokens: number;
  /** Ratio of turns that include tool calls (0-1, default: 0.3) */
  toolCallRatio?: number;
  /** Include thinking blocks (default: false) */
  includeThinking?: boolean;
  /** Average tokens per user message (default: 100) */
  avgUserTokens?: number;
  /** Average tokens per assistant response (default: 500) */
  avgAssistantTokens?: number;
  /** Average tokens per tool result (default: 200) */
  avgToolResultTokens?: number;
  /** Model to simulate (default: 'claude-sonnet-4-20250514') */
  model?: string;
  /** Random seed for reproducibility (default: Date.now()) */
  seed?: number;
}

export interface SimulatedSession {
  /** Generated messages */
  messages: Message[];
  /** Estimated token count */
  estimatedTokens: number;
  /** Number of turns (user + assistant pairs) */
  turnCount: number;
  /** Number of tool calls made */
  toolCalls: number;
  /** Files mentioned in tool calls */
  filesModified: string[];
  /** Tools used */
  toolsUsed: string[];
}

// =============================================================================
// Constants
// =============================================================================

/** Chars per token estimate (matches token-estimator.ts) */
const CHARS_PER_TOKEN = 4;

/** Sample file paths for realistic tool calls */
const SAMPLE_FILES = [
  '/src/components/Button.tsx',
  '/src/hooks/useAuth.ts',
  '/src/services/api.ts',
  '/src/utils/helpers.ts',
  '/src/models/User.ts',
  '/tests/Button.test.tsx',
  '/package.json',
  '/tsconfig.json',
  '/README.md',
  '/src/index.ts',
  '/src/types/index.ts',
  '/src/context/loader.ts',
  '/src/context/context-manager.ts',
  '/src/agent/tron-agent.ts',
  '/docs/api.md',
];

/** Sample tool names */
const SAMPLE_TOOLS = [
  'Read',
  'Write',
  'Edit',
  'Grep',
  'Glob',
  'Bash',
  'Task',
  'WebFetch',
  'AskUserQuestion',
];

/** Sample user prompts for realistic content */
const USER_PROMPTS = [
  'Can you help me fix this bug in the authentication flow?',
  'Please add a new feature for user notifications.',
  'I need to refactor this component to use hooks.',
  'Can you write tests for the API service?',
  'Help me understand how this function works.',
  'Please update the documentation for the new API.',
  'I need to implement error handling for this edge case.',
  'Can you review this code and suggest improvements?',
  'Help me debug this issue with state management.',
  'Please add TypeScript types to this module.',
  'I want to optimize the performance of this query.',
  'Can you help me set up the CI/CD pipeline?',
  'Please implement pagination for the user list.',
  'I need to add validation to this form.',
  'Can you help me migrate to the new API version?',
];

/** Sample assistant response fragments */
const ASSISTANT_FRAGMENTS = [
  "I'll help you with that. Let me start by reading the relevant files.",
  "I've analyzed the code and found the issue. Here's my recommendation:",
  "Based on my review, I suggest implementing the following changes:",
  "I'll create the necessary files and update the existing code.",
  "The test results show that the implementation is working correctly.",
  "I've made the requested changes. Let me explain what I did:",
  "Here's the updated code with the new feature implemented:",
  "I found a few issues that need to be addressed:",
  "The documentation has been updated to reflect the changes.",
  "I've refactored the code to improve maintainability:",
];

// =============================================================================
// Simple PRNG for reproducibility
// =============================================================================

class SeededRandom {
  private seed: number;

  constructor(seed: number) {
    this.seed = seed;
  }

  /** Returns a random number between 0 and 1 */
  random(): number {
    // Simple LCG algorithm
    this.seed = (this.seed * 1664525 + 1013904223) % 2147483648;
    return this.seed / 2147483648;
  }

  /** Returns a random integer between min and max (inclusive) */
  randomInt(min: number, max: number): number {
    return Math.floor(this.random() * (max - min + 1)) + min;
  }

  /** Returns a random element from an array */
  randomElement<T>(array: T[]): T {
    return array[this.randomInt(0, array.length - 1)];
  }

  /** Returns true with the given probability */
  randomBool(probability: number): boolean {
    return this.random() < probability;
  }
}

// =============================================================================
// ContextSimulator
// =============================================================================

export class ContextSimulator {
  private config: Required<SimulatorConfig>;
  private rng: SeededRandom;

  constructor(config: SimulatorConfig) {
    this.config = {
      targetTokens: config.targetTokens,
      toolCallRatio: config.toolCallRatio ?? 0.3,
      includeThinking: config.includeThinking ?? false,
      avgUserTokens: config.avgUserTokens ?? 100,
      avgAssistantTokens: config.avgAssistantTokens ?? 500,
      avgToolResultTokens: config.avgToolResultTokens ?? 200,
      model: config.model ?? 'claude-sonnet-4-20250514',
      seed: config.seed ?? Date.now(),
    };
    this.rng = new SeededRandom(this.config.seed);
  }

  /**
   * Generate a simulated session with realistic conversation patterns.
   * Continues generating turns until target token count is reached.
   */
  generateSession(): SimulatedSession {
    const messages: Message[] = [];
    let currentTokens = 0;
    let turnCount = 0;
    let toolCallCount = 0;
    const filesModified = new Set<string>();
    const toolsUsed = new Set<string>();

    // Generate turns until we hit target tokens
    while (currentTokens < this.config.targetTokens) {
      turnCount++;

      // User message
      const userMsg = this.generateUserMessage(turnCount);
      messages.push(userMsg);
      currentTokens += this.estimateTokens(userMsg);

      // Check if we've hit target after user message
      if (currentTokens >= this.config.targetTokens) {
        break;
      }

      // Decide if this turn has a tool call
      const hasToolCall = this.rng.randomBool(this.config.toolCallRatio);

      // Assistant response
      const assistantMsg = this.generateAssistantMessage(turnCount, hasToolCall);
      messages.push(assistantMsg);
      currentTokens += this.estimateTokens(assistantMsg);

      // Track tool usage
      if (hasToolCall && Array.isArray(assistantMsg.content)) {
        for (const block of assistantMsg.content) {
          if (typeof block === 'object' && 'type' in block && block.type === 'tool_use') {
            const toolUse = block as { name: string; arguments?: Record<string, unknown> };
            toolCallCount++;
            toolsUsed.add(toolUse.name);
            if (toolUse.arguments?.file_path) {
              filesModified.add(toolUse.arguments.file_path as string);
            }
          }
        }

        // Tool result message
        const toolResultMsg = this.generateToolResultMessage(turnCount);
        messages.push(toolResultMsg);
        currentTokens += this.estimateTokens(toolResultMsg);
      }
    }

    return {
      messages,
      estimatedTokens: currentTokens,
      turnCount,
      toolCalls: toolCallCount,
      filesModified: [...filesModified],
      toolsUsed: [...toolsUsed],
    };
  }

  /**
   * Generate a session at specific context utilization percentage.
   */
  generateAtUtilization(percentage: number, contextLimit: number): SimulatedSession {
    const targetTokens = Math.floor((percentage / 100) * contextLimit);
    const simulator = new ContextSimulator({ ...this.config, targetTokens });
    return simulator.generateSession();
  }

  /**
   * Generate test suite at all threshold levels.
   * Returns sessions at 50%, 70%, 85%, and 95% utilization.
   */
  static generateTestSuite(contextLimit: number = 200000): Map<string, SimulatedSession> {
    const suite = new Map<string, SimulatedSession>();
    const seed = 12345; // Fixed seed for reproducibility

    suite.set('normal_50', new ContextSimulator({
      targetTokens: Math.floor(contextLimit * 0.5),
      seed,
    }).generateSession());

    suite.set('warning_70', new ContextSimulator({
      targetTokens: Math.floor(contextLimit * 0.7),
      seed: seed + 1,
    }).generateSession());

    suite.set('alert_85', new ContextSimulator({
      targetTokens: Math.floor(contextLimit * 0.85),
      seed: seed + 2,
    }).generateSession());

    suite.set('critical_95', new ContextSimulator({
      targetTokens: Math.floor(contextLimit * 0.95),
      seed: seed + 3,
    }).generateSession());

    return suite;
  }

  // ===========================================================================
  // Message Generators
  // ===========================================================================

  private generateUserMessage(turn: number): UserMessage {
    // Generate content of varying length
    const targetChars = this.config.avgUserTokens * CHARS_PER_TOKEN;
    const variance = this.rng.randomInt(-20, 50);
    const actualChars = Math.max(50, targetChars + variance * CHARS_PER_TOKEN);

    let content = this.rng.randomElement(USER_PROMPTS);

    // Pad to target length with contextual content
    while (content.length < actualChars) {
      content += ` Also, ${this.rng.randomElement([
        'please make sure to follow the existing code style',
        'let me know if you have any questions about the requirements',
        'I think this should integrate with the existing system',
        'we need to ensure backward compatibility',
        'performance is important for this feature',
        'please add appropriate error handling',
        'the tests should cover edge cases',
        'documentation would be helpful',
      ])}.`;
    }

    return {
      role: 'user',
      content: content.slice(0, actualChars),
      timestamp: Date.now() - (1000 - turn) * 60000,
    };
  }

  private generateAssistantMessage(turn: number, includeToolCall: boolean): AssistantMessage {
    const content: Array<{ type: 'text'; text: string } | { type: 'thinking'; thinking: string } | { type: 'tool_use'; id: string; name: string; arguments: Record<string, unknown> }> = [];

    // Optionally include thinking
    if (this.config.includeThinking && this.rng.randomBool(0.3)) {
      content.push({
        type: 'thinking',
        thinking: this.generateThinkingContent(),
      });
    }

    // Generate text content
    const targetChars = this.config.avgAssistantTokens * CHARS_PER_TOKEN;
    const variance = this.rng.randomInt(-100, 200);
    const actualChars = Math.max(100, targetChars + variance * CHARS_PER_TOKEN);

    let text = this.rng.randomElement(ASSISTANT_FRAGMENTS);

    // Pad to target length
    while (text.length < actualChars) {
      text += ` ${this.rng.randomElement([
        'I\'ve analyzed the code structure and identified the key areas to modify.',
        'The implementation follows the established patterns in the codebase.',
        'I\'ll make sure to preserve the existing functionality while adding the new feature.',
        'Let me show you the specific changes I\'m making:',
        'This approach ensures maintainability and follows best practices.',
        'I\'ve considered potential edge cases and added appropriate handling.',
        'The tests will verify that the changes work as expected.',
        'Here\'s my analysis of the current implementation:',
      ])}`;
    }

    content.push({
      type: 'text',
      text: text.slice(0, actualChars),
    });

    // Include tool call if requested
    if (includeToolCall) {
      const toolName = this.rng.randomElement(SAMPLE_TOOLS);
      content.push({
        type: 'tool_use',
        id: `tool_${turn}_${this.rng.randomInt(1000, 9999)}`,
        name: toolName,
        arguments: this.generateToolArguments(toolName),
      });
    }

    return {
      role: 'assistant',
      content,
      usage: {
        inputTokens: this.rng.randomInt(1000, 5000),
        outputTokens: this.rng.randomInt(500, 2000),
      },
      stopReason: includeToolCall ? 'tool_use' : 'end_turn',
    };
  }

  private generateToolResultMessage(turn: number): ToolResultMessage {
    const targetChars = this.config.avgToolResultTokens * CHARS_PER_TOKEN;
    const variance = this.rng.randomInt(-50, 100);
    const actualChars = Math.max(50, targetChars + variance * CHARS_PER_TOKEN);

    // Generate realistic tool output
    let content = this.rng.randomElement([
      'File contents:\n```typescript\n// Sample code content\nexport function example() {\n  return "value";\n}\n```',
      'Command output:\n✓ Tests passed (12 passing, 0 failing)\n✓ Linting complete\n✓ Build successful',
      'Search results:\nFound 5 matches in 3 files:\n- src/utils.ts:42\n- src/helpers.ts:17\n- tests/utils.test.ts:8',
      'File written successfully.\nPath: /src/components/NewComponent.tsx\nSize: 2.4 KB',
      'Edit applied successfully.\nLines changed: 15\nNew content verified.',
    ]);

    // Pad if needed
    while (content.length < actualChars) {
      content += '\n' + this.generateCodeBlock();
    }

    return {
      role: 'toolResult',
      toolCallId: `tool_${turn}_${this.rng.randomInt(1000, 9999)}`,
      content: content.slice(0, actualChars),
    };
  }

  private generateToolArguments(toolName: string): Record<string, unknown> {
    switch (toolName) {
      case 'Read':
      case 'Write':
        return { file_path: this.rng.randomElement(SAMPLE_FILES) };
      case 'Edit':
        return {
          file_path: this.rng.randomElement(SAMPLE_FILES),
          old_string: 'const old = true;',
          new_string: 'const new = false;',
        };
      case 'Grep':
        return {
          pattern: this.rng.randomElement(['TODO', 'FIXME', 'function', 'export', 'import']),
          path: '/src',
        };
      case 'Glob':
        return { pattern: '**/*.ts' };
      case 'Bash':
        return { command: 'npm test' };
      default:
        return {};
    }
  }

  private generateThinkingContent(): string {
    return this.rng.randomElement([
      'Let me analyze the requirements and identify the best approach.',
      'I need to consider the existing architecture and how this change fits.',
      'Breaking down the task into smaller steps for systematic implementation.',
      'Reviewing the codebase patterns to ensure consistency.',
    ]);
  }

  private generateCodeBlock(): string {
    return `\`\`\`typescript
// ${this.rng.randomElement(['Component', 'Service', 'Utility', 'Test'])} implementation
export ${this.rng.randomElement(['function', 'class', 'const'])} ${this.rng.randomElement(['handler', 'processor', 'manager', 'helper'])}() {
  ${this.rng.randomElement(['return', 'await', 'const result ='])} ${this.rng.randomElement(['true', 'false', '"value"', '42'])};
}
\`\`\``;
  }

  // ===========================================================================
  // Token Estimation (matches token-estimator.ts logic)
  // ===========================================================================

  private estimateTokens(message: Message): number {
    let chars = 0;

    // Role overhead
    chars += (message.role?.length ?? 0) + 10;

    // Content
    if (message.role === 'toolResult') {
      const content = (message as ToolResultMessage).content;
      chars += typeof content === 'string' ? content.length : 0;
    } else if (typeof message.content === 'string') {
      chars += message.content.length;
    } else if (Array.isArray(message.content)) {
      for (const block of message.content) {
        chars += this.estimateBlockChars(block);
      }
    }

    return Math.ceil(chars / CHARS_PER_TOKEN);
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

    if (b.type === 'thinking' && typeof b.thinking === 'string') {
      return b.thinking.length;
    }

    if (b.type === 'tool_use') {
      let chars = (b.name as string)?.length ?? 0;
      chars += JSON.stringify(b.arguments ?? {}).length;
      return chars + 20;
    }

    if (b.type === 'tool_result') {
      if (typeof b.content === 'string') {
        return b.content.length + 20;
      }
      return JSON.stringify(b.content ?? '').length + 20;
    }

    return JSON.stringify(block).length;
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create a context simulator for testing.
 */
export function createContextSimulator(config: SimulatorConfig): ContextSimulator {
  return new ContextSimulator(config);
}
