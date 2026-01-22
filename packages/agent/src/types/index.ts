/**
 * @fileoverview Public type exports for @tron/core
 */

// Basic content types (used by both messages and tools)
export * from './content.js';

// Memory types
export * from './memory.js';

// Messages
export type {
  TextContent,
  ImageContent,
  ThinkingContent,
  ToolCall,
  UserContent,
  AssistantContent,
  ToolResultContent,
  TokenUsage,
  Cost,
  StopReason,
  UserMessage,
  AssistantMessage,
  ToolResultMessage,
  Message,
  Context,
  Tool,
  // API-format types for persistence and wire format
  ApiToolUseBlock,
  ApiToolResultBlock,
} from './messages.js';

export {
  isUserMessage,
  isAssistantMessage,
  isToolResultMessage,
  isToolCall,
  isTextContent,
  isImageContent,
  isThinkingContent,
  isApiToolResultBlock,
  isApiToolUseBlock,
  extractText,
  extractToolCalls,
  // Conversion utilities for internal ↔ API format
  toApiToolUse,
  fromApiToolUse,
  normalizeToolArguments,
  normalizeToolResultId,
  normalizeIsError,
} from './messages.js';

// Tools
export type {
  ToolParameterSchema,
  ToolParameterProperty,
  ToolResultContentType,
  TronToolResult,
  ToolProgressCallback,
  ToolExecuteFunction,
  TronTool,
} from './tools.js';

export {
  isTronTool,
  textResult,
  errorResult,
  imageResult,
} from './tools.js';

// Events
export type {
  StreamEvent,
  StreamStartEvent,
  TextStartEvent,
  TextDeltaEvent,
  TextEndEvent,
  ThinkingStartEvent,
  ThinkingDeltaEvent,
  ThinkingEndEvent,
  ToolCallStartEvent,
  ToolCallDeltaEvent,
  ToolCallEndEvent,
  DoneEvent,
  ErrorEvent,
  SafetyBlockEvent,
  BaseTronEvent,
  TronEvent,
  TronEventType,
  AgentStartEvent,
  AgentEndEvent,
  AgentInterruptedEvent,
  TurnStartEvent,
  TurnEndEvent,
  MessageUpdateEvent,
  ToolExecutionStartEvent,
  ToolExecutionUpdateEvent,
  ToolExecutionEndEvent,
  HookTriggeredEvent,
  HookCompletedEvent,
  SessionSavedEvent,
  SessionLoadedEvent,
  ContextWarningEvent,
  TronErrorEvent,
} from './events.js';

export {
  isStreamEvent,
  isTronEvent,
  isToolExecutionEvent,
  createBaseEvent,
  agentStartEvent,
  agentEndEvent,
} from './events.js';

// AskUserQuestion
export type {
  AskUserQuestionOption,
  AskUserQuestion,
  AskUserQuestionParams,
  AskUserQuestionAnswer,
  AskUserQuestionResult,
  ValidationResult,
} from './ask-user-question.js';

export {
  validateAskUserQuestionParams,
  isAskUserQuestionComplete,
  createAskUserQuestionResult,
} from './ask-user-question.js';
