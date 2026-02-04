/**
 * @fileoverview Focused Event Handlers
 *
 * Exports all event handlers extracted from AgentEventHandler.
 * Each handler is responsible for a specific category of events.
 *
 * ## Handler Categories
 *
 * - **TurnEventHandler**: Turn lifecycle (turn_start, turn_end, response_complete)
 * - **ToolEventHandler**: Tool execution (tool_use_batch, tool_execution_start/end)
 * - **StreamingEventHandler**: Real-time streaming (message_update, toolcall_delta, thinking_*)
 * - **LifecycleEventHandler**: Agent lifecycle (agent_start/end, api_retry, interrupted)
 * - **CompactionEventHandler**: Context compaction (compaction_complete)
 * - **SubagentForwarder**: Subagent event forwarding to parent sessions
 */

// Turn lifecycle
export {
  TurnEventHandler,
  createTurnEventHandler,
  type TurnEventHandlerDeps,
} from './turn-event-handler.js';

// Tool execution
export {
  ToolEventHandler,
  createToolEventHandler,
  type ToolEventHandlerDeps,
  type BlobStore,
} from './tool-event-handler.js';

// Real-time streaming
export {
  StreamingEventHandler,
  createStreamingEventHandler,
  type StreamingEventHandlerDeps,
} from './streaming-event-handler.js';

// Agent lifecycle
export {
  LifecycleEventHandler,
  createLifecycleEventHandler,
  type LifecycleEventHandlerDeps,
} from './lifecycle-event-handler.js';

// Context compaction
export {
  CompactionEventHandler,
  createCompactionEventHandler,
  type CompactionEventHandlerDeps,
} from './compaction-event-handler.js';

// Subagent forwarding
export {
  SubagentForwarder,
  createSubagentForwarder,
  type SubagentForwarderDeps,
} from './subagent-forwarder.js';

// Hook events
export {
  HookEventHandler,
  createHookEventHandler,
  type HookEventHandlerDeps,
  type InternalHookTriggeredEvent,
  type InternalHookCompletedEvent,
} from './hook-event-handler.js';
