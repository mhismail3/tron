/**
 * @fileoverview Individual event item in timeline
 */

import React, { memo } from 'react';
import type { TronSessionEvent, EventId } from '@tron/agent';
import {
  getEventTypeLabel,
  getEventIcon,
  getEventSeverity,
} from '../../types/display.js';
import { formatRelativeTime } from '../../types/session.js';
import { Badge } from '../ui/Badge.js';
import { JsonViewer } from '../ui/JsonViewer.js';

export interface EventItemProps {
  event: TronSessionEvent;
  expanded?: boolean;
  onToggle?: (id: EventId) => void;
  onClick?: (event: TronSessionEvent) => void;
}

const severityToVariant = {
  info: 'default',
  success: 'success',
  warning: 'warning',
  error: 'error',
} as const;

const iconMap: Record<string, string> = {
  'message-user': '›',
  'message-assistant': '✦',
  'message-system': '⚡',
  'tool-call': '◐',
  'tool-result': '✓',
  'session-start': '▶',
  'session-end': '■',
  'config': '⚙',
  'error': '✗',
  'compact': '◆',
  'subagent': '⧉',
  'hook': '⎔',
  'default': '•',
};

export const EventItem = memo(function EventItem({
  event,
  expanded = false,
  onToggle,
  onClick,
}: EventItemProps) {
  const label = getEventTypeLabel(event.type);
  const icon = getEventIcon(event.type);
  const severity = getEventSeverity(event.type);
  const variant = severityToVariant[severity];

  const handleClick = () => {
    onClick?.(event);
  };

  const handleToggle = (e: React.MouseEvent) => {
    e.stopPropagation();
    onToggle?.(event.id as EventId);
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      handleClick();
    }
  };

  return (
    <div
      className={`event-item event-item-${severity} ${expanded ? 'event-item-expanded' : ''}`}
      role="button"
      tabIndex={0}
      onClick={handleClick}
      onKeyDown={handleKeyDown}
    >
      <div className="event-item-header">
        <button
          className="event-item-toggle"
          onClick={handleToggle}
          aria-expanded={expanded}
          aria-label={expanded ? 'Collapse' : 'Expand'}
        >
          {expanded ? '▼' : '▶'}
        </button>

        <span className="event-item-icon" title={label}>
          {iconMap[icon] || iconMap.default}
        </span>

        <Badge variant={variant} size="sm">
          {label}
        </Badge>

        <span className="event-item-time">
          {formatRelativeTime(event.timestamp)}
        </span>

        <span className="event-item-id" title={event.id}>
          {event.id}
        </span>
      </div>

      {expanded && (
        <div className="event-item-content">
          <div className="event-item-meta">
            <div className="event-meta-row">
              <span className="meta-key">Sequence:</span>
              <span className="meta-val">{event.sequence}</span>
            </div>
            <div className="event-meta-row">
              <span className="meta-key">Timestamp:</span>
              <span className="meta-val">{event.timestamp}</span>
            </div>
            {event.parentId && (
              <div className="event-meta-row">
                <span className="meta-key">Parent:</span>
                <span className="meta-val">{event.parentId}</span>
              </div>
            )}
          </div>

          <div className="event-item-payload">
            <span className="payload-label">Payload:</span>
            <JsonViewer data={event.payload} initialExpanded={true} />
          </div>
        </div>
      )}
    </div>
  );
});
