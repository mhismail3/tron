/**
 * @fileoverview Context module exports
 */

export {
  ContextLoader,
  createContextLoader,
  type ContextLoaderConfig,
  type ContextFile,
  type LoadedContext,
  type ContextSection,
} from './loader.js';

export {
  ContextAudit,
  getCurrentContextAudit,
  createContextAudit,
  clearContextAudit,
  type ContextAuditData,
  type ContextFileEntry,
  type HandoffEntry,
  type HookModification,
  type ToolEntry,
} from './audit.js';

export {
  ContextManager,
  createContextManager,
  type ContextManagerConfig,
  type ContextSnapshot,
  type DetailedContextSnapshot,
  type DetailedMessageInfo,
  type PreTurnValidation,
  type CompactionPreview,
  type CompactionResult,
  type ProcessedToolResult,
  type ExportedState,
  type ThresholdLevel,
  type RulesFileSnapshot,
  type RulesSnapshot,
  type SessionMemoryEntry,
} from './context-manager.js';

export {
  KeywordSummarizer,
  type Summarizer,
  type SummaryResult,
  type ExtractedData,
} from './summarizer.js';

export {
  LLMSummarizer,
  type LLMSummarizerDeps,
} from './llm-summarizer.js';

export {
  TRON_CORE_PROMPT,
  WORKING_DIRECTORY_SUFFIX,
  buildSystemPrompt,
  buildAnthropicSystemPrompt,
  buildOpenAISystemPrompt,
  buildCodexToolClarification,
  buildGoogleSystemPrompt,
  requiresToolClarificationMessage,
  getToolClarificationMessage,
  loadSystemPromptFromFileSync,
  type SystemPromptConfig,
  type LoadedSystemPrompt,
} from './system-prompts.js';

export {
  RulesTracker,
  createRulesTracker,
  type TrackedRulesFile,
  type RulesTrackingEvent,
} from './rules-tracker.js';

export {
  discoverRulesFiles,
  type DiscoveredRulesFile,
  type RulesDiscoveryConfig,
} from './rules-discovery.js';

export {
  RulesIndex,
} from './rules-index.js';

// Token estimation utilities
export {
  estimateBlockTokens,
  estimateImageTokens,
  estimateMessageTokens,
  estimateMessagesTokens,
  estimateSystemTokens,
  estimateSystemPromptTokens,
  estimateToolsTokens,
  estimateRulesTokens,
  CHARS_PER_TOKEN,
  type ImageSource,
} from './token-estimator.js';

// Sub-components (for advanced use cases)
export { MessageStore, createMessageStore, type MessageStoreConfig } from './message-store.js';
export {
  CompactionEngine,
  createCompactionEngine,
  type CompactionEngineConfig,
  type CompactionDeps,
} from './compaction-engine.js';
export {
  ContextSnapshotBuilder,
  createContextSnapshotBuilder,
  type SnapshotDeps,
} from './context-snapshot-builder.js';

// Type re-exports from types.ts
export { THRESHOLDS } from './types.js';
