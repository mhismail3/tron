/**
 * @fileoverview SessionBrowser Component Tests
 *
 * Tests for the component that shows all past sessions and allows
 * selecting them to view history and fork from any event.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { SessionBrowser } from '../../../src/components/session/SessionBrowser.js';
import type { SessionSummary } from '../../../src/store/types.js';

// =============================================================================
// Mocks
// =============================================================================

const mockRpcCall = vi.fn();
const mockOnSelectSession = vi.fn();
const mockOnForkFromEvent = vi.fn();
const mockOnClose = vi.fn();

function createMockSession(
  id: string,
  title: string,
  overrides: Partial<SessionSummary> = {}
): SessionSummary {
  return {
    id,
    title,
    workingDirectory: '/project',
    model: 'claude-sonnet-4',
    messageCount: 10,
    lastActivity: new Date().toISOString(),
    ...overrides,
  };
}

function createMockEvent(
  id: string,
  type: string,
  parentId: string | null,
  payload: Record<string, unknown> = {}
) {
  return {
    id,
    type,
    parentId,
    sessionId: 'session_1',
    workspaceId: 'ws_1',
    timestamp: new Date().toISOString(),
    sequence: 0,
    payload,
  };
}

describe('SessionBrowser', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe('rendering', () => {
    it('should not render when closed', () => {
      render(
        <SessionBrowser
          isOpen={false}
          onClose={mockOnClose}
          sessions={[]}
          rpcCall={mockRpcCall}
          onSelectSession={mockOnSelectSession}
          onForkFromEvent={mockOnForkFromEvent}
        />
      );

      expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    });

    it('should render dialog when open', () => {
      render(
        <SessionBrowser
          isOpen={true}
          onClose={mockOnClose}
          sessions={[]}
          rpcCall={mockRpcCall}
          onSelectSession={mockOnSelectSession}
          onForkFromEvent={mockOnForkFromEvent}
        />
      );

      expect(screen.getByRole('dialog')).toBeInTheDocument();
      expect(screen.getByText(/session browser/i)).toBeInTheDocument();
    });

    it('should show empty state when no sessions', () => {
      render(
        <SessionBrowser
          isOpen={true}
          onClose={mockOnClose}
          sessions={[]}
          rpcCall={mockRpcCall}
          onSelectSession={mockOnSelectSession}
          onForkFromEvent={mockOnForkFromEvent}
        />
      );

      expect(screen.getByText(/no past sessions/i)).toBeInTheDocument();
    });

    it('should render session list', () => {
      const sessions = [
        createMockSession('session_1', 'Feature Development'),
        createMockSession('session_2', 'Bug Fix'),
        createMockSession('session_3', 'Refactoring'),
      ];

      render(
        <SessionBrowser
          isOpen={true}
          onClose={mockOnClose}
          sessions={sessions}
          rpcCall={mockRpcCall}
          onSelectSession={mockOnSelectSession}
          onForkFromEvent={mockOnForkFromEvent}
        />
      );

      expect(screen.getByText('Feature Development')).toBeInTheDocument();
      expect(screen.getByText('Bug Fix')).toBeInTheDocument();
      expect(screen.getByText('Refactoring')).toBeInTheDocument();
    });

    it('should show session metadata', () => {
      const sessions = [
        createMockSession('session_1', 'Test Session', {
          messageCount: 25,
          model: 'claude-opus-4',
        }),
      ];

      render(
        <SessionBrowser
          isOpen={true}
          onClose={mockOnClose}
          sessions={sessions}
          rpcCall={mockRpcCall}
          onSelectSession={mockOnSelectSession}
          onForkFromEvent={mockOnForkFromEvent}
        />
      );

      expect(screen.getByText(/25 messages/i)).toBeInTheDocument();
      // Component displays "Opus" for claude-opus-4 model
      expect(screen.getByText(/opus/i)).toBeInTheDocument();
    });
  });

  describe('session selection', () => {
    it('should call onSelectSession when session is clicked', () => {
      const sessions = [createMockSession('session_1', 'Test Session')];

      render(
        <SessionBrowser
          isOpen={true}
          onClose={mockOnClose}
          sessions={sessions}
          rpcCall={mockRpcCall}
          onSelectSession={mockOnSelectSession}
          onForkFromEvent={mockOnForkFromEvent}
        />
      );

      fireEvent.click(screen.getByText('Test Session'));

      expect(mockOnSelectSession).toHaveBeenCalledWith('session_1');
    });

    it('should highlight selected session', () => {
      const sessions = [
        createMockSession('session_1', 'Session 1'),
        createMockSession('session_2', 'Session 2'),
      ];

      render(
        <SessionBrowser
          isOpen={true}
          onClose={mockOnClose}
          sessions={sessions}
          rpcCall={mockRpcCall}
          onSelectSession={mockOnSelectSession}
          onForkFromEvent={mockOnForkFromEvent}
          selectedSessionId="session_1"
        />
      );

      const session1 = screen.getByText('Session 1').closest('.session-item');
      expect(session1).toHaveClass('selected');
    });
  });

  describe('session history loading', () => {
    it('should fetch events when session is selected', async () => {
      const sessions = [createMockSession('session_1', 'Test Session')];
      mockRpcCall.mockResolvedValueOnce({
        events: [
          { id: 'evt_1', type: 'session.start', parentId: null, sessionId: 'session_1', workspaceId: 'ws_1', timestamp: new Date().toISOString(), sequence: 0, payload: {} },
          { id: 'evt_2', type: 'message.user', parentId: 'evt_1', sessionId: 'session_1', workspaceId: 'ws_1', timestamp: new Date().toISOString(), sequence: 1, payload: { content: 'Hello' } },
        ],
        hasMore: false,
      });

      render(
        <SessionBrowser
          isOpen={true}
          onClose={mockOnClose}
          sessions={sessions}
          rpcCall={mockRpcCall}
          onSelectSession={mockOnSelectSession}
          onForkFromEvent={mockOnForkFromEvent}
          selectedSessionId="session_1"
        />
      );

      await waitFor(() => {
        expect(mockRpcCall).toHaveBeenCalledWith('events.getHistory', {
          sessionId: 'session_1',
        });
      });
    });

    it('should show loading state while fetching events', async () => {
      const sessions = [createMockSession('session_1', 'Test Session')];
      let resolvePromise: (value: unknown) => void;
      mockRpcCall.mockReturnValue(
        new Promise((resolve) => {
          resolvePromise = resolve;
        })
      );

      render(
        <SessionBrowser
          isOpen={true}
          onClose={mockOnClose}
          sessions={sessions}
          rpcCall={mockRpcCall}
          onSelectSession={mockOnSelectSession}
          onForkFromEvent={mockOnForkFromEvent}
          selectedSessionId="session_1"
        />
      );

      expect(screen.getByText(/loading/i)).toBeInTheDocument();

      resolvePromise!({ events: [], hasMore: false });

      await waitFor(() => {
        expect(screen.queryByText(/loading/i)).not.toBeInTheDocument();
      });
    });

    it('should show session tree when events are loaded', async () => {
      const sessions = [createMockSession('session_1', 'Test Session')];
      mockRpcCall.mockResolvedValueOnce({
        events: [
          createMockEvent('evt_1', 'session.start', null, { title: 'Session started' }),
          createMockEvent('evt_2', 'message.user', 'evt_1', { content: 'Hello world' }),
        ],
        hasMore: false,
        headEventId: 'evt_2',
      });

      render(
        <SessionBrowser
          isOpen={true}
          onClose={mockOnClose}
          sessions={sessions}
          rpcCall={mockRpcCall}
          onSelectSession={mockOnSelectSession}
          onForkFromEvent={mockOnForkFromEvent}
          selectedSessionId="session_1"
        />
      );

      await waitFor(() => {
        expect(screen.getByRole('tree')).toBeInTheDocument();
      });
    });
  });

  describe('forking from past session', () => {
    it('should show confirmation and call onForkFromEvent when confirmed', async () => {
      const sessions = [createMockSession('session_1', 'Test Session')];
      mockRpcCall.mockResolvedValueOnce({
        events: [
          createMockEvent('evt_1', 'session.start', null, { title: 'Session started' }),
          createMockEvent('evt_2', 'message.user', 'evt_1', { content: 'Hello' }),
        ],
        hasMore: false,
        headEventId: 'evt_2',
      });

      render(
        <SessionBrowser
          isOpen={true}
          onClose={mockOnClose}
          sessions={sessions}
          rpcCall={mockRpcCall}
          onSelectSession={mockOnSelectSession}
          onForkFromEvent={mockOnForkFromEvent}
          selectedSessionId="session_1"
        />
      );

      await waitFor(() => {
        expect(screen.getByRole('tree')).toBeInTheDocument();
      });

      // Find a tree node (not the head) and hover over it to show actions
      const treeNodes = screen.getAllByRole('treeitem');
      const targetNode = treeNodes[0]; // First node (session.start, not head)

      if (targetNode) {
        // Hover to show action buttons
        fireEvent.mouseEnter(targetNode);

        await waitFor(() => {
          const forkButton = screen.getByTitle('Fork from this point');
          expect(forkButton).toBeInTheDocument();
        });

        // Click the fork button
        const forkButton = screen.getByTitle('Fork from this point');
        fireEvent.click(forkButton);

        // Should show confirmation dialog
        await waitFor(() => {
          expect(screen.getByText(/create new session/i)).toBeInTheDocument();
        });

        // Click confirm button
        const confirmButton = screen.getByRole('button', { name: /create session/i });
        fireEvent.click(confirmButton);

        // Should call onForkFromEvent
        await waitFor(() => {
          expect(mockOnForkFromEvent).toHaveBeenCalledWith('session_1', 'evt_1');
        });
      }
    });

    it('should cancel fork when cancel button is clicked', async () => {
      const sessions = [createMockSession('session_1', 'Test Session')];
      mockRpcCall.mockResolvedValueOnce({
        events: [
          createMockEvent('evt_1', 'session.start', null, { title: 'Session started' }),
          createMockEvent('evt_2', 'message.user', 'evt_1', { content: 'Hello' }),
        ],
        hasMore: false,
        headEventId: 'evt_2',
      });

      render(
        <SessionBrowser
          isOpen={true}
          onClose={mockOnClose}
          sessions={sessions}
          rpcCall={mockRpcCall}
          onSelectSession={mockOnSelectSession}
          onForkFromEvent={mockOnForkFromEvent}
          selectedSessionId="session_1"
        />
      );

      await waitFor(() => {
        expect(screen.getByRole('tree')).toBeInTheDocument();
      });

      // Find a tree node and hover
      const treeNodes = screen.getAllByRole('treeitem');
      const targetNode = treeNodes[0];

      if (targetNode) {
        fireEvent.mouseEnter(targetNode);

        await waitFor(() => {
          expect(screen.getByTitle('Fork from this point')).toBeInTheDocument();
        });

        fireEvent.click(screen.getByTitle('Fork from this point'));

        // Wait for confirmation dialog
        await waitFor(() => {
          expect(screen.getByText(/create new session/i)).toBeInTheDocument();
        });

        // Click cancel button
        const cancelButton = screen.getByRole('button', { name: /cancel/i });
        fireEvent.click(cancelButton);

        // Confirmation should be closed and onForkFromEvent should not be called
        await waitFor(() => {
          expect(screen.queryByText(/create new session/i)).not.toBeInTheDocument();
        });
        expect(mockOnForkFromEvent).not.toHaveBeenCalled();
      }
    });
  });

  describe('filtering and search', () => {
    it('should filter sessions by search query', () => {
      const sessions = [
        createMockSession('session_1', 'Feature Development'),
        createMockSession('session_2', 'Bug Fix'),
        createMockSession('session_3', 'Feature Testing'),
      ];

      render(
        <SessionBrowser
          isOpen={true}
          onClose={mockOnClose}
          sessions={sessions}
          rpcCall={mockRpcCall}
          onSelectSession={mockOnSelectSession}
          onForkFromEvent={mockOnForkFromEvent}
        />
      );

      const searchInput = screen.getByPlaceholderText(/search/i);
      fireEvent.change(searchInput, { target: { value: 'Feature' } });

      expect(screen.getByText('Feature Development')).toBeInTheDocument();
      expect(screen.getByText('Feature Testing')).toBeInTheDocument();
      expect(screen.queryByText('Bug Fix')).not.toBeInTheDocument();
    });

    it('should show no results message when search has no matches', () => {
      const sessions = [createMockSession('session_1', 'Feature Development')];

      render(
        <SessionBrowser
          isOpen={true}
          onClose={mockOnClose}
          sessions={sessions}
          rpcCall={mockRpcCall}
          onSelectSession={mockOnSelectSession}
          onForkFromEvent={mockOnForkFromEvent}
        />
      );

      const searchInput = screen.getByPlaceholderText(/search/i);
      fireEvent.change(searchInput, { target: { value: 'nonexistent' } });

      expect(screen.getByText(/no sessions found/i)).toBeInTheDocument();
    });
  });

  describe('keyboard navigation', () => {
    it('should close on Escape', () => {
      render(
        <SessionBrowser
          isOpen={true}
          onClose={mockOnClose}
          sessions={[]}
          rpcCall={mockRpcCall}
          onSelectSession={mockOnSelectSession}
          onForkFromEvent={mockOnForkFromEvent}
        />
      );

      fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Escape' });

      expect(mockOnClose).toHaveBeenCalled();
    });
  });

  describe('sorting', () => {
    it('should sort sessions by last activity by default', () => {
      const older = new Date(Date.now() - 86400000 * 2).toISOString();
      const newer = new Date(Date.now() - 86400000).toISOString();

      const sessions = [
        createMockSession('session_1', 'Older Session', { lastActivity: older }),
        createMockSession('session_2', 'Newer Session', { lastActivity: newer }),
      ];

      render(
        <SessionBrowser
          isOpen={true}
          onClose={mockOnClose}
          sessions={sessions}
          rpcCall={mockRpcCall}
          onSelectSession={mockOnSelectSession}
          onForkFromEvent={mockOnForkFromEvent}
        />
      );

      const items = screen.getAllByRole('listitem');
      expect(items[0]).toHaveTextContent('Newer Session');
      expect(items[1]).toHaveTextContent('Older Session');
    });
  });

  describe('working directory grouping', () => {
    it('should group sessions by working directory', () => {
      const sessions = [
        createMockSession('session_1', 'Project A Work', {
          workingDirectory: '/projects/a',
        }),
        createMockSession('session_2', 'Project B Work', {
          workingDirectory: '/projects/b',
        }),
        createMockSession('session_3', 'More Project A', {
          workingDirectory: '/projects/a',
        }),
      ];

      render(
        <SessionBrowser
          isOpen={true}
          onClose={mockOnClose}
          sessions={sessions}
          rpcCall={mockRpcCall}
          onSelectSession={mockOnSelectSession}
          onForkFromEvent={mockOnForkFromEvent}
          groupByDirectory={true}
        />
      );

      expect(screen.getByText('/projects/a')).toBeInTheDocument();
      expect(screen.getByText('/projects/b')).toBeInTheDocument();
    });
  });
});
