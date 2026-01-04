/**
 * @fileoverview MessageList Component Tests
 *
 * Tests for the message list with streaming, thinking, and tool indicators.
 */

import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import { MessageList } from '../../../src/components/chat/MessageList.js';
import { ChatProvider } from '../../../src/store/context.js';
import type { DisplayMessage } from '../../../src/store/types.js';

function renderWithProvider(ui: React.ReactElement) {
  return render(<ChatProvider>{ui}</ChatProvider>);
}

function createMessage(
  role: DisplayMessage['role'],
  content: string,
  id?: string,
): DisplayMessage {
  return {
    id: id || `msg_${Date.now()}_${Math.random()}`,
    role,
    content,
    timestamp: new Date().toISOString(),
  };
}

describe('MessageList', () => {
  describe('structure', () => {
    it('should render empty state when no messages', () => {
      renderWithProvider(<MessageList messages={[]} />);

      expect(screen.getByText(/no messages/i)).toBeInTheDocument();
    });

    it('should render messages', () => {
      const messages = [
        createMessage('user', 'Hello'),
        createMessage('assistant', 'Hi there!'),
      ];
      renderWithProvider(<MessageList messages={messages} />);

      expect(screen.getByText('Hello')).toBeInTheDocument();
      expect(screen.getByText('Hi there!')).toBeInTheDocument();
    });

    it('should have message-list class', () => {
      const messages = [createMessage('user', 'Test')];
      const { container } = renderWithProvider(
        <MessageList messages={messages} />,
      );

      expect(container.querySelector('.message-list')).toBeInTheDocument();
    });

    it('should render messages in order', () => {
      const messages = [
        createMessage('user', 'First', 'msg_1'),
        createMessage('assistant', 'Second', 'msg_2'),
        createMessage('user', 'Third', 'msg_3'),
      ];
      const { container } = renderWithProvider(
        <MessageList messages={messages} />,
      );

      const items = container.querySelectorAll('.message-item');
      expect(items.length).toBe(3);
    });
  });

  describe('thinking indicator', () => {
    it('should show thinking indicator when processing', () => {
      const messages = [createMessage('user', 'Question')];
      renderWithProvider(
        <MessageList messages={messages} isProcessing={true} />,
      );

      expect(screen.getByRole('status')).toBeInTheDocument();
      expect(screen.getByText('Thinking')).toBeInTheDocument();
    });

    it('should not show thinking when not processing', () => {
      const messages = [createMessage('user', 'Question')];
      renderWithProvider(
        <MessageList messages={messages} isProcessing={false} />,
      );

      expect(screen.queryByText('Thinking')).not.toBeInTheDocument();
    });

    it('should show thinking text when provided', () => {
      const messages = [createMessage('user', 'Question')];
      renderWithProvider(
        <MessageList
          messages={messages}
          isProcessing={true}
          thinkingText="Analyzing the request..."
        />,
      );

      expect(screen.getByText('Analyzing the request...')).toBeInTheDocument();
    });
  });

  describe('streaming content', () => {
    it('should show streaming content when provided', () => {
      const messages = [createMessage('user', 'Question')];
      renderWithProvider(
        <MessageList
          messages={messages}
          streamingContent="Generating response..."
          isStreaming={true}
        />,
      );

      expect(screen.getByText('Generating response...')).toBeInTheDocument();
    });

    it('should show streaming cursor when streaming', () => {
      const messages = [createMessage('user', 'Question')];
      const { container } = renderWithProvider(
        <MessageList
          messages={messages}
          streamingContent="Streaming"
          isStreaming={true}
        />,
      );

      expect(container.querySelector('.streaming-cursor')).toBeInTheDocument();
    });

    it('should not show thinking when streaming', () => {
      const messages = [createMessage('user', 'Question')];
      renderWithProvider(
        <MessageList
          messages={messages}
          isProcessing={true}
          streamingContent="Streaming content"
          isStreaming={true}
        />,
      );

      // Streaming content should be shown, not thinking
      expect(screen.getByText('Streaming content')).toBeInTheDocument();
      expect(screen.queryByText('Thinking')).not.toBeInTheDocument();
    });
  });

  describe('active tool', () => {
    it('should show tool indicator when active', () => {
      const messages = [createMessage('user', 'Read a file')];
      renderWithProvider(
        <MessageList
          messages={messages}
          isProcessing={true}
          activeTool="Read"
        />,
      );

      expect(screen.getByText('Read')).toBeInTheDocument();
    });

    it('should show tool input when provided', () => {
      const messages = [createMessage('user', 'Run a command')];
      renderWithProvider(
        <MessageList
          messages={messages}
          isProcessing={true}
          activeTool="Bash"
          activeToolInput="ls -la"
        />,
      );

      expect(screen.getByText(/ls -la/)).toBeInTheDocument();
    });
  });

  describe('welcome box', () => {
    it('should show welcome when configured', () => {
      renderWithProvider(
        <MessageList
          messages={[]}
          showWelcome={true}
          welcomeModel="claude-sonnet-4-20250514"
          welcomeWorkingDirectory="/home/user/project"
        />,
      );

      // WelcomeBox formats model name as "sonnet-4" (removes "claude-" prefix and date suffix)
      expect(screen.getByText('sonnet-4')).toBeInTheDocument();
    });

    it('should show git branch when provided', () => {
      renderWithProvider(
        <MessageList
          messages={[]}
          showWelcome={true}
          welcomeModel="claude-sonnet-4-20250514"
          welcomeWorkingDirectory="/home/user/project"
          welcomeGitBranch="main"
        />,
      );

      expect(screen.getByText(/main/)).toBeInTheDocument();
    });
  });

  describe('scrolling', () => {
    it('should have scrollable container', () => {
      const { container } = renderWithProvider(<MessageList messages={[]} />);

      expect(container.querySelector('.message-list')).toHaveClass('scrollable');
    });
  });

  describe('accessibility', () => {
    it('should have log role', () => {
      const messages = [createMessage('user', 'Test')];
      renderWithProvider(<MessageList messages={messages} />);

      expect(screen.getByRole('log')).toBeInTheDocument();
    });

    it('should be aria-live polite', () => {
      const messages = [createMessage('user', 'Test')];
      renderWithProvider(<MessageList messages={messages} />);

      expect(screen.getByRole('log')).toHaveAttribute('aria-live', 'polite');
    });
  });
});
