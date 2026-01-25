/**
 * @fileoverview Compaction Test Harness
 *
 * Unified fixture factory for all compaction tests. Provides precise control
 * over context state for deterministic compaction testing without LLM calls.
 *
 * @example
 * ```typescript
 * // Create context at exactly 70% (alert threshold)
 * const harness = CompactionTestHarness.atThreshold('alert');
 * harness.inject();
 * expect(harness.contextManager.shouldCompact()).toBe(true);
 *
 * // Test compaction
 * const result = await harness.executeCompaction();
 * harness.expectTokensLessThan(50000);
 * ```
 */

import {
  ContextManager,
  createContextManager,
  type ThresholdLevel,
  type ContextManagerConfig,
} from '../context-manager.js';
import type { Message } from '../../types/index.js';
import type { Summarizer, SummaryResult } from '../summarizer.js';
import { PreciseTokenGenerator } from './precise-token-generator.js';
import { MockSummarizer } from './mock-summarizer.js';

// =============================================================================
// Types
// =============================================================================

export interface HarnessConfig {
  /** Model to use (default: 'claude-sonnet-4-20250514') */
  model?: string;
  /** Context limit override (default: from model) */
  contextLimit?: number;
  /** Seed for reproducibility */
  seed?: number;
  /** Custom summarizer (default: MockSummarizer) */
  summarizer?: Summarizer;
  /** Compaction config overrides */
  compaction?: {
    threshold?: number;
    preserveRecentTurns?: number;
  };
}

export interface HarnessInstance {
  /** The ContextManager instance */
  contextManager: ContextManager;
  /** The summarizer to use for compaction */
  summarizer: Summarizer;
  /** Generated messages (before injection) */
  messages: Message[];
  /** Target token count */
  targetTokens: number;
  /** Context limit */
  contextLimit: number;
  /** Inject messages into the context manager */
  inject(): void;
  /** Execute compaction using the harness's summarizer */
  executeCompaction(editedSummary?: string): Promise<{
    success: boolean;
    tokensBefore: number;
    tokensAfter: number;
  }>;

  // Assertions
  expectThreshold(level: ThresholdLevel): void;
  expectTokensInRange(min: number, max: number): void;
  expectTokensLessThan(max: number): void;
  expectTokensGreaterThan(min: number): void;
  expectCanCompact(expected: boolean): void;
  expectCanAcceptTurn(expected: boolean): void;
}

// =============================================================================
// Threshold Constants (match ContextManager)
// =============================================================================

const THRESHOLDS: Record<ThresholdLevel, number> = {
  normal: 0,
  warning: 0.50,
  alert: 0.70,
  critical: 0.85,
  exceeded: 0.95,
};

const DEFAULT_CONTEXT_LIMIT = 200_000;

// =============================================================================
// CompactionTestHarness
// =============================================================================

/**
 * Unified fixture factory for compaction tests.
 */
export class CompactionTestHarness {
  /**
   * Create context at exact threshold boundary.
   * For 'warning', creates context at exactly 50% of limit.
   * For 'alert', creates context at exactly 70% of limit.
   * etc.
   */
  static atThreshold(
    level: ThresholdLevel,
    config: HarnessConfig = {}
  ): HarnessInstance {
    const contextLimit = config.contextLimit ?? DEFAULT_CONTEXT_LIMIT;
    const ratio = THRESHOLDS[level];
    const targetTokens = Math.floor(contextLimit * ratio);

    return this.createInstance(targetTokens, contextLimit, config);
  }

  /**
   * Create context near a threshold (for boundary testing).
   * Positive delta = above threshold, negative = below.
   *
   * @example
   * // Just below alert threshold (69.9%)
   * const harness = CompactionTestHarness.nearThreshold('alert', -200);
   *
   * // Just above critical threshold (85.1%)
   * const harness = CompactionTestHarness.nearThreshold('critical', 200);
   */
  static nearThreshold(
    level: ThresholdLevel,
    deltaTokens: number,
    config: HarnessConfig = {}
  ): HarnessInstance {
    const contextLimit = config.contextLimit ?? DEFAULT_CONTEXT_LIMIT;
    const ratio = THRESHOLDS[level];
    const baseTokens = Math.floor(contextLimit * ratio);
    const targetTokens = baseTokens + deltaTokens;

    return this.createInstance(targetTokens, contextLimit, config);
  }

  /**
   * Create context at exact token count.
   */
  static atTokens(
    targetTokens: number,
    config: HarnessConfig = {}
  ): HarnessInstance {
    const contextLimit = config.contextLimit ?? DEFAULT_CONTEXT_LIMIT;
    return this.createInstance(targetTokens, contextLimit, config);
  }

  /**
   * Create context at exact utilization percentage.
   */
  static atUtilization(
    percentage: number,
    config: HarnessConfig = {}
  ): HarnessInstance {
    const contextLimit = config.contextLimit ?? DEFAULT_CONTEXT_LIMIT;
    const targetTokens = Math.floor((percentage / 100) * contextLimit);
    return this.createInstance(targetTokens, contextLimit, config);
  }

  /**
   * Create multiple isolated instances for concurrent testing.
   */
  static createConcurrentSessions(
    count: number,
    config: HarnessConfig = {}
  ): HarnessInstance[] {
    const instances: HarnessInstance[] = [];

    for (let i = 0; i < count; i++) {
      const instanceConfig = {
        ...config,
        seed: (config.seed ?? 42) + i * 1000,
      };
      instances.push(this.atThreshold('critical', instanceConfig));
    }

    return instances;
  }

