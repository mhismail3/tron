/**
 * @fileoverview Tests for MessageBubble component
 */
import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import { MessageBubble, type Message } from '../../../src/components/chat/MessageBubble.js';

describe('MessageBubble', () => {
  const baseMessage: Message = {
    id: 'msg_1',
    role: 'user',
    content: 'Test message',
    timestamp: '2025-01-01T00:00:00Z',
  };

  describe('User messages', () => {
    it('should render user message content', () => {
      render(<MessageBubble message={baseMessage} />);
      expect(screen.getByText('Test message')).toBeInTheDocument();
    });

    it('should apply user message styling', () => {
      const { container } = render(<MessageBubble message={baseMessage} />);
      const bubble = container.firstChild as HTMLElement;
      expect(bubble).toHaveStyle({ justifyContent: 'flex-end' });
    });
  });

  describe('Assistant messages', () => {
    const assistantMessage: Message = {
      id: 'msg_2',
      role: 'assistant',
      content: 'Hello, I am Claude',
      timestamp: '2025-01-01T00:00:00Z',
    };

    it('should render assistant message content', () => {
      render(<MessageBubble message={assistantMessage} />);
      expect(screen.getByText('Hello, I am Claude')).toBeInTheDocument();
    });

    it('should show assistant indicator', () => {
      render(<MessageBubble message={assistantMessage} />);
      expect(screen.getByText('assistant')).toBeInTheDocument();
      expect(screen.getByText('*')).toBeInTheDocument();
    });

    it('should show streaming indicator when streaming', () => {
      const streamingMessage: Message = {
        ...assistantMessage,
        isStreaming: true,
      };
      const { container } = render(<MessageBubble message={streamingMessage} />);
      // Should have spinner
      const spinner = container.querySelector('svg');
      expect(spinner).toBeInTheDocument();
    });

    it('should render tool calls when present', () => {
      const messageWithTools: Message = {
        ...assistantMessage,
        toolCalls: [
          {
            id: 'tool_1',
            name: 'bash',
            status: 'success',
            input: 'ls -la',
            duration: 150,
          },
        ],
      };
      render(<MessageBubble message={messageWithTools} />);
      expect(screen.getByText('bash')).toBeInTheDocument();
    });
  });

  describe('System messages', () => {
    const systemMessage: Message = {
      id: 'msg_3',
      role: 'system',
      content: 'Session started',
      timestamp: '2025-01-01T00:00:00Z',
    };

    it('should render system message content', () => {
      render(<MessageBubble message={systemMessage} />);
      expect(screen.getByText('Session started')).toBeInTheDocument();
    });

    it('should center system messages', () => {
      const { container } = render(<MessageBubble message={systemMessage} />);
      const bubble = container.firstChild as HTMLElement;
      expect(bubble).toHaveStyle({ justifyContent: 'center' });
    });
  });
});
