/**
 * @fileoverview Tests for SessionList component
 */

import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { SessionList } from '../SessionList.js';
import type { DashboardSessionSummary } from '../../../types/session.js';
import type { SessionId, WorkspaceId } from '@tron/agent';

describe('SessionList', () => {
  const mockSessions: DashboardSessionSummary[] = [
    createMockSession('sess_1', 'Session One'),
    createMockSession('sess_2', 'Session Two'),
    createMockSession('sess_3', null),
  ];

  it('renders loading state', () => {
    render(<SessionList sessions={[]} loading={true} />);
    expect(screen.getByRole('status')).toBeInTheDocument();
  });

  it('renders empty state when no sessions', () => {
    render(<SessionList sessions={[]} loading={false} />);
    expect(screen.getByText(/no sessions/i)).toBeInTheDocument();
  });

  it('renders error state', () => {
    render(<SessionList sessions={[]} loading={false} error="Failed to load" />);
    expect(screen.getByText(/failed to load/i)).toBeInTheDocument();
  });

  it('renders list of sessions', () => {
    render(<SessionList sessions={mockSessions} loading={false} />);

    expect(screen.getByText('Session One')).toBeInTheDocument();
    expect(screen.getByText('Session Two')).toBeInTheDocument();
  });

  it('calls onSelect when session is clicked', () => {
    const onSelect = vi.fn();
    render(<SessionList sessions={mockSessions} loading={false} onSelect={onSelect} />);

    fireEvent.click(screen.getByText('Session One'));
    expect(onSelect).toHaveBeenCalledWith('sess_1');
  });

  it('highlights selected session', () => {
    render(
      <SessionList
        sessions={mockSessions}
        loading={false}
        selectedId={'sess_2' as SessionId}
      />
    );

    const selectedCard = screen.getByText('Session Two').closest('.session-card');
    expect(selectedCard).toHaveClass('session-card-selected');
  });
});

function createMockSession(id: string, title: string | null): DashboardSessionSummary {
  return {
    id: id as SessionId,
    workspaceId: 'ws_test' as WorkspaceId,
    title,
    workingDirectory: '/test/project',
    model: 'claude-sonnet-4-20250514',
    createdAt: new Date().toISOString(),
    lastActivityAt: new Date().toISOString(),
    endedAt: null,
    isEnded: false,
    eventCount: 10,
    messageCount: 5,
    turnCount: 2,
    totalInputTokens: 1000,
    totalOutputTokens: 500,
    lastTurnInputTokens: 500,
    totalCost: 0.05,
    totalCacheReadTokens: 0,
    totalCacheCreationTokens: 0,
    lastUserPrompt: 'Hello there',
    lastAssistantResponse: 'Hi!',
    spawningSessionId: null,
    spawnType: null,
    spawnTask: null,
    tags: [],
  };
}
