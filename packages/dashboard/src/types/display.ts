/**
 * @fileoverview Display-oriented type definitions for the dashboard
 *
 * These types are optimized for UI rendering and extend the base event types
 * with computed display properties.
 */

import type { SessionId, EventId, EventType, SessionEvent } from '@tron/agent';

/**
 * Timeline entry representing an event in the session timeline
 */
export interface TimelineEntry {
  /** The underlying event */
  event: SessionEvent;
  /** Display-friendly label for the event type */
  typeLabel: string;
  /** Computed display time (relative or absolute) */
  displayTime: string;
  /** Whether this entry should be collapsed by default */
  collapsible: boolean;
  /** Icon identifier for the event type */
  icon: TimelineIcon;
  /** Severity level for styling */
  severity: 'info' | 'success' | 'warning' | 'error';
}

/**
 * Icon identifiers for timeline entries
 */
export type TimelineIcon =
  | 'message-user'
  | 'message-assistant'
  | 'message-system'
  | 'tool-call'
  | 'tool-result'
  | 'session-start'
  | 'session-end'
  | 'config'
  | 'error'
  | 'compact'
  | 'subagent'
  | 'hook'
  | 'default';

/**
 * Event type categories for filtering
 */
export type EventCategory =
  | 'message'
  | 'tool'
  | 'session'
  | 'config'
  | 'error'
  | 'system';

/**
 * Mapping from EventType to EventCategory
 */
export function getEventCategory(type: EventType): EventCategory {
  if (type.startsWith('message.')) return 'message';
  if (type.startsWith('tool.')) return 'tool';
  if (type.startsWith('session.')) return 'session';
  if (type.startsWith('config.')) return 'config';
  if (type.startsWith('error.')) return 'error';
  return 'system';
}

/**
 * Get display label for an event type
 */
export function getEventTypeLabel(type: EventType): string {
  const labels: Record<string, string> = {
    'session.start': 'Session Started',
    'session.end': 'Session Ended',
    'session.fork': 'Session Forked',
    'session.branch': 'Session Branched',
    'message.user': 'User Message',
    'message.assistant': 'Assistant Message',
    'message.system': 'System Message',
    'message.deleted': 'Message Deleted',
    'tool.call': 'Tool Call',
    'tool.result': 'Tool Result',
    'config.model_switch': 'Model Switched',
    'config.prompt_update': 'Prompt Updated',
    'config.reasoning_level': 'Reasoning Level Changed',
    'error.agent': 'Agent Error',
    'error.tool': 'Tool Error',
    'error.provider': 'Provider Error',
    'compact.boundary': 'Compaction',
    'compact.summary': 'Summary',
    'stream.turn_start': 'Turn Started',
    'stream.turn_end': 'Turn Ended',
    'subagent.spawned': 'Subagent Spawned',
    'subagent.status_update': 'Subagent Status',
    'subagent.completed': 'Subagent Completed',
    'subagent.failed': 'Subagent Failed',
    'hook.triggered': 'Hook Triggered',
    'hook.completed': 'Hook Completed',
    'hook.background_started': 'Background Hook Started',
    'hook.background_completed': 'Background Hook Completed',
    'todo.write': 'Todo Updated',
    'turn.failed': 'Turn Failed',
    'rules.loaded': 'Rules Loaded',
    'context.cleared': 'Context Cleared',
    'plan.mode_entered': 'Plan Mode Entered',
    'plan.mode_exited': 'Plan Mode Exited',
    'plan.created': 'Plan Created',
  };
  return labels[type] ?? type;
}

/**
 * Get icon identifier for an event type
 */
export function getEventIcon(type: EventType): TimelineIcon {
  if (type === 'message.user') return 'message-user';
  if (type === 'message.assistant') return 'message-assistant';
  if (type === 'message.system') return 'message-system';
  if (type === 'tool.call') return 'tool-call';
  if (type === 'tool.result') return 'tool-result';
  if (type === 'session.start') return 'session-start';
  if (type === 'session.end') return 'session-end';
  if (type.startsWith('config.')) return 'config';
  if (type.startsWith('error.')) return 'error';
  if (type.startsWith('compact.')) return 'compact';
  if (type.startsWith('subagent.')) return 'subagent';
  if (type.startsWith('hook.')) return 'hook';
  return 'default';
}

/**
 * Get severity level for an event type
 */
export function getEventSeverity(type: EventType): TimelineEntry['severity'] {
  if (type.startsWith('error.') || type === 'turn.failed' || type === 'subagent.failed') {
    return 'error';
  }
  if (type === 'session.end' || type === 'subagent.completed') {
    return 'success';
  }
  if (type.startsWith('config.') || type.startsWith('compact.')) {
    return 'warning';
  }
  return 'info';
}

/**
 * Filter configuration for event list
 */
export interface EventFilter {
  /** Event types to include (empty = all) */
  types: EventType[];
  /** Event categories to include */
  categories: EventCategory[];
  /** Text search query */
  search: string;
  /** Show only errors */
  errorsOnly: boolean;
}

/**
 * Default filter configuration
 */
export const defaultEventFilter: EventFilter = {
  types: [],
  categories: [],
  search: '',
  errorsOnly: false,
};
