/**
 * @fileoverview Context Manager
 *
 * Central management of all context for agent calls:
 * - Message tracking with token estimation
 * - Model-aware context limits
 * - Pre-turn validation
 * - Compaction orchestration
 * - Tool result processing
 * - Model switching with revalidation
 */

import type { Message, Tool } from '@core/types/index.js';
import { getContextLimit } from '@infrastructure/usage/index.js';
import { detectProviderFromModel, type ProviderType } from '@llm/providers/index.js';
import type { Summarizer } from './summarizer.js';
import {
  buildSystemPrompt,
  requiresToolClarificationMessage,
  getToolClarificationMessage,
  TRON_CORE_PROMPT,
  loadSystemPromptFromFileSync,
} from './system-prompts.js';
import {
  estimateMessageTokens as estimateMessageTokensUtil,
  estimateRulesTokens as estimateRulesTokensUtil,
  estimateSystemPromptTokens as estimateSystemPromptTokensUtil,
  estimateToolsTokens as estimateToolsTokensUtil,
} from './token-estimator.js';
import { MessageStore } from './message-store.js';
import { CompactionEngine } from './compaction-engine.js';
import { ContextSnapshotBuilder } from './context-snapshot-builder.js';
import {
  type ThresholdLevel,
  type ContextManagerConfig,
  type ContextSnapshot,
  type DetailedContextSnapshot,
  type PreTurnValidation,
  type CompactionPreview,
  type CompactionResult,
  type ProcessedToolResult,
  type ExportedState,
} from './types.js';

// =============================================================================
// ContextManager
// =============================================================================

/**
 * Central context management for agent calls.
 *
 * Responsibilities:
 * - Track messages and estimate tokens
 * - Provide model-aware context limits
 * - Pre-validate turns before API calls
 * - Orchestrate compaction
 * - Process tool results
 * - Handle model switching
 */
export class ContextManager {
  private model: string;
  private providerType: ProviderType;
  private contextLimit: number;
  private customSystemPrompt: string | undefined;
  private workingDirectory: string;
  private tools: Tool[];
  private messageStore: MessageStore;
  private compactionEngine: CompactionEngine;
  private snapshotBuilder: ContextSnapshotBuilder;
  /** Rules content from AGENTS.md / CLAUDE.md hierarchy */
  private rulesContent: string | undefined;

  // Cached values for performance
  private cachedSystemPromptTokens: number | null = null;
  private cachedToolsTokens: number | null = null;

  /**
   * API-reported context token count from model response.
   * This is the ground truth from the actual tokenizer, set after each turn.
   * When available, this is preferred over our char/4 estimates.
   * null = no API data available (use component estimates as fallback).
   */
  private lastApiContextTokens: number | null = null;

