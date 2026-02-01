/**
 * @fileoverview Full event detail view
 */

import React, { memo } from 'react';
import type { TronSessionEvent } from '@tron/agent';
import { getEventTypeLabel, getEventSeverity } from '../../types/display.js';
import { Badge } from '../ui/Badge.js';
import { JsonViewer } from '../ui/JsonViewer.js';

export interface EventDetailProps {
  event: TronSessionEvent;
  onClose?: () => void;
}

const severityToVariant = {
  info: 'default',
  success: 'success',
  warning: 'warning',
  error: 'error',
} as const;

export const EventDetail = memo(function EventDetail({
  event,
  onClose,
}: EventDetailProps) {
  const label = getEventTypeLabel(event.type);
  const severity = getEventSeverity(event.type);
  const variant = severityToVariant[severity];

  return (
    <div className="event-detail">
      <div className="event-detail-header">
        <Badge variant={variant}>{label}</Badge>
        {onClose && (
          <button className="event-detail-close" onClick={onClose} aria-label="Close">
            ×
          </button>
        )}
      </div>

      <div className="event-detail-meta">
        <div className="event-detail-meta-row">
          <span className="meta-key">Event ID:</span>
          <code className="meta-val">{event.id}</code>
        </div>
        <div className="event-detail-meta-row">
          <span className="meta-key">Type:</span>
          <code className="meta-val">{event.type}</code>
        </div>
        <div className="event-detail-meta-row">
          <span className="meta-key">Session ID:</span>
          <code className="meta-val">{event.sessionId}</code>
        </div>
        <div className="event-detail-meta-row">
          <span className="meta-key">Workspace ID:</span>
          <code className="meta-val">{event.workspaceId}</code>
        </div>
        <div className="event-detail-meta-row">
          <span className="meta-key">Parent ID:</span>
          <code className="meta-val">{event.parentId || 'null'}</code>
        </div>
        <div className="event-detail-meta-row">
          <span className="meta-key">Sequence:</span>
          <span className="meta-val">{event.sequence}</span>
        </div>
        <div className="event-detail-meta-row">
          <span className="meta-key">Timestamp:</span>
          <span className="meta-val">{event.timestamp}</span>
        </div>
        <div className="event-detail-meta-row">
          <span className="meta-key">Local Time:</span>
          <span className="meta-val">
            {new Date(event.timestamp).toLocaleString()}
          </span>
        </div>
      </div>

      <div className="event-detail-payload">
        <h3 className="event-detail-section-title">Payload</h3>
        <JsonViewer data={event.payload} initialExpanded={true} />
      </div>
    </div>
  );
});
