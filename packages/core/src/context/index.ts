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
  ContextCompactor,
  createContextCompactor,
  type CompactorConfig,
  type CompactResult,
  type BeforeCompactInfo,
  type AfterCompactInfo,
} from './compactor.js';

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
} from './context-manager.js';

export {
  KeywordSummarizer,
  type Summarizer,
  type SummaryResult,
  type ExtractedData,
} from './summarizer.js';

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
  type SystemPromptConfig,
} from './system-prompts.js';