  constructor(config: ContextManagerConfig) {
    this.model = config.model;
    this.providerType = detectProviderFromModel(config.model);
    this.contextLimit = getContextLimit(config.model);
    this.workingDirectory = config.workingDirectory ?? process.cwd();
    this.tools = config.tools ?? [];
    this.rulesContent = config.rulesContent;
    this.messageStore = new MessageStore();

    // Create compaction engine with dependencies injected
    this.compactionEngine = new CompactionEngine(
      {
        threshold: config.compaction?.threshold ?? 0.70,
        preserveRecentTurns: config.compaction?.preserveRecentTurns ?? 5,
      },
      {
        getMessages: () => this.messageStore.get(),
        setMessages: (msgs) => this.setMessages(msgs),
        getCurrentTokens: () => this.getCurrentTokens(),
        getContextLimit: () => this.contextLimit,
        estimateSystemPromptTokens: () => this.estimateSystemPromptTokens(),
        estimateToolsTokens: () => this.estimateToolsTokens(),
        getMessageTokens: (msg) =>
          this.messageStore.getCachedTokens(msg) ?? estimateMessageTokensUtil(msg),
      }
    );

    // Create snapshot builder with dependencies injected
    this.snapshotBuilder = new ContextSnapshotBuilder({
      getCurrentTokens: () => this.getCurrentTokens(),
      getContextLimit: () => this.contextLimit,
      getMessages: () => this.messageStore.get(),
      estimateSystemPromptTokens: () => this.estimateSystemPromptTokens(),
      estimateToolsTokens: () => this.estimateToolsTokens(),
      estimateRulesTokens: () => this.estimateRulesTokens(),
      getMessagesTokens: () => this.getMessagesTokens(),
      getMessageTokens: (msg) =>
        this.messageStore.getCachedTokens(msg) ?? estimateMessageTokensUtil(msg),
      getSystemPrompt: () => this.getSystemPrompt(),
      getToolClarificationMessage: () => this.getToolClarificationMessage(),
      getTools: () => this.tools,
    });

    // Load system prompt with priority: programmatic > file-based > hardcoded
    // Note: Check for undefined, not truthiness, so empty string '' is honored
    if (config.systemPrompt !== undefined) {
      // Explicit programmatic override takes highest priority
      this.customSystemPrompt = config.systemPrompt;
    } else {
      // Try loading from project .tron/SYSTEM.md
      const loaded = loadSystemPromptFromFileSync({
        workingDirectory: this.workingDirectory,
      });
      if (loaded) {
        this.customSystemPrompt = loaded.content;
      } else {
        // No explicit prompt and no project SYSTEM.md - will use TRON_CORE_PROMPT
        this.customSystemPrompt = undefined;
      }
    }
  }

  // ===========================================================================
  // Message Management
  // ===========================================================================

  /**
   * Add a message to the context.
   */
  addMessage(message: Message): void {
    this.messageStore.add(message);
  }

  /**
   * Replace all messages.
   */
  setMessages(messages: Message[]): void {
    this.messageStore.set(messages);
    // Reset API tokens since message set changed — fall back to estimates until next turn
    this.lastApiContextTokens = null;
  }

  /**
   * Get all messages (defensive copy).
   */
  getMessages(): Message[] {
    return this.messageStore.get();
  }

  /**
   * Clear all messages from context.
   * System prompt and tools are preserved.
   */
  clearMessages(): void {
    this.messageStore.clear();
    // Reset API tokens — fall back to estimates until next turn completes
    this.lastApiContextTokens = null;
  }

  /**
   * Get the system prompt built for the current provider.
   * For most providers, this returns the Tron system prompt.
   * For OpenAI Codex, returns empty string (Tron context is via tool clarification).
   */
  getSystemPrompt(): string {
    return buildSystemPrompt({
      providerType: this.providerType,
      workingDirectory: this.workingDirectory,
      customPrompt: this.customSystemPrompt,
    });
  }

  /**
   * Get the raw/custom system prompt without provider adaptation.
   */
  getRawSystemPrompt(): string {
    return this.customSystemPrompt ?? TRON_CORE_PROMPT;
  }

  /**
   * Get tool clarification message for providers that need it (e.g., OpenAI Codex).
   * Returns null if the provider uses standard system prompts.
   */
  getToolClarificationMessage(): string | null {
    return getToolClarificationMessage({
      providerType: this.providerType,
      workingDirectory: this.workingDirectory,
      customPrompt: this.customSystemPrompt,
    });
  }

  /**
   * Check if current provider requires tool clarification instead of system prompt.
   */
  requiresToolClarification(): boolean {
    return requiresToolClarificationMessage(this.providerType);
  }

  /**
   * Get current provider type.
   */
  getProviderType(): ProviderType {
    return this.providerType;
  }

  /**
   * Get working directory.
   */
  getWorkingDirectory(): string {
    return this.workingDirectory;
  }

  /**
   * Set rules content from AGENTS.md / CLAUDE.md hierarchy.
   * Invalidates cached token counts.
   */
  setRulesContent(content: string | undefined): void {
    this.rulesContent = content;
    this.invalidateSystemPromptCache();
  }

