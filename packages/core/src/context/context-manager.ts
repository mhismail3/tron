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
} from './system-prompts.js';

// =============================================================================
// Types
// =============================================================================

export type ThresholdLevel = 'normal' | 'warning' | 'alert' | 'critical' | 'exceeded';

export interface ContextManagerConfig {
  model: string;
  /** Custom system prompt - if not provided, uses TRON_CORE_PROMPT */
  systemPrompt?: string;
  /** Working directory for file operations */
  workingDirectory?: string;
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
  systemPromptContent: string;
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

  constructor(config: ContextManagerConfig) {
    this.model = config.model;
    this.providerType = detectProviderFromModel(config.model);
    this.contextLimit = getContextLimit(config.model);
    this.customSystemPrompt = config.systemPrompt;
    this.workingDirectory = config.workingDirectory ?? process.cwd();
    this.tools = config.tools ?? [];
    this.rulesContent = config.rulesContent;
    this.messages = [];
    this.tokenCache = new WeakMap();
    this.compactionConfig = {
      threshold: config.compaction?.threshold ?? 0.70,
      preserveRecentTurns: config.compaction?.preserveRecentTurns ?? 3,
    };
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
   */
  getCurrentTokens(): number {
    let total = this.estimateSystemPromptTokens();
    total += this.estimateToolsTokens();
    for (const msg of this.messages) {
      total += this.tokenCache.get(msg) ?? this.estimateMessageTokens(msg);
    }
    return total;
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

  // ===========================================================================
  // Snapshot & Validation
  // ===========================================================================

  /**
   * Get a snapshot of current context state.
   */
  getSnapshot(): ContextSnapshot {
    const currentTokens = this.getCurrentTokens();
    return {
      currentTokens,
      contextLimit: this.contextLimit,
      usagePercent: currentTokens / this.contextLimit,
      thresholdLevel: this.getThresholdLevel(currentTokens),
      breakdown: {
        systemPrompt: this.estimateSystemPromptTokens(),
        tools: this.estimateToolsTokens(),
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

    return {
      ...snapshot,
      messages: detailedMessages,
      systemPromptContent: this.getSystemPrompt(),
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
    const messagesToSummarize =
      this.messages.length > preserveCount
        ? this.messages.slice(0, -preserveCount)
        : [];
    const preservedMessages =
      this.messages.length > preserveCount
        ? this.messages.slice(-preserveCount)
        : this.messages;

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
    const messagesToSummarize =
      this.messages.length > preserveCount
        ? this.messages.slice(0, -preserveCount)
        : [];
    const preserved =
      this.messages.length > preserveCount
        ? this.messages.slice(-preserveCount)
        : this.messages;

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

    // Update state
    this.setMessages(newMessages);
    const tokensAfter = this.getCurrentTokens();

    return {
      success: true,
      tokensBefore,
      tokensAfter,
      compressionRatio: tokensAfter / tokensBefore,
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
    this.cachedSystemPromptTokens = Math.ceil(totalLength / 4);
    return this.cachedSystemPromptTokens;
  }

  private estimateToolsTokens(): number {
    if (this.cachedToolsTokens !== null) {
      return this.cachedToolsTokens;
    }
    this.cachedToolsTokens = Math.ceil(
      this.tools.reduce((sum, t) => sum + JSON.stringify(t).length / 4, 0)
    );
    return this.cachedToolsTokens;
  }

  private getMessagesTokens(): number {
    let total = 0;
    for (const msg of this.messages) {
      total += this.tokenCache.get(msg) ?? this.estimateMessageTokens(msg);
    }
    return total;
  }

  private estimateMessageTokens(message: Message): number {
    // Base overhead for role and structure
    let chars = (message.role?.length ?? 0) + 10;

    if (message.role === 'toolResult') {
      // Tool result message
      chars += message.toolCallId.length;
      if (typeof message.content === 'string') {
        chars += message.content.length;
      } else if (Array.isArray(message.content)) {
        for (const block of message.content) {
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

    return Math.ceil(chars / 4);
  }

  private estimateBlockChars(block: unknown): number {
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

    if (b.type === 'image') {
      // Anthropic image tokenization: tokens = (width × height) / 750
      // We estimate in characters (will be divided by 4 later in estimateMessageTokens)
      const source = b.source as Record<string, unknown> | undefined;

      if (source?.type === 'base64' && typeof source.data === 'string') {
        // Base64: estimate dimensions from data size
        // Base64 overhead is ~33%, so actual bytes = length * 0.75
        // JPEG compression ratio ~10:1 for photos, PNG less compressed
        // Use conservative multiplier of 5 for mixed content
        const dataLength = (source.data as string).length;
        const estimatedBytes = dataLength * 0.75;
        const estimatedPixels = estimatedBytes * 5;
        const estimatedTokens = Math.max(85, Math.ceil(estimatedPixels / 750));
        return estimatedTokens * 4; // Convert tokens back to chars
      }

      // URL or unknown: conservative estimate for typical 1024x1024 image (~1400 tokens)
      return 1500 * 4;
    }

    // Unknown type - estimate based on JSON size
    return JSON.stringify(block).length;
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
