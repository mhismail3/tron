/**
 * @fileoverview Subagents module exports
 *
 * Provides sub-agent tracking and management functionality.
 */

export {
  SubAgentTracker,
  createSubAgentTracker,
  type TrackedSubagent,
  type SubagentStatus,
  type SubagentTrackingEvent,
  type SubagentResult,
  type SubagentCompletionCallback,
} from './subagent-tracker.js';