  /**
   * Get rules content from AGENTS.md / CLAUDE.md hierarchy.
   */
  getRulesContent(): string | undefined {
    return this.rulesContent;
  }

  /**
   * Set working directory (updates cached system prompt tokens).
   */
  setWorkingDirectory(dir: string): void {
    this.workingDirectory = dir;
    this.invalidateSystemPromptCache();
  }

  /**
   * Get tools.
   */
  getTools(): Tool[] {
    return [...this.tools];
  }

  // ===========================================================================
  // Token Tracking
  // ===========================================================================

  /**
   * Get current total token count.
   * Returns API-reported tokens when available (ground truth from model's tokenizer).
   * Falls back to sum of component estimates when API data is unavailable
   * (before first turn, after compaction resets messages, after clearMessages).
   */
  getCurrentTokens(): number {
    if (this.lastApiContextTokens !== null) {
      return this.lastApiContextTokens;
    }
    return this.estimateSystemPromptTokens()
      + this.estimateToolsTokens()
      + this.estimateRulesTokens()
      + this.getMessagesTokens();
  }

  /**
   * Get model's context limit.
   */
  getContextLimit(): number {
    return this.contextLimit;
  }

  /**
   * Get current model.
   */
  getModel(): string {
    return this.model;
  }

  /**
   * Set the API-reported context token count.
   * Called after each turn with actual tokenizer count from model API.
   * This value is preferred over estimates when available.
   */
  setApiContextTokens(tokens: number): void {
    this.lastApiContextTokens = tokens;
  }

  /**
   * Get the API-reported context token count (0 if not yet available).
   */
  getApiContextTokens(): number {
    return this.lastApiContextTokens ?? 0;
  }

  // ===========================================================================
  // Snapshot & Validation
  // ===========================================================================

  /**
   * Get a snapshot of current context state.
   * For UI consistency, uses API tokens when available (matches progress bar).
   * Before first turn, shows 0 tokens used (full context remaining).
   */
  getSnapshot(): ContextSnapshot {
    return this.snapshotBuilder.build();
  }

  /**
   * Get a detailed snapshot with per-message token breakdown.
   */
  getDetailedSnapshot(): DetailedContextSnapshot {
    return this.snapshotBuilder.buildDetailed();
  }

  /**
   * Check if a new turn can be accepted.
   */
  canAcceptTurn(opts: { estimatedResponseTokens: number }): PreTurnValidation {
    const currentTokens = this.getCurrentTokens();
    const estimated = currentTokens + opts.estimatedResponseTokens;
    const level = this.getThresholdLevel(currentTokens);

    return {
      canProceed: level !== 'critical' && level !== 'exceeded',
      needsCompaction: level === 'alert' || level === 'critical' || level === 'exceeded',
      wouldExceedLimit: estimated > this.contextLimit,
      currentTokens,
      estimatedAfterTurn: estimated,
      contextLimit: this.contextLimit,
    };
  }

  /**
   * Get threshold level for a token count.
   */
  getThresholdLevel(tokens: number): ThresholdLevel {
    return this.snapshotBuilder.getThresholdLevel(tokens);
  }

  // ===========================================================================
  // Model Switching
  // ===========================================================================

  /**
   * Switch to a different model.
   * Updates provider type, revalidates context, and triggers callback if compaction is needed.
   */
  switchModel(newModel: string): void {
    this.model = newModel;
    this.providerType = detectProviderFromModel(newModel);
    this.contextLimit = getContextLimit(newModel);
    this.invalidateSystemPromptCache();

    // Check if we now need compaction
    this.compactionEngine.triggerIfNeeded();
  }

  /**
   * Register callback for when compaction is needed.
   */
  onCompactionNeeded(callback: () => void): void {
    this.compactionEngine.onNeeded(callback);
  }

  // ===========================================================================
  // Compaction
  // ===========================================================================

  /**
   * Check if compaction is recommended.
   */
  shouldCompact(): boolean {
    return this.compactionEngine.shouldCompact();
  }

