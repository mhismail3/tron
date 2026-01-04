/**
 * @fileoverview StreamingContent Component Tests
 *
 * Tests for the streaming content display with animated cursor.
 */

import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import { StreamingContent } from '../../../src/components/chat/StreamingContent.js';
import { ChatProvider } from '../../../src/store/context.js';

function renderWithProvider(ui: React.ReactElement) {
  return render(<ChatProvider>{ui}</ChatProvider>);
}

describe('StreamingContent', () => {
  describe('structure', () => {
    it('should render content', () => {
      renderWithProvider(
        <StreamingContent content="Hello, world!" isStreaming={false} />,
      );

      expect(screen.getByText('Hello, world!')).toBeInTheDocument();
    });

    it('should have streaming-content class', () => {
      const { container } = renderWithProvider(
        <StreamingContent content="Test" isStreaming={false} />,
      );

      expect(container.querySelector('.streaming-content')).toBeInTheDocument();
    });

    it('should render empty when no content and not streaming', () => {
      const { container } = renderWithProvider(
        <StreamingContent content="" isStreaming={false} />,
      );

      const content = container.querySelector('.streaming-content');
      expect(content?.textContent).toBe('');
    });
  });

  describe('streaming state', () => {
    it('should show cursor when streaming', () => {
      const { container } = renderWithProvider(
        <StreamingContent content="Loading" isStreaming={true} />,
      );

      expect(container.querySelector('.streaming-cursor')).toBeInTheDocument();
    });

    it('should hide cursor when not streaming', () => {
      const { container } = renderWithProvider(
        <StreamingContent content="Complete" isStreaming={false} />,
      );

      expect(
        container.querySelector('.streaming-cursor'),
      ).not.toBeInTheDocument();
    });

    it('should show cursor even with empty content when streaming', () => {
      const { container } = renderWithProvider(
        <StreamingContent content="" isStreaming={true} />,
      );

      expect(container.querySelector('.streaming-cursor')).toBeInTheDocument();
    });

    it('should have isStreaming class when streaming', () => {
      const { container } = renderWithProvider(
        <StreamingContent content="Test" isStreaming={true} />,
      );

      expect(container.querySelector('.streaming-content')).toHaveClass(
        'is-streaming',
      );
    });
  });

  describe('cursor animation', () => {
    it('should have blink animation on cursor', () => {
      const { container } = renderWithProvider(
        <StreamingContent content="Test" isStreaming={true} />,
      );

      const cursor = container.querySelector('.streaming-cursor');
      expect(cursor).toHaveStyle({ 'animation-name': 'cursor-blink' });
    });
  });

  describe('markdown rendering', () => {
    it('should render markdown content', () => {
      const markdown = '**Bold** and *italic*';
      const { container } = renderWithProvider(
        <StreamingContent content={markdown} isStreaming={false} />,
      );

      // Should have markdown rendered
      expect(container.querySelector('strong')).toBeInTheDocument();
      expect(container.querySelector('em')).toBeInTheDocument();
    });

    it('should render code blocks', () => {
      const content = '```javascript\nconst x = 1;\n```';
      const { container } = renderWithProvider(
        <StreamingContent content={content} isStreaming={false} />,
      );

      expect(container.querySelector('pre')).toBeInTheDocument();
      expect(container.querySelector('code')).toBeInTheDocument();
    });

    it('should render inline code', () => {
      const content = 'Use `console.log()` to debug';
      const { container } = renderWithProvider(
        <StreamingContent content={content} isStreaming={false} />,
      );

      const code = container.querySelector('code');
      expect(code).toBeInTheDocument();
      expect(code?.textContent).toBe('console.log()');
    });
  });

  describe('customization', () => {
    it('should accept custom className', () => {
      const { container } = renderWithProvider(
        <StreamingContent
          content="Test"
          isStreaming={false}
          className="custom-stream"
        />,
      );

      expect(container.querySelector('.custom-stream')).toBeInTheDocument();
    });
  });

  describe('accessibility', () => {
    it('should have proper ARIA attributes when streaming', () => {
      renderWithProvider(
        <StreamingContent content="Loading..." isStreaming={true} />,
      );

      const content = screen.getByRole('status');
      expect(content).toHaveAttribute('aria-busy', 'true');
    });

    it('should not have aria-busy when not streaming', () => {
      renderWithProvider(
        <StreamingContent content="Done" isStreaming={false} />,
      );

      const content = screen.getByRole('status');
      expect(content).toHaveAttribute('aria-busy', 'false');
    });
  });
});
