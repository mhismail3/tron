/**
 * @fileoverview Compaction Engine
 *
 * Handles context compaction logic for managing context window limits:
 * - Determining when compaction is needed
 * - Generating compaction previews
 * - Executing compaction with summarization
 *
 * Extracted from ContextManager to provide focused compaction operations.
 */

import type { Message } from '../types/index.js';
import type { Summarizer, ExtractedData } from './summarizer.js';
import type { CompactionPreview, CompactionResult } from './types.js';
import { createLogger } from '../logging/logger.js';

const logger = createLogger('compaction-engine');

// =============================================================================
// Types
// =============================================================================

export interface CompactionEngineConfig {
  /** Threshold ratio (0-1) to trigger compaction suggestion (default: 0.70) */
  threshold: number;
  /** Number of recent turns to preserve during compaction (default: 3) */
  preserveRecentTurns: number;
}

/**
 * Dependencies injected from ContextManager.
 * Allows CompactionEngine to operate on context state without direct coupling.
 */
export interface CompactionDeps {
  /** Get current messages */
  getMessages: () => Message[];
  /** Set messages (replaces all) */
  setMessages: (messages: Message[]) => void;
  /** Get current token count (API-reported) */
  getCurrentTokens: () => number;
  /** Get model's context limit */
  getContextLimit: () => number;
  /** Estimate system prompt tokens */
  estimateSystemPromptTokens: () => number;
  /** Estimate tools tokens */
  estimateToolsTokens: () => number;
  /** Get token count for a specific message */
  getMessageTokens: (msg: Message) => number;
}

// =============================================================================
// CompactionEngine
// =============================================================================

/**
 * Manages context compaction to stay within context window limits.
 *
 * Responsibilities:
 * - Check if compaction is needed based on threshold
 * - Generate compaction previews without modifying state
 * - Execute compaction with summarization
 * - Trigger callbacks when compaction is needed
 */
export class CompactionEngine {
  private config: CompactionEngineConfig;
  private deps: CompactionDeps;
  private onNeededCallback?: () => void;

  constructor(config: CompactionEngineConfig, deps: CompactionDeps) {
    this.config = config;
    this.deps = deps;
  }

  /**
   * Check if compaction is recommended based on current token usage.
   */
  shouldCompact(): boolean {
    const ratio = this.deps.getCurrentTokens() / this.deps.getContextLimit();
    return ratio >= this.config.threshold;
  }

  /**
   * Generate a compaction preview without modifying state.
   */
  async preview(summarizer: Summarizer): Promise<CompactionPreview> {
    const tokensBefore = this.deps.getCurrentTokens();
    const messages = this.deps.getMessages();

    // Calculate how many messages to preserve
    const preserveCount = this.config.preserveRecentTurns * 2;

    // Handle preserveCount=0 specially since slice(-0) returns all items
    const { messagesToSummarize, preservedMessages } = this.splitMessages(
      messages,
      preserveCount
    );

    // Generate summary
    const { narrative, extractedData } = await summarizer.summarize(messagesToSummarize);

    // Estimate tokens after compaction
    const tokensAfter = this.estimateTokensAfterCompaction(
      narrative,
      preservedMessages
    );

    return {
      tokensBefore,
      tokensAfter,
      compressionRatio: tokensAfter / tokensBefore,
      preservedTurns: this.config.preserveRecentTurns,
      summarizedTurns: Math.floor(messagesToSummarize.length / 2),
      summary: narrative,
      extractedData,
    };
  }

