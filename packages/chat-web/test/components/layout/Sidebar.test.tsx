/**
 * @fileoverview Sidebar Component Tests
 *
 * Tests for the sidebar container with session list.
 */

import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { Sidebar } from '../../../src/components/layout/Sidebar.js';
import { ChatProvider } from '../../../src/store/context.js';

function renderWithProvider(ui: React.ReactElement) {
  return render(<ChatProvider>{ui}</ChatProvider>);
}

describe('Sidebar', () => {
  describe('structure', () => {
    it('should render header with title', () => {
      renderWithProvider(<Sidebar />);

      expect(screen.getByText('Sessions')).toBeInTheDocument();
    });

    it('should have sidebar class', () => {
      const { container } = renderWithProvider(<Sidebar />);

      expect(container.querySelector('.sidebar')).toBeInTheDocument();
    });

    it('should render new session button', () => {
      renderWithProvider(<Sidebar />);

      expect(
        screen.getByRole('button', { name: /new session/i }),
      ).toBeInTheDocument();
    });

    it('should render session list area', () => {
      renderWithProvider(<Sidebar />);

      expect(screen.getByRole('listbox')).toBeInTheDocument();
    });
  });

  describe('new session', () => {
    it('should call onNewSession when button clicked', () => {
      const onNewSession = vi.fn();
      renderWithProvider(<Sidebar onNewSession={onNewSession} />);

      fireEvent.click(screen.getByRole('button', { name: /new session/i }));

      expect(onNewSession).toHaveBeenCalled();
    });
  });

  describe('session list', () => {
    const mockSessions = [
      {
        sessionId: 'session_1',
        workingDirectory: '/project/one',
        model: 'claude-sonnet-4-20250514',
        messageCount: 5,
        createdAt: '2025-01-01T10:00:00Z',
        lastActivity: '2025-01-01T12:00:00Z',
        isActive: true,
      },
      {
        sessionId: 'session_2',
        workingDirectory: '/project/two',
        model: 'claude-sonnet-4-20250514',
        messageCount: 10,
        createdAt: '2025-01-01T09:00:00Z',
        lastActivity: '2025-01-01T11:00:00Z',
        isActive: false,
      },
    ];

    it('should render session items', () => {
      renderWithProvider(<Sidebar sessions={mockSessions} />);

      expect(screen.getByText(/one/i)).toBeInTheDocument();
      expect(screen.getByText(/two/i)).toBeInTheDocument();
    });

    it('should highlight active session', () => {
      renderWithProvider(
        <Sidebar sessions={mockSessions} activeSessionId="session_1" />,
      );

      const activeItem = screen.getByText(/one/i).closest('.session-item');
      expect(activeItem).toHaveClass('active');
    });

    it('should call onSessionSelect when session clicked', () => {
      const onSessionSelect = vi.fn();
      renderWithProvider(
        <Sidebar sessions={mockSessions} onSessionSelect={onSessionSelect} />,
      );

      fireEvent.click(screen.getByText(/two/i));

      expect(onSessionSelect).toHaveBeenCalledWith('session_2');
    });

    it('should show message count for each session', () => {
      renderWithProvider(<Sidebar sessions={mockSessions} />);

      expect(screen.getByText(/5 messages/i)).toBeInTheDocument();
      expect(screen.getByText(/10 messages/i)).toBeInTheDocument();
    });

    it('should show empty state when no sessions', () => {
      renderWithProvider(<Sidebar sessions={[]} />);

      expect(screen.getByText(/no sessions/i)).toBeInTheDocument();
    });
  });

  describe('collapsed state', () => {
    it('should apply collapsed class when collapsed', () => {
      const { container } = renderWithProvider(<Sidebar collapsed={true} />);

      expect(container.querySelector('.sidebar')).toHaveClass('collapsed');
    });

    it('should hide session names when collapsed', () => {
      const mockSessions = [
        {
          sessionId: 'session_1',
          workingDirectory: '/project/one',
          model: 'claude-sonnet-4-20250514',
          messageCount: 5,
          createdAt: '2025-01-01T10:00:00Z',
          lastActivity: '2025-01-01T12:00:00Z',
          isActive: true,
        },
      ];

      const { container } = renderWithProvider(
        <Sidebar sessions={mockSessions} collapsed={true} />,
      );

      // When collapsed, session details has sr-only class
      const sessionDetails = container.querySelector('.session-details');
      expect(sessionDetails).toHaveClass('sr-only');
    });
  });

  describe('session actions', () => {
    const mockSessions = [
      {
        sessionId: 'session_1',
        workingDirectory: '/project/one',
        model: 'claude-sonnet-4-20250514',
        messageCount: 5,
        createdAt: '2025-01-01T10:00:00Z',
        lastActivity: '2025-01-01T12:00:00Z',
        isActive: true,
      },
    ];

    it('should show delete button on hover', () => {
      renderWithProvider(<Sidebar sessions={mockSessions} />);

      const sessionItem = screen.getByText(/one/i).closest('.session-item');
      fireEvent.mouseEnter(sessionItem!);

      expect(
        screen.getByRole('button', { name: /delete/i }),
      ).toBeInTheDocument();
    });

    it('should call onSessionDelete when delete clicked', () => {
      const onSessionDelete = vi.fn();
      renderWithProvider(
        <Sidebar sessions={mockSessions} onSessionDelete={onSessionDelete} />,
      );

      const sessionItem = screen.getByText(/one/i).closest('.session-item');
      fireEvent.mouseEnter(sessionItem!);

      fireEvent.click(screen.getByRole('button', { name: /delete/i }));

      expect(onSessionDelete).toHaveBeenCalledWith('session_1');
    });
  });

  describe('accessibility', () => {
    it('should have navigation role', () => {
      renderWithProvider(<Sidebar />);

      expect(screen.getByRole('navigation')).toBeInTheDocument();
    });

    it('should have accessible session list', () => {
      const mockSessions = [
        {
          sessionId: 'session_1',
          workingDirectory: '/project/one',
          model: 'claude-sonnet-4-20250514',
          messageCount: 5,
          createdAt: '2025-01-01T10:00:00Z',
          lastActivity: '2025-01-01T12:00:00Z',
          isActive: true,
        },
      ];

      renderWithProvider(<Sidebar sessions={mockSessions} />);

      const list = screen.getByRole('listbox');
      expect(list).toHaveAttribute('aria-label', 'Sessions');
    });
  });
});
