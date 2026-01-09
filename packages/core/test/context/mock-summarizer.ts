/**
 * @fileoverview Mock Summarizer for Testing
 *
 * Returns deterministic summaries without calling any LLM.
 * Used for testing compaction behavior without burning tokens.
 *
 * @example
 * ```typescript
 * const summarizer = new MockSummarizer();
 * const result = await summarizer.summarize(messages);
 * // result.narrative contains "[MOCK SUMMARY] ..."
 * ```
 */

import type { Message } from '../../types/index.js';
import type { Summarizer, SummaryResult, ExtractedData } from '../summarizer.js';

// =============================================================================
// Mock Summarizer Configuration
// =============================================================================

export interface MockSummarizerConfig {
  /** Simulated delay in milliseconds (default: 0) */
  delay?: number;
  /** Custom narrative prefix (default: "[MOCK SUMMARY]") */
  narrativePrefix?: string;
  /** Override extracted data (for specific test scenarios) */
  overrideExtractedData?: Partial<ExtractedData>;
}

// =============================================================================
// Mock Summarizer
// =============================================================================

/**
 * Mock summarizer that generates deterministic summaries for testing.
 *
 * Features:
 * - No LLM calls - completely deterministic
 * - Extracts real files and tools from messages
 * - Configurable delay to simulate API latency
 * - Custom overrides for specific test scenarios
 */
export class MockSummarizer implements Summarizer {
  private config: Required<Omit<MockSummarizerConfig, 'overrideExtractedData'>> & {
    overrideExtractedData?: Partial<ExtractedData>;
  };

  constructor(config: MockSummarizerConfig = {}) {
    this.config = {
      delay: config.delay ?? 0,
      narrativePrefix: config.narrativePrefix ?? '[MOCK SUMMARY]',
      overrideExtractedData: config.overrideExtractedData,
    };
  }

  async summarize(messages: Message[]): Promise<SummaryResult> {
    // Simulate API latency if configured
    if (this.config.delay > 0) {
      await new Promise(resolve => setTimeout(resolve, this.config.delay));
    }

    const extractedData = this.extractData(messages);
    const narrative = this.generateNarrative(extractedData, messages);

    return { extractedData, narrative };
  }

  private extractData(messages: Message[]): ExtractedData {
    const toolsUsed = this.extractTools(messages);
    const filesModified = this.extractFiles(messages);
    const topics = this.extractTopics(messages);

    const baseData: ExtractedData = {
      currentGoal: `Continue working on the task (${messages.length} messages processed)`,
      completedSteps: [
        `Processed ${messages.length} messages`,
        toolsUsed.length > 0 ? `Used ${toolsUsed.length} tools` : 'No tools used',
      ].filter(Boolean),
      pendingTasks: ['Continue implementation'],
      keyDecisions: messages.length > 5
        ? [{ decision: 'Mock decision', reason: 'Testing purposes' }]
        : [],
      filesModified,
      topicsDiscussed: topics.length > 0 ? topics : ['Testing', 'Development'],
      userPreferences: [],
      importantContext: [
        `Session has ${messages.length} messages`,
        toolsUsed.length > 0 ? `Tools: ${toolsUsed.join(', ')}` : '',
      ].filter(Boolean),
    };

    // Apply overrides if configured
    if (this.config.overrideExtractedData) {
      return { ...baseData, ...this.config.overrideExtractedData };
    }

    return baseData;
  }

  private generateNarrative(data: ExtractedData, messages: Message[]): string {
    const parts: string[] = [this.config.narrativePrefix];

    parts.push(`This session contains ${messages.length} messages discussing implementation.`);

    if (data.filesModified.length > 0) {
      parts.push(`Files: ${data.filesModified.slice(0, 5).join(', ')}.`);
    }

    const toolsUsed = this.extractTools(messages);
    if (toolsUsed.length > 0) {
      parts.push(`Tools used: ${[...new Set(toolsUsed)].join(', ')}.`);
    }

    if (data.keyDecisions.length > 0) {
      parts.push(`Key decisions: ${data.keyDecisions.map(d => d.decision).join(', ')}.`);
    }

    return parts.join(' ');
  }

  private extractTools(messages: Message[]): string[] {
    const tools: string[] = [];

    for (const message of messages) {
      if (message.role === 'assistant' && Array.isArray(message.content)) {
        for (const block of message.content) {
          if (typeof block === 'object' && 'type' in block && block.type === 'tool_use') {
            const toolUse = block as { name: string };
            if (toolUse.name) {
              tools.push(toolUse.name);
            }
          }
        }
      }
    }

    return tools;
  }

  private extractFiles(messages: Message[]): string[] {
    const files = new Set<string>();

    for (const message of messages) {
      if (message.role === 'assistant' && Array.isArray(message.content)) {
        for (const block of message.content) {
          if (typeof block === 'object' && 'type' in block && block.type === 'tool_use') {
            const toolUse = block as { arguments?: Record<string, unknown> };
            if (toolUse.arguments) {
              // Common file path argument names
              const pathKeys = ['file_path', 'path', 'filePath', 'filename'];
              for (const key of pathKeys) {
                if (typeof toolUse.arguments[key] === 'string') {
                  files.add(toolUse.arguments[key] as string);
                }
              }
            }
          }
        }
      }
    }

    return [...files];
  }

  private extractTopics(messages: Message[]): string[] {
    const topics = new Set<string>();

    for (const message of messages) {
      const text = this.extractText(message);
      // Look for programming-related keywords
      const matches = text.match(/\b(function|class|interface|component|module|service|test|build|deploy|error|fix|feature|refactor|implement)\b/gi);
      if (matches) {
        for (const match of matches) {
          topics.add(match.toLowerCase());
        }
      }
    }

    return [...topics].slice(0, 5);
  }

  private extractText(message: Message): string {
    if (message.role === 'toolResult') {
      return typeof message.content === 'string' ? message.content : '';
    }

    if (typeof message.content === 'string') {
      return message.content;
    }

    if (Array.isArray(message.content)) {
      return message.content
        .filter((b): b is { type: 'text'; text: string } =>
          typeof b === 'object' && 'type' in b && b.type === 'text' && 'text' in b
        )
        .map(b => b.text)
        .join(' ');
    }

    return '';
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create a mock summarizer for testing.
 */
export function createMockSummarizer(config?: MockSummarizerConfig): MockSummarizer {
  return new MockSummarizer(config);
}