  /**
   * Execute compaction and update messages.
   */
  async execute(opts: {
    summarizer: Summarizer;
    editedSummary?: string;
  }): Promise<CompactionResult> {
    const tokensBefore = this.deps.getCurrentTokens();
    const messages = this.deps.getMessages();

    // Calculate how many messages to preserve
    const preserveCount = this.config.preserveRecentTurns * 2;

    // Handle preserveCount=0 specially since slice(-0) returns all items
    const { messagesToSummarize, preservedMessages } = this.splitMessages(
      messages,
      preserveCount
    );

    // Log before summarizer call
    logger.trace('Compaction: calling summarizer', {
      totalMessages: messages.length,
      messagesToSummarize: messagesToSummarize.length,
      messagesToPreserve: preservedMessages.length,
      tokensBefore,
      summarizerId: opts.summarizer?.constructor?.name ?? 'unknown',
      usingEditedSummary: !!opts.editedSummary,
    });

    // Generate or use edited summary
    let summary: string;
    let extractedData: ExtractedData | undefined;

    if (opts.editedSummary) {
      summary = opts.editedSummary;
    } else {
      const result = await opts.summarizer.summarize(messagesToSummarize);
      summary = result.narrative;
      extractedData = result.extractedData;
    }

    // Log summary generated
    const summaryTokens = Math.ceil(summary.length / 4);
    logger.trace('Compaction: summary generated', {
      summaryLength: summary.length,
      summaryTokens,
      hasExtractedData: !!extractedData,
    });

    // Build new message list
    const newMessages: Message[] = [
      {
        role: 'user',
        content: `[Context from earlier in this conversation]\n\n${summary}`,
      },
      {
        role: 'assistant',
        content: [
          {
            type: 'text',
            text: 'I understand the previous context. Let me continue helping you.',
          },
        ],
      },
      ...preservedMessages,
    ];

    // Log message rebuild
    logger.trace('Compaction: rebuilding message list', {
      newMessageCount: newMessages.length,
      preservedMessages: preservedMessages.length,
      summarizedMessages: messagesToSummarize.length,
    });

    // Estimate tokens after compaction (API tokens won't be available until next turn)
    const tokensAfter = this.estimateTokensAfterCompaction(summary, preservedMessages);
    const compressionRatio = tokensAfter / tokensBefore;

    // Update state
    this.deps.setMessages(newMessages);

    // Log completion
    logger.trace('Compaction: complete', {
      tokensBefore,
      tokensAfter,
      tokensSaved: tokensBefore - tokensAfter,
      compressionRatio,
    });

    return {
      success: true,
      tokensBefore,
      tokensAfter,
      compressionRatio,
      summary,
      extractedData,
    };
  }

  /**
   * Register callback for when compaction is needed.
   */
  onNeeded(callback: () => void): void {
    this.onNeededCallback = callback;
  }

  /**
   * Trigger callback if compaction is needed.
   * Called after model switch or other context-affecting operations.
   */
  triggerIfNeeded(): void {
    if (this.shouldCompact() && this.onNeededCallback) {
      this.onNeededCallback();
    }
  }

  // ===========================================================================
  // Private Helpers
  // ===========================================================================

  /**
   * Split messages into those to summarize and those to preserve.
   */
  private splitMessages(
    messages: Message[],
    preserveCount: number
  ): { messagesToSummarize: Message[]; preservedMessages: Message[] } {
    if (preserveCount === 0) {
      return {
        messagesToSummarize: [...messages],
        preservedMessages: [],
      };
    }

    if (messages.length > preserveCount) {
      return {
        messagesToSummarize: messages.slice(0, -preserveCount),
        preservedMessages: messages.slice(-preserveCount),
      };
    }

    return {
      messagesToSummarize: [],
      preservedMessages: [...messages],
    };
  }

  /**
   * Estimate tokens after compaction.
   */
  private estimateTokensAfterCompaction(
    summary: string,
    preservedMessages: Message[]
  ): number {
    const summaryTokens = Math.ceil(summary.length / 4);
    const contextMessageTokens = 50; // Overhead for context wrapper
    const ackMessageTokens = 50; // Assistant acknowledgment

    let preservedTokens = 0;
    for (const msg of preservedMessages) {
      preservedTokens += this.deps.getMessageTokens(msg);
    }

    return (
      this.deps.estimateSystemPromptTokens() +
      this.deps.estimateToolsTokens() +
      summaryTokens +
      contextMessageTokens +
      ackMessageTokens +
      preservedTokens
    );
  }
}

// =============================================================================
// Factory
// =============================================================================

/**
 * Create a new CompactionEngine instance.
 */
export function createCompactionEngine(
  config: CompactionEngineConfig,
  deps: CompactionDeps
): CompactionEngine {
  return new CompactionEngine(config, deps);
}
