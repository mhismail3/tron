/**
 * @fileoverview ThinkingBlock Component Tests
 *
 * Tests for the animated thinking indicator with pulsing bars.
 */

import { describe, it, expect } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { ThinkingBlock } from '../../../src/components/chat/ThinkingBlock.js';
import { ChatProvider } from '../../../src/store/context.js';

function renderWithProvider(ui: React.ReactElement) {
  return render(<ChatProvider>{ui}</ChatProvider>);
}

describe('ThinkingBlock', () => {
  describe('structure', () => {
    it('should render with default props', () => {
      renderWithProvider(<ThinkingBlock />);

      expect(screen.getByText('Thinking')).toBeInTheDocument();
    });

    it('should have thinking-block class', () => {
      const { container } = renderWithProvider(<ThinkingBlock />);

      expect(container.querySelector('.thinking-block')).toBeInTheDocument();
    });

    it('should render animated bars', () => {
      const { container } = renderWithProvider(<ThinkingBlock />);

      const bars = container.querySelectorAll('.thinking-bar');
      expect(bars.length).toBeGreaterThan(0);
    });

    it('should render 5 bars by default', () => {
      const { container } = renderWithProvider(<ThinkingBlock />);

      const bars = container.querySelectorAll('.thinking-bar');
      expect(bars.length).toBe(5);
    });
  });

  describe('customization', () => {
    it('should accept custom label', () => {
      renderWithProvider(<ThinkingBlock label="Processing" />);

      expect(screen.getByText('Processing')).toBeInTheDocument();
    });

    it('should accept custom bar count', () => {
      const { container } = renderWithProvider(<ThinkingBlock barCount={3} />);

      const bars = container.querySelectorAll('.thinking-bar');
      expect(bars.length).toBe(3);
    });

    it('should accept custom className', () => {
      const { container } = renderWithProvider(
        <ThinkingBlock className="custom-thinking" />,
      );

      expect(container.querySelector('.custom-thinking')).toBeInTheDocument();
    });
  });

  describe('thinking text', () => {
    it('should show thinking text when provided', () => {
      renderWithProvider(
        <ThinkingBlock thinkingText="Analyzing the codebase..." />,
      );

      expect(screen.getByText('Analyzing the codebase...')).toBeInTheDocument();
    });

    it('should not show thinking content area when no text', () => {
      const { container } = renderWithProvider(<ThinkingBlock />);

      expect(
        container.querySelector('.thinking-content'),
      ).not.toBeInTheDocument();
    });

    it('should show thinking content area when text provided', () => {
      const { container } = renderWithProvider(
        <ThinkingBlock thinkingText="Some thinking" />,
      );

      expect(container.querySelector('.thinking-content')).toBeInTheDocument();
    });
  });

  describe('collapsed state', () => {
    it('should start collapsed when thinkingText is long', () => {
      const longText = 'A'.repeat(500);
      const { container } = renderWithProvider(
        <ThinkingBlock thinkingText={longText} />,
      );

      expect(container.querySelector('.thinking-content')).toHaveClass(
        'collapsed',
      );
    });

    it('should expand when expand button clicked', () => {
      const longText = 'A'.repeat(500);
      renderWithProvider(<ThinkingBlock thinkingText={longText} />);

      const expandButton = screen.getByRole('button', { name: /expand/i });
      fireEvent.click(expandButton);

      expect(
        screen.getByRole('button', { name: /collapse/i }),
      ).toBeInTheDocument();
    });
  });

  describe('animation classes', () => {
    it('should have animation classes on bars', () => {
      const { container } = renderWithProvider(<ThinkingBlock />);

      const bars = container.querySelectorAll('.thinking-bar');
      bars.forEach((bar) => {
        expect(bar).toHaveStyle({ 'animation-name': 'thinking-pulse' });
      });
    });

    it('should have staggered animation delays', () => {
      const { container } = renderWithProvider(<ThinkingBlock />);

      const bars = container.querySelectorAll('.thinking-bar');
      const delays = Array.from(bars).map((bar) => {
        const style = window.getComputedStyle(bar);
        return style.animationDelay;
      });

      // Each bar should have different delay
      const uniqueDelays = new Set(delays);
      expect(uniqueDelays.size).toBe(bars.length);
    });
  });

  describe('accessibility', () => {
    it('should have accessible status role', () => {
      renderWithProvider(<ThinkingBlock />);

      expect(screen.getByRole('status')).toBeInTheDocument();
    });

    it('should have aria-busy attribute', () => {
      renderWithProvider(<ThinkingBlock />);

      expect(screen.getByRole('status')).toHaveAttribute('aria-busy', 'true');
    });

    it('should have accessible label', () => {
      renderWithProvider(<ThinkingBlock label="Processing request" />);

      expect(screen.getByRole('status')).toHaveAttribute(
        'aria-label',
        'Processing request',
      );
    });
  });
});