  // ===========================================================================
  // Private Implementation
  // ===========================================================================

  private static createInstance(
    targetTokens: number,
    contextLimit: number,
    config: HarnessConfig
  ): HarnessInstance {
    const model = config.model ?? 'claude-sonnet-4-20250514';
    const seed = config.seed ?? 42;

    // Create context manager first to get base overhead
    const cmConfig: ContextManagerConfig = {
      model,
      workingDirectory: '/test',
      compaction: config.compaction,
    };
    const contextManager = createContextManager(cmConfig);

    // Calculate base overhead (system prompt + tools + rules)
    // When no messages, getCurrentTokens returns just the overhead
    const baseOverhead = contextManager.getCurrentTokens();

    // Generate messages for (target - overhead) tokens so total matches target
    const messageTokens = Math.max(0, targetTokens - baseOverhead);
    const messages = PreciseTokenGenerator.generateForTokens(messageTokens, {
      seed,
      includeToolCalls: true,
    });

    // Create summarizer
    const summarizer = config.summarizer ?? new MockSummarizer();

    // Create harness instance
    const instance: HarnessInstance = {
      contextManager,
      summarizer,
      messages,
      targetTokens,
      contextLimit,

      inject() {
        contextManager.setMessages(messages);
        // Set API tokens to simulate what happens after a turn completes
        // This is the ground truth mechanism - tokens come from API after each turn
        contextManager.setApiContextTokens(targetTokens);
      },

      async executeCompaction(editedSummary?: string) {
        const result = await contextManager.executeCompaction({
          summarizer,
          editedSummary,
        });
        return {
          success: result.success,
          tokensBefore: result.tokensBefore,
          tokensAfter: result.tokensAfter,
        };
      },

      expectThreshold(level: ThresholdLevel) {
        const snapshot = contextManager.getSnapshot();
        if (snapshot.thresholdLevel !== level) {
          throw new Error(
            `Expected threshold '${level}' but got '${snapshot.thresholdLevel}' ` +
              `(usage: ${(snapshot.usagePercent * 100).toFixed(2)}%)`
          );
        }
      },

      expectTokensInRange(min: number, max: number) {
        const tokens = contextManager.getCurrentTokens();
        if (tokens < min || tokens > max) {
          throw new Error(
            `Expected tokens in range [${min}, ${max}] but got ${tokens}`
          );
        }
      },

      expectTokensLessThan(max: number) {
        const tokens = contextManager.getCurrentTokens();
        if (tokens >= max) {
          throw new Error(`Expected tokens < ${max} but got ${tokens}`);
        }
      },

      expectTokensGreaterThan(min: number) {
        const tokens = contextManager.getCurrentTokens();
        if (tokens <= min) {
          throw new Error(`Expected tokens > ${min} but got ${tokens}`);
        }
      },

      expectCanCompact(expected: boolean) {
        const shouldCompact = contextManager.shouldCompact();
        if (shouldCompact !== expected) {
          throw new Error(
            `Expected shouldCompact() to be ${expected} but got ${shouldCompact}`
          );
        }
      },

      expectCanAcceptTurn(expected: boolean) {
        const validation = contextManager.canAcceptTurn({
          estimatedResponseTokens: 4000,
        });
        if (validation.canProceed !== expected) {
          throw new Error(
            `Expected canAcceptTurn().canProceed to be ${expected} but got ${validation.canProceed}`
          );
        }
      },
    };

    return instance;
  }
}

// =============================================================================
// Summarizer Test Variants
// =============================================================================

/**
 * Summarizer that returns a fixed-size summary for predictable compression testing.
 */
export class FixedSizeSummarizer implements Summarizer {
  constructor(private summaryTokens: number) {}

  async summarize(messages: Message[]): Promise<SummaryResult> {
    const chars = this.summaryTokens * 4 - 20; // Reserve for structure
    const narrative = '[FIXED] ' + 'x'.repeat(Math.max(0, chars));

    return {
      extractedData: {
        currentGoal: 'Fixed test goal',
        completedSteps: ['Fixed step'],
        pendingTasks: [],
        keyDecisions: [],
        filesModified: [],
        topicsDiscussed: ['testing'],
        userPreferences: [],
        importantContext: [],
      },
      narrative,
    };
  }
}

/**
 * Summarizer that throws an error for failure testing.
 */
export class FailingSummarizer implements Summarizer {
  constructor(private errorMessage: string = 'Summarizer failed') {}

  async summarize(): Promise<SummaryResult> {
    throw new Error(this.errorMessage);
  }
}

/**
 * Summarizer that delays response for timeout/race condition testing.
 */
export class SlowSummarizer implements Summarizer {
  private delegate: Summarizer;

  constructor(
    private delayMs: number,
    delegate?: Summarizer
  ) {
    this.delegate = delegate ?? new MockSummarizer();
  }

  async summarize(messages: Message[]): Promise<SummaryResult> {
    await new Promise(resolve => setTimeout(resolve, this.delayMs));
    return this.delegate.summarize(messages);
  }
}

// =============================================================================
// Factory Functions
// =============================================================================

/**
 * Create a harness at a specific threshold.
 */
export function createHarnessAtThreshold(
  level: ThresholdLevel,
  config?: HarnessConfig
): HarnessInstance {
  return CompactionTestHarness.atThreshold(level, config);
}

/**
 * Create a harness at exact token count.
 */
export function createHarnessAtTokens(
  tokens: number,
  config?: HarnessConfig
): HarnessInstance {
  return CompactionTestHarness.atTokens(tokens, config);
}