  /**
   * Generate a compaction preview without modifying state.
   */
  async previewCompaction(opts: {
    summarizer: Summarizer;
  }): Promise<CompactionPreview> {
    return this.compactionEngine.preview(opts.summarizer);
  }

  /**
   * Execute compaction and update messages.
   */
  async executeCompaction(opts: {
    summarizer: Summarizer;
    editedSummary?: string;
  }): Promise<CompactionResult> {
    return this.compactionEngine.execute(opts);
  }

  // ===========================================================================
  // Tool Result Processing
  // ===========================================================================

  /**
   * Process a tool result, potentially truncating if too large.
   */
  processToolResult(result: {
    toolCallId: string;
    content: string;
  }): ProcessedToolResult {
    const maxSize = this.getMaxToolResultSize();
    if (result.content.length <= maxSize) {
      return { ...result, truncated: false };
    }

    return {
      toolCallId: result.toolCallId,
      content: result.content.slice(0, maxSize) + '\n... [truncated]',
      truncated: true,
      originalSize: result.content.length,
    };
  }

  /**
   * Get maximum tool result size based on remaining context budget.
   * This provides a dynamic ceiling that adapts to current context usage.
   */
  getMaxToolResultSize(): number {
    const currentTokens = this.getCurrentTokens();
    const remainingBudget = this.contextLimit - currentTokens;

    // Reserve tokens for:
    // - Model response: 8,000 tokens (typical response size)
    // - Safety margin: 10% of remaining budget
    const responseReserve = 8_000;
    const safetyMargin = Math.floor(remainingBudget * 0.1);

    const availableTokens = Math.max(
      remainingBudget - responseReserve - safetyMargin,
      2_500  // Minimum 2,500 tokens for tool results
    );

    // Convert to chars (4 chars ~ 1 token), cap at 100k chars (~25k tokens)
    return Math.min(availableTokens * 4, 100_000);
  }

  // ===========================================================================
  // Serialization
  // ===========================================================================

  /**
   * Export state for persistence.
   */
  exportState(): ExportedState {
    return {
      model: this.model,
      systemPrompt: this.getSystemPrompt(),
      tools: [...this.tools],
      messages: this.messageStore.get(),
    };
  }

  // ===========================================================================
  // Private Helpers
  // ===========================================================================

  /**
   * Invalidate cached system prompt tokens.
   * Called when rules content, working directory, or model changes.
   */
  private invalidateSystemPromptCache(): void {
    this.cachedSystemPromptTokens = null;
  }

  private estimateSystemPromptTokens(): number {
    if (this.cachedSystemPromptTokens !== null) {
      return this.cachedSystemPromptTokens;
    }
    this.cachedSystemPromptTokens = estimateSystemPromptTokensUtil(
      this.getSystemPrompt(),
      this.getToolClarificationMessage()
    );
    return this.cachedSystemPromptTokens;
  }

  private estimateToolsTokens(): number {
    if (this.cachedToolsTokens !== null) {
      return this.cachedToolsTokens;
    }
    this.cachedToolsTokens = estimateToolsTokensUtil(this.tools);
    return this.cachedToolsTokens;
  }

  private estimateRulesTokens(): number {
    return estimateRulesTokensUtil(this.rulesContent);
  }

  private getMessagesTokens(): number {
    return this.messageStore.getTokens();
  }
}

// =============================================================================
// Factory
// =============================================================================

/**
 * Create a new ContextManager instance.
 */
export function createContextManager(config: ContextManagerConfig): ContextManager {
  return new ContextManager(config);
}

// =============================================================================
// Type Re-exports (public API)
// =============================================================================

export type {
  ThresholdLevel,
  ContextManagerConfig,
  RulesFileSnapshot,
  RulesSnapshot,
  ContextSnapshot,
  DetailedMessageInfo,
  DetailedContextSnapshot,
  PreTurnValidation,
  CompactionPreview,
  CompactionResult,
  ProcessedToolResult,
  ExportedState,
} from './types.js';
