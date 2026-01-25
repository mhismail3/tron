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

import type { Message, Tool } from '../types/index.js';
import { getContextLimit } from '../usage/index.js';
import { detectProviderFromModel, type ProviderType } from '../providers/index.js';
import type { Summarizer, ExtractedData } from './summarizer.js';
import {
  buildSystemPrompt,
  requiresToolClarificationMessage,
  getToolClarificationMessage,
  TRON_CORE_PROMPT,
  loadSystemPromptFromFileSync,
} from './system-prompts.js';
import { createLogger } from '../logging/logger.js';
import {
  estimateMessageTokens as estimateMessageTokensUtil,
  estimateRulesTokens as estimateRulesTokensUtil,
  CHARS_PER_TOKEN,
} from './token-estimator.js';

const logger = createLogger('context-manager');

// =============================================================================
// Types
// =============================================================================

export type ThresholdLevel = 'normal' | 'warning' | 'alert' | 'critical' | 'exceeded';

export interface ContextManagerConfig {
  model: string;
  /** Custom system prompt - if not provided, loads from SYSTEM.md or uses TRON_CORE_PROMPT */
  systemPrompt?: string;
  /** Working directory for file operations */
  workingDirectory?: string;
  /** User home directory for loading global SYSTEM.md (defaults to process.env.HOME) */
  userHome?: string;
  tools?: Tool[];
  /** Rules content from AGENTS.md / CLAUDE.md hierarchy */
  rulesContent?: string;
  compaction?: {
    /** Threshold ratio (0-1) to trigger compaction suggestion (default: 0.70) */
    threshold?: number;
    /** Number of recent turns to preserve during compaction (default: 3) */
    preserveRecentTurns?: number;
  };
}

/** Information about a loaded rules file for context auditing */
export interface RulesFileSnapshot {
  /** Absolute path to the file */
  path: string;
  /** Path relative to working directory */
  relativePath: string;
  /** Level in hierarchy: global, project, or directory */
  level: 'global' | 'project' | 'directory';
  /** Depth from project root (-1 for global) */
  depth: number;
}

/** Rules section for context snapshot */
export interface RulesSnapshot {
  /** List of loaded rules files */
  files: RulesFileSnapshot[];
  /** Total number of rules files */
  totalFiles: number;
  /** Estimated token count for merged rules content */
  tokens: number;
}

export interface ContextSnapshot {
  currentTokens: number;
  contextLimit: number;
  usagePercent: number;
  thresholdLevel: ThresholdLevel;
  breakdown: {
    systemPrompt: number;
    tools: number;
    rules: number;
    messages: number;
  };
  /** Loaded rules files (if any) */
  rules?: RulesSnapshot;
}

/**
 * Detailed message info for context auditing
 */
export interface DetailedMessageInfo {
  index: number;
  role: 'user' | 'assistant' | 'toolResult';
  tokens: number;
  /** Summary for display (truncated content or tool info) */
  summary: string;
  /** Full content for expansion */
  content: string;
  /** Event ID for this message (for deletion support) - undefined for synthetic messages */
  eventId?: string;
  /** For tool calls within assistant messages */
  toolCalls?: Array<{
    id: string;
    name: string;
    tokens: number;
    arguments: string;
  }>;
  /** For tool result messages */
  toolCallId?: string;
  isError?: boolean;
}

/**
 * Detailed context snapshot with per-message token breakdown
 */
export interface DetailedContextSnapshot extends ContextSnapshot {
  messages: DetailedMessageInfo[];
  /** Effective system-level context sent to the model */
  systemPromptContent: string;
  /** Raw tool clarification content if applicable (for debugging) */
  toolClarificationContent?: string;
  toolsContent: string[];
}

export interface PreTurnValidation {
  canProceed: boolean;
  needsCompaction: boolean;
  wouldExceedLimit: boolean;
  currentTokens: number;
  estimatedAfterTurn: number;
  contextLimit: number;
}

export interface CompactionPreview {
  tokensBefore: number;
  tokensAfter: number;
  compressionRatio: number;
  preservedTurns: number;
  summarizedTurns: number;
  summary: string;
  extractedData?: ExtractedData;
}

export interface CompactionResult {
  success: boolean;
  tokensBefore: number;
  tokensAfter: number;
  compressionRatio: number;
  summary: string;
  extractedData?: ExtractedData;
}

export interface ProcessedToolResult {
  toolCallId: string;
  content: string;
  truncated: boolean;
  originalSize?: number;
}

export interface ExportedState {
  model: string;
  systemPrompt: string;
  tools: Tool[];
  messages: Message[];
}

// =============================================================================
// Threshold Configuration
// =============================================================================

