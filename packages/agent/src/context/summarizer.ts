/**
 * @fileoverview Summarizer Interface
 *
 * Defines the contract for context summarization. Implementations can use
 * LLM-based summarization (production) or mock summarization (testing).
 */

import type { Message } from '@core/types/index.js';

// =============================================================================
// Extracted Data Structure
// =============================================================================

/**
 * Structured data extracted from conversation context.
 * Used for building the narrative summary and for analytics.
 */
export interface ExtractedData {
  /** The main goal or task being worked on */
  currentGoal: string;
  /** Actions/steps that have been completed */
  completedSteps: string[];
  /** Tasks that were mentioned but not completed */
  pendingTasks: string[];
  /** Key decisions made and their rationale */
  keyDecisions: Array<{ decision: string; reason: string }>;
  /** Files that have been modified */
  filesModified: string[];
  /** Topics that were discussed */
  topicsDiscussed: string[];
  /** User preferences or constraints expressed */
  userPreferences: string[];
  /** Critical context that must be preserved */
  importantContext: string[];
  /** Key reasoning insights from thinking blocks */
  thinkingInsights?: string[];
}

// =============================================================================
// Summary Result
// =============================================================================

/**
 * Result of summarization containing both structured data and narrative.
 */
export interface SummaryResult {
  /** Structured extracted data */
  extractedData: ExtractedData;
  /** Human-readable narrative summary */
  narrative: string;
}

// =============================================================================
// Summarizer Interface
// =============================================================================

/**
 * Interface for context summarization.
 *
 * Implementations:
 * - LLMSummarizer: Uses Claude/GPT to generate intelligent summaries
 * - MockSummarizer: Returns deterministic summaries for testing
 * - KeywordSummarizer: Simple keyword-based extraction (fallback)
 */
export interface Summarizer {
  /**
   * Summarize a sequence of messages.
   *
   * @param messages - Messages to summarize
   * @returns Promise containing extracted data and narrative summary
   */
  summarize(messages: Message[]): Promise<SummaryResult>;
}

// =============================================================================
// Keyword-Based Summarizer (Simple Fallback)
// =============================================================================

/**
 * Simple keyword-based summarizer for when LLM is not available.
 * Extracts key information through pattern matching rather than LLM.
 */
export class KeywordSummarizer implements Summarizer {
  async summarize(messages: Message[]): Promise<SummaryResult> {
    const extractedData = this.extractData(messages);
    const narrative = this.generateNarrative(extractedData, messages.length);

    return { extractedData, narrative };
  }

  private extractData(messages: Message[]): ExtractedData {
    const toolsUsed = new Set<string>();
    const filesModified = new Set<string>();
    const topics = new Set<string>();
    const thinkingInsights: string[] = [];

    for (const message of messages) {
      // Extract tool names and thinking blocks
      if (message.role === 'assistant' && Array.isArray(message.content)) {
        for (const block of message.content) {
          if (typeof block === 'object' && 'type' in block && block.type === 'tool_use') {
            const toolUse = block as { name: string; arguments?: Record<string, unknown> };
            toolsUsed.add(toolUse.name);

            // Extract file paths from common tool arguments
            if (toolUse.arguments) {
              const args = toolUse.arguments;
              if (typeof args.file_path === 'string') {
                filesModified.add(args.file_path);
              }
              if (typeof args.path === 'string') {
                filesModified.add(args.path);
              }
            }
          }
          // Extract thinking block insights
          if (typeof block === 'object' && 'type' in block && block.type === 'thinking') {
            const thinking = (block as { thinking?: string }).thinking;
            if (thinking && thinking.length > 20) {
              // Take the first sentence or first 200 chars as insight
              const firstSentence = thinking.split(/[.!?]\s/)[0];
              if (firstSentence) {
                thinkingInsights.push(firstSentence.slice(0, 200));
              }
            }
          }
        }
      }

      // Extract topics from text content
      const text = this.extractText(message);
      const words = text.toLowerCase().split(/\s+/);
      for (const word of words) {
        if (word.length > 5 && !COMMON_WORDS.has(word) && /^[a-z]+$/.test(word)) {
          topics.add(word);
        }
      }
    }

    return {
      currentGoal: 'Continue working on the task',
      completedSteps: [`Processed ${messages.length} messages`],
      pendingTasks: [],
      keyDecisions: [],
      filesModified: [...filesModified].slice(0, 10),
      topicsDiscussed: [...topics].slice(0, 10),
      userPreferences: [],
      importantContext: toolsUsed.size > 0
        ? [`Tools used: ${[...toolsUsed].join(', ')}`]
        : [],
      thinkingInsights: thinkingInsights.slice(0, 5),
    };
  }

  private generateNarrative(data: ExtractedData, messageCount: number): string {
    const parts: string[] = [];

    if (data.topicsDiscussed.length > 0) {
      parts.push(`Topics discussed: ${data.topicsDiscussed.slice(0, 5).join(', ')}`);
    }

    if (data.filesModified.length > 0) {
      parts.push(`Files modified: ${data.filesModified.slice(0, 5).join(', ')}`);
    }

    if (data.importantContext.length > 0) {
      parts.push(data.importantContext.join('. '));
    }

    if (data.thinkingInsights && data.thinkingInsights.length > 0) {
      parts.push(`Key reasoning: ${data.thinkingInsights.slice(0, 3).join('; ')}`);
    }

    parts.push(`(${messageCount} messages summarized)`);

    return parts.join('\n');
  }

  private extractText(message: Message): string {
    if (message.role === 'toolResult') {
      return typeof message.content === 'string'
        ? message.content
        : '';
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

// Common words to filter out from topic extraction
const COMMON_WORDS = new Set([
  'about', 'after', 'again', 'being', 'could', 'would', 'should', 'these',
  'their', 'there', 'where', 'which', 'while', 'other', 'under', 'thing',
  'things', 'thank', 'thanks', 'please', 'right', 'going', 'really',
  'doing', 'using', 'those', 'before', 'between', 'through', 'during',
  'without', 'within', 'something', 'anything', 'everything', 'nothing',
  'first', 'second', 'third', 'following', 'example', 'create', 'making',
]);
