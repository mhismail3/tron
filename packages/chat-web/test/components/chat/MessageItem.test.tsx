/**
 * @fileoverview MessageItem Component Tests
 *
 * Tests for the terminal-style message display.
 */

import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import { MessageItem } from '../../../src/components/chat/MessageItem.js';
import { ChatProvider } from '../../../src/store/context.js';
import type { DisplayMessage } from '../../../src/store/types.js';

function renderWithProvider(ui: React.ReactElement) {
  return render(<ChatProvider>{ui}</ChatProvider>);
}

function createMessage(
  role: DisplayMessage['role'],
  content: string,
  overrides: Partial<DisplayMessage> = {},
): DisplayMessage {
  return {
    id: `msg_${Date.now()}`,
    role,
    content,
    timestamp: new Date().toISOString(),
    ...overrides,
  };
}

describe('MessageItem', () => {
  describe('structure', () => {
    it('should render message content', () => {
      const message = createMessage('user', 'Hello, Claude!');
      renderWithProvider(<MessageItem message={message} />);

      expect(screen.getByText('Hello, Claude!')).toBeInTheDocument();
    });

    it('should have message-item class', () => {
      const message = createMessage('user', 'Test');
      const { container } = renderWithProvider(<MessageItem message={message} />);

      expect(container.querySelector('.message-item')).toBeInTheDocument();
    });
  });

  describe('user messages', () => {
    it('should display user prefix icon', () => {
      const message = createMessage('user', 'User message');
      const { container } = renderWithProvider(<MessageItem message={message} />);

      expect(container.querySelector('.message-prefix.user')).toBeInTheDocument();
    });

    it('should have user role styling', () => {
      const message = createMessage('user', 'User message');
      const { container } = renderWithProvider(<MessageItem message={message} />);

      expect(container.querySelector('.message-item')).toHaveClass('role-user');
    });
  });

  describe('assistant messages', () => {
    it('should display assistant prefix icon', () => {
      const message = createMessage('assistant', 'Assistant response');
      const { container } = renderWithProvider(<MessageItem message={message} />);

      expect(
        container.querySelector('.message-prefix.assistant'),
      ).toBeInTheDocument();
    });

    it('should have assistant role styling', () => {
      const message = createMessage('assistant', 'Response');
      const { container } = renderWithProvider(<MessageItem message={message} />);

      expect(container.querySelector('.message-item')).toHaveClass(
        'role-assistant',
      );
    });

    it('should render markdown content', () => {
      const message = createMessage('assistant', '**Bold** text');
      const { container } = renderWithProvider(<MessageItem message={message} />);

      expect(container.querySelector('strong')).toBeInTheDocument();
    });
  });

  describe('system messages', () => {
    it('should display system prefix icon', () => {
      const message = createMessage('system', 'System notification');
      const { container } = renderWithProvider(<MessageItem message={message} />);

      expect(
        container.querySelector('.message-prefix.system'),
      ).toBeInTheDocument();
    });

    it('should have system role styling', () => {
      const message = createMessage('system', 'System message');
      const { container } = renderWithProvider(<MessageItem message={message} />);

      expect(container.querySelector('.message-item')).toHaveClass('role-system');
    });
  });

  describe('tool messages', () => {
    it('should display tool prefix icon', () => {
      const message = createMessage('tool', 'Tool output', {
        toolName: 'Read',
        toolStatus: 'success',
      });
      const { container } = renderWithProvider(<MessageItem message={message} />);

      expect(container.querySelector('.message-prefix.tool')).toBeInTheDocument();
    });

    it('should show tool name', () => {
      const message = createMessage('tool', 'File contents', {
        toolName: 'Read',
        toolStatus: 'success',
      });
      renderWithProvider(<MessageItem message={message} />);

      expect(screen.getByText('Read')).toBeInTheDocument();
    });

    it('should indicate success status', () => {
      const message = createMessage('tool', 'Done', {
        toolName: 'Bash',
        toolStatus: 'success',
      });
      const { container } = renderWithProvider(<MessageItem message={message} />);

      expect(container.querySelector('.tool-status.success')).toBeInTheDocument();
    });

    it('should indicate error status', () => {
      const message = createMessage('tool', 'Error occurred', {
        toolName: 'Bash',
        toolStatus: 'error',
      });
      const { container } = renderWithProvider(<MessageItem message={message} />);

      expect(container.querySelector('.tool-status.error')).toBeInTheDocument();
    });

    it('should indicate running status', () => {
      const message = createMessage('tool', '', {
        toolName: 'Bash',
        toolStatus: 'running',
      });
      const { container } = renderWithProvider(<MessageItem message={message} />);

      expect(container.querySelector('.tool-status.running')).toBeInTheDocument();
    });

    it('should show duration when provided', () => {
      const message = createMessage('tool', 'Done', {
        toolName: 'Bash',
        toolStatus: 'success',
        duration: 1500,
      });
      renderWithProvider(<MessageItem message={message} />);

      expect(screen.getByText(/1\.5s/)).toBeInTheDocument();
    });
  });

  describe('collapsible content', () => {
    it('should be expandable for long content', () => {
      const longContent = 'A'.repeat(1000);
      const message = createMessage('tool', longContent, {
        toolName: 'Read',
        toolStatus: 'success',
      });
      const { container } = renderWithProvider(<MessageItem message={message} />);

      // Should have collapse capability
      expect(
        container.querySelector('.message-content.collapsible'),
      ).toBeInTheDocument();
    });
  });

  describe('accessibility', () => {
    it('should have article role', () => {
      const message = createMessage('user', 'Test');
      renderWithProvider(<MessageItem message={message} />);

      expect(screen.getByRole('article')).toBeInTheDocument();
    });

    it('should have accessible label based on role', () => {
      const message = createMessage('user', 'Test message');
      renderWithProvider(<MessageItem message={message} />);

      expect(screen.getByRole('article')).toHaveAttribute(
        'aria-label',
        expect.stringContaining('user'),
      );
    });
  });
});