const THRESHOLDS = {
  warning: 0.50,   // 50% - yellow zone
  alert: 0.70,     // 70% - orange zone, suggest compaction
  critical: 0.85,  // 85% - red zone, block new turns
  exceeded: 0.95,  // 95% - hard limit
};

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
  private messages: Message[];
  private tokenCache: WeakMap<Message, number>;
  private compactionConfig: {
    threshold: number;
    preserveRecentTurns: number;
  };
  private onCompactionNeededCallback?: () => void;
  /** Rules content from AGENTS.md / CLAUDE.md hierarchy */
  private rulesContent: string | undefined;

  // Cached values for performance
  private cachedSystemPromptTokens: number | null = null;
  private cachedToolsTokens: number | null = null;

  /**
   * API-reported context token count from model response.
   * This is the ground truth from the actual tokenizer, set after each turn.
   * When available, this is preferred over our char/4 estimates.
   */
  private lastApiContextTokens: number = 0;

  constructor(config: ContextManagerConfig) {
    this.model = config.model;
    this.providerType = detectProviderFromModel(config.model);
    this.contextLimit = getContextLimit(config.model);
    this.workingDirectory = config.workingDirectory ?? process.cwd();
    this.tools = config.tools ?? [];
    this.rulesContent = config.rulesContent;
    this.messages = [];
    this.tokenCache = new WeakMap();
    this.compactionConfig = {
      threshold: config.compaction?.threshold ?? 0.70,
      preserveRecentTurns: config.compaction?.preserveRecentTurns ?? 3,
    };

    // Load system prompt with priority: programmatic > file-based > hardcoded
    // Note: Check for undefined, not truthiness, so empty string '' is honored
    if (config.systemPrompt !== undefined) {
      // Explicit programmatic override takes highest priority
      this.customSystemPrompt = config.systemPrompt;
    } else {
      // Try loading from SYSTEM.md files
      const loaded = loadSystemPromptFromFileSync({
        workingDirectory: this.workingDirectory,
        userHome: config.userHome,
      });
      if (loaded) {
        this.customSystemPrompt = loaded.content;
      } else {
        // No explicit prompt and no file found - will use TRON_CORE_PROMPT
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
    this.messages.push(message);
    // Pre-compute and cache token estimate
    this.tokenCache.set(message, this.estimateMessageTokens(message));
  }

  /**
   * Replace all messages.
   */
  setMessages(messages: Message[]): void {
    this.messages = [...messages];
    // Reset API tokens since message set changed - estimate until next turn
    this.lastApiContextTokens = 0;
    // Rebuild token cache
    for (const msg of this.messages) {
      this.tokenCache.set(msg, this.estimateMessageTokens(msg));
    }
  }

  /**
   * Get all messages (defensive copy).
   */
  getMessages(): Message[] {
    return [...this.messages];
  }

  /**
   * Clear all messages from context.
   * System prompt and tools are preserved.
   */
  clearMessages(): void {
    this.messages = [];
    // Reset API tokens so estimate is used until next turn completes
    this.lastApiContextTokens = 0;
    // Token cache will be rebuilt on next add
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
    // Invalidate system prompt cache since rules affect total size
    this.cachedSystemPromptTokens = null;
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
    this.cachedSystemPromptTokens = null; // Invalidate cache
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
   * Returns API-reported tokens (ground truth from model's tokenizer).
   * Returns 0 before first turn completes - this is intentional for UI consistency.
   */
  getCurrentTokens(): number {
    return this.lastApiContextTokens;
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
    return this.lastApiContextTokens;
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
    // For UI display: use API tokens (0 if no data) to match progress bar
    // This ensures Context Manager sheet shows same "tokens remaining" as progress bar
    const currentTokens = this.lastApiContextTokens;

    return {
      currentTokens,
      contextLimit: this.contextLimit,
      usagePercent: currentTokens / this.contextLimit,
      thresholdLevel: this.getThresholdLevel(currentTokens),
      // Always show breakdown estimates for informational purposes.
      // These are approximations - currentTokens (API value) is ground truth.
      breakdown: {
        systemPrompt: this.estimateSystemPromptTokens(),
        tools: this.estimateToolsTokens(),
        rules: this.estimateRulesTokens(),
        messages: this.getMessagesTokens(),
      },
    };
  }

  /**
   * Get a detailed snapshot with per-message token breakdown.
   */
  getDetailedSnapshot(): DetailedContextSnapshot {
    const snapshot = this.getSnapshot();
    const detailedMessages: DetailedMessageInfo[] = [];

    for (let i = 0; i < this.messages.length; i++) {
      const msg = this.messages[i];
      if (!msg) continue;

      const tokens = this.tokenCache.get(msg) ?? this.estimateMessageTokens(msg);

      switch (msg.role) {
        case 'user': {
          const userContent = typeof msg.content === 'string'
            ? msg.content
            : msg.content.map(c => c.type === 'text' ? c.text : '[image]').join('\n');
          detailedMessages.push({
            index: i,
            role: 'user',
            tokens,
            summary: userContent.length > 100 ? userContent.slice(0, 100) + '...' : userContent,
            content: userContent,
          });
          break;
        }
        case 'assistant': {
          // Extract text content and tool calls
          const textParts: string[] = [];
          const toolCalls: NonNullable<DetailedMessageInfo['toolCalls']> = [];

          for (const block of msg.content) {
            if (block.type === 'text') {
              textParts.push(block.text);
            } else if (block.type === 'tool_use') {
              const argsStr = block.arguments ? JSON.stringify(block.arguments, null, 2) : '{}';
              const toolTokens = Math.ceil((block.name.length + argsStr.length) / 4);
              toolCalls.push({
                id: block.id,
                name: block.name,
                tokens: toolTokens,
                arguments: argsStr,
              });
            }
          }

          const assistantContent = textParts.join('\n');
          const summary = toolCalls.length > 0
            ? `${toolCalls.map(t => t.name).join(', ')}${assistantContent ? ' + text' : ''}`
            : (assistantContent.length > 100 ? assistantContent.slice(0, 100) + '...' : assistantContent);

          detailedMessages.push({
            index: i,
            role: 'assistant',
            tokens,
            summary,
            content: assistantContent,
            toolCalls: toolCalls.length > 0 ? toolCalls : undefined,
          });
          break;
        }
        case 'toolResult': {
          const resultContent = typeof msg.content === 'string'
            ? msg.content
            : msg.content.map(c => c.type === 'text' ? c.text : '[image]').join('\n');
          detailedMessages.push({
            index: i,
            role: 'toolResult',
            tokens,
            summary: resultContent.length > 100 ? resultContent.slice(0, 100) + '...' : resultContent,
            content: resultContent,
            toolCallId: msg.toolCallId,
            isError: msg.isError,
          });
          break;
        }
      }
    }

    // Use the effective system-level context: tool clarification for Codex, system prompt for others
    const systemPrompt = this.getSystemPrompt();
    const toolClarification = this.getToolClarificationMessage();
    const effectiveSystemContent = toolClarification || systemPrompt;

    return {
      ...snapshot,
      messages: detailedMessages,
      systemPromptContent: effectiveSystemContent,
      toolClarificationContent: toolClarification ?? undefined,
      toolsContent: this.tools.map(t => `${t.name}: ${t.description || 'No description'}`),
    };
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
    const ratio = tokens / this.contextLimit;
    if (ratio >= THRESHOLDS.exceeded) return 'exceeded';
    if (ratio >= THRESHOLDS.critical) return 'critical';
    if (ratio >= THRESHOLDS.alert) return 'alert';
    if (ratio >= THRESHOLDS.warning) return 'warning';
    return 'normal';
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

    // Invalidate system prompt cache since provider may have changed
    this.cachedSystemPromptTokens = null;

    // Check if we now need compaction
    const level = this.getThresholdLevel(this.getCurrentTokens());
    if (
      (level === 'alert' || level === 'critical' || level === 'exceeded') &&
      this.onCompactionNeededCallback
    ) {
      this.onCompactionNeededCallback();
    }
  }

  /**
   * Register callback for when compaction is needed.
   */
  onCompactionNeeded(callback: () => void): void {
    this.onCompactionNeededCallback = callback;
  }

  // ===========================================================================
  // Compaction
  // ===========================================================================

  /**
   * Check if compaction is recommended.
   */
  shouldCompact(): boolean {
    const ratio = this.getCurrentTokens() / this.contextLimit;
    return ratio >= this.compactionConfig.threshold;
  }

  /**
   * Generate a compaction preview without modifying state.
   */
  async previewCompaction(opts: {
    summarizer: Summarizer;
  }): Promise<CompactionPreview> {
    const tokensBefore = this.getCurrentTokens();

    // Calculate how many messages to preserve
    const preserveCount = this.compactionConfig.preserveRecentTurns * 2;

    // Handle preserveCount=0 specially since slice(-0) returns all items
    let messagesToSummarize: Message[];
    let preservedMessages: Message[];

    if (preserveCount === 0) {
      messagesToSummarize = [...this.messages];
      preservedMessages = [];
    } else if (this.messages.length > preserveCount) {
      messagesToSummarize = this.messages.slice(0, -preserveCount);
      preservedMessages = this.messages.slice(-preserveCount);
    } else {
      messagesToSummarize = [];
      preservedMessages = [...this.messages];
    }

    // Generate summary
    const { narrative, extractedData } =
      await opts.summarizer.summarize(messagesToSummarize);

    // Estimate tokens after compaction
    const summaryTokens = Math.ceil(narrative.length / 4);
    const contextMessageTokens = 50; // Overhead for context wrapper
    const ackMessageTokens = 50; // Assistant acknowledgment

    let preservedTokens = 0;
    for (const msg of preservedMessages) {
      preservedTokens += this.tokenCache.get(msg) ?? this.estimateMessageTokens(msg);
    }

    const tokensAfter =
      this.estimateSystemPromptTokens() +
      this.estimateToolsTokens() +
      summaryTokens +
      contextMessageTokens +
      ackMessageTokens +
      preservedTokens;

    return {
      tokensBefore,
      tokensAfter,
      compressionRatio: tokensAfter / tokensBefore,
      preservedTurns: this.compactionConfig.preserveRecentTurns,
      summarizedTurns: Math.floor(messagesToSummarize.length / 2),
      summary: narrative,
      extractedData,
    };
  }

  /**
   * Execute compaction and update messages.
   */
  async executeCompaction(opts: {
    summarizer: Summarizer;
    editedSummary?: string;
  }): Promise<CompactionResult> {
    const tokensBefore = this.getCurrentTokens();

    // Calculate how many messages to preserve
    const preserveCount = this.compactionConfig.preserveRecentTurns * 2;

    // Handle preserveCount=0 specially since slice(-0) returns all items
    let messagesToSummarize: Message[];
    let preserved: Message[];

    if (preserveCount === 0) {
      messagesToSummarize = [...this.messages];
      preserved = [];
    } else if (this.messages.length > preserveCount) {
      messagesToSummarize = this.messages.slice(0, -preserveCount);
      preserved = this.messages.slice(-preserveCount);
    } else {
      messagesToSummarize = [];
      preserved = [...this.messages];
    }

    // Log before summarizer call
    logger.trace('Compaction: calling summarizer', {
      totalMessages: this.messages.length,
      messagesToSummarize: messagesToSummarize.length,
      messagesToPreserve: preserved.length,
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
      ...preserved,
    ];

    // Log message rebuild
    logger.trace('Compaction: rebuilding message list', {
      newMessageCount: newMessages.length,
      preservedMessages: preserved.length,
      summarizedMessages: messagesToSummarize.length,
    });

    // Estimate tokens after compaction (API tokens won't be available until next turn)
    const contextMessageTokens = 50; // Overhead for context wrapper
    const ackMessageTokens = 50; // Assistant acknowledgment
    let preservedTokens = 0;
    for (const msg of preserved) {
      preservedTokens += this.tokenCache.get(msg) ?? this.estimateMessageTokens(msg);
    }
    const tokensAfter =
      this.estimateSystemPromptTokens() +
      this.estimateToolsTokens() +
      summaryTokens +
      contextMessageTokens +
      ackMessageTokens +
      preservedTokens;
    const compressionRatio = tokensAfter / tokensBefore;

    // Update state (this resets API tokens - actual count comes from next turn)
    this.setMessages(newMessages);

    // Log completion with full context breakdown
    logger.trace('Compaction: complete', {
      tokensBefore,
      tokensAfter,
      tokensSaved: tokensBefore - tokensAfter,
      compressionRatio,
      breakdown: this.getSnapshot().breakdown,
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
      messages: [...this.messages],
    };
  }

  // ===========================================================================
  // Private Helpers
  // ===========================================================================

  private estimateSystemPromptTokens(): number {
    if (this.cachedSystemPromptTokens !== null) {
      return this.cachedSystemPromptTokens;
    }
    const systemPrompt = this.getSystemPrompt();
    // Also include tool clarification message for providers that need it
    const toolClarification = this.getToolClarificationMessage();
    const totalLength = systemPrompt.length + (toolClarification?.length ?? 0);
    this.cachedSystemPromptTokens = Math.ceil(totalLength / CHARS_PER_TOKEN);
    return this.cachedSystemPromptTokens;
  }

  private estimateToolsTokens(): number {
    if (this.cachedToolsTokens !== null) {
      return this.cachedToolsTokens;
    }
    this.cachedToolsTokens = Math.ceil(
      this.tools.reduce((sum, t) => sum + JSON.stringify(t).length / CHARS_PER_TOKEN, 0)
    );
    return this.cachedToolsTokens;
  }

  private estimateRulesTokens(): number {
    return estimateRulesTokensUtil(this.rulesContent);
  }

  private getMessagesTokens(): number {
    let total = 0;
    for (const msg of this.messages) {
      // Use cached value if available, otherwise estimate and cache
      let tokens = this.tokenCache.get(msg);
      if (tokens === undefined) {
        tokens = estimateMessageTokensUtil(msg);
        this.tokenCache.set(msg, tokens);
      }
      total += tokens;
    }
    return total;
  }

  private estimateMessageTokens(message: Message): number {
    return estimateMessageTokensUtil(message);
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
