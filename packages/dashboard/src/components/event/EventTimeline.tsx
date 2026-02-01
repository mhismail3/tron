/**
 * @fileoverview Event timeline component
 */

import React, { memo } from 'react';
import type { TronSessionEvent, EventId } from '@tron/agent';
import { EventItem } from './EventItem.js';
import { Spinner } from '../ui/Spinner.js';

export interface EventTimelineProps {
  events: TronSessionEvent[];
  loading?: boolean;
  error?: string | null;
  expandedIds?: Set<EventId>;
  onEventClick?: (event: TronSessionEvent) => void;
  onToggleExpanded?: (id: EventId) => void;
  onExpandAll?: () => void;
  onCollapseAll?: () => void;
  onLoadMore?: () => void;
  hasMore?: boolean;
}

export const EventTimeline = memo(function EventTimeline({
  events,
  loading = false,
  error = null,
  expandedIds = new Set(),
  onEventClick,
  onToggleExpanded,
  onExpandAll,
  onCollapseAll,
  onLoadMore,
  hasMore = false,
}: EventTimelineProps) {
  if (loading && events.length === 0) {
    return (
      <div className="event-timeline-loading">
        <Spinner size="lg" />
      </div>
    );
  }

  if (error) {
    return (
      <div className="event-timeline-error">
        <span className="error-icon">!</span>
        <span>{error}</span>
      </div>
    );
  }

  if (events.length === 0) {
    return (
      <div className="event-timeline-empty">
        <span>No events found</span>
      </div>
    );
  }

  return (
    <div className="event-timeline">
      <div className="event-timeline-controls">
        <span className="event-timeline-count">
          {events.length} events
        </span>
        <div className="event-timeline-actions">
          <button
            className="event-timeline-btn"
            onClick={onExpandAll}
            disabled={!onExpandAll}
          >
            Expand All
          </button>
          <button
            className="event-timeline-btn"
            onClick={onCollapseAll}
            disabled={!onCollapseAll}
          >
            Collapse All
          </button>
        </div>
      </div>

      <div className="event-timeline-list">
        {events.map((event) => (
          <EventItem
            key={event.id}
            event={event}
            expanded={expandedIds.has(event.id as EventId)}
            onToggle={onToggleExpanded}
            onClick={onEventClick}
          />
        ))}
      </div>

      {hasMore && (
        <div className="event-timeline-load-more">
          <button
            className="event-timeline-btn event-timeline-btn-primary"
            onClick={onLoadMore}
            disabled={loading}
          >
            {loading ? <Spinner size="sm" /> : 'Load More'}
          </button>
        </div>
      )}
    </div>
  );
});
