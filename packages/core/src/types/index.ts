/**
 * @fileoverview Public type exports for @tron/core
 */

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
} from './messages.js';

export {
  isUserMessage,
  isAssistantMessage,
  isToolResultMessage,
  isToolCall,
  isTextContent,
  isImageContent,
  isThinkingContent,
  extractText,
  extractToolCalls,
} from './messages.js';

// Tools
export type {
  ToolParameterSchema,
  ToolParameterProperty,
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
  BaseTronEvent,
  TronEvent,
  TronEventType,
  AgentStartEvent,
  AgentEndEvent,
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
