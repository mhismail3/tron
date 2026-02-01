/**
 * @fileoverview Tests for EventTimeline component
 */

import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { EventTimeline } from '../EventTimeline.js';
import type { TronSessionEvent, SessionId, WorkspaceId, EventId } from '@tron/agent';

describe('EventTimeline', () => {
  const mockEvents = createMockEvents();

  it('renders loading state', () => {
    render(<EventTimeline events={[]} loading={true} />);
    expect(screen.getByRole('status')).toBeInTheDocument();
  });

  it('renders empty state when no events', () => {
    render(<EventTimeline events={[]} loading={false} />);
    expect(screen.getByText(/no events/i)).toBeInTheDocument();
  });

  it('renders list of events', () => {
    render(<EventTimeline events={mockEvents} loading={false} />);

    expect(screen.getByText(/Session Started/i)).toBeInTheDocument();
    expect(screen.getByText(/User Message/i)).toBeInTheDocument();
    expect(screen.getByText(/Assistant Message/i)).toBeInTheDocument();
  });

  it('calls onEventClick when event is clicked', () => {
    const onEventClick = vi.fn();
    render(
      <EventTimeline
        events={mockEvents}
        loading={false}
        onEventClick={onEventClick}
      />
    );

    // Get the event item elements (not the toggle buttons)
    const eventItems = document.querySelectorAll('.event-item');
    fireEvent.click(eventItems[0]);
    expect(onEventClick).toHaveBeenCalledWith(mockEvents[0]);
  });

  it('shows expand/collapse all buttons', () => {
    render(<EventTimeline events={mockEvents} loading={false} />);

    expect(screen.getByText(/Expand All/i)).toBeInTheDocument();
    expect(screen.getByText(/Collapse All/i)).toBeInTheDocument();
  });

  it('calls onExpandAll when expand all is clicked', () => {
    const onExpandAll = vi.fn();
    render(
      <EventTimeline
        events={mockEvents}
        loading={false}
        onExpandAll={onExpandAll}
      />
    );

    fireEvent.click(screen.getByText(/Expand All/i));
    expect(onExpandAll).toHaveBeenCalled();
  });
});

function createMockEvents(): TronSessionEvent[] {
  const sessionId = 'sess_test' as SessionId;
  const workspaceId = 'ws_test' as WorkspaceId;

  return [
    {
      id: 'evt_1' as EventId,
      sessionId,
      workspaceId,
      parentId: null,
      timestamp: new Date().toISOString(),
      sequence: 0,
      type: 'session.start',
      payload: {
        workingDirectory: '/test',
        model: 'claude-sonnet-4-20250514',
      },
    },
    {
      id: 'evt_2' as EventId,
      sessionId,
      workspaceId,
      parentId: 'evt_1' as EventId,
      timestamp: new Date().toISOString(),
      sequence: 1,
      type: 'message.user',
      payload: {
        content: 'Hello',
        turn: 1,
      },
    },
    {
      id: 'evt_3' as EventId,
      sessionId,
      workspaceId,
      parentId: 'evt_2' as EventId,
      timestamp: new Date().toISOString(),
      sequence: 2,
      type: 'message.assistant',
      payload: {
        content: [{ type: 'text', text: 'Hi there!' }],
        turn: 1,
        model: 'claude-sonnet-4-20250514',
        stopReason: 'end_turn',
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
      },
    },
  ] as TronSessionEvent[];
}
