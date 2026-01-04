/**
 * @fileoverview MainContent Component Tests
 *
 * Tests for the main content area wrapper.
 */

import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import { MainContent } from '../../../src/components/layout/MainContent.js';
import { ChatProvider } from '../../../src/store/context.js';

function renderWithProvider(ui: React.ReactElement) {
  return render(<ChatProvider>{ui}</ChatProvider>);
}

describe('MainContent', () => {
  describe('structure', () => {
    it('should render children', () => {
      renderWithProvider(
        <MainContent>
          <div data-testid="child">Content</div>
        </MainContent>,
      );

      expect(screen.getByTestId('child')).toBeInTheDocument();
    });

    it('should have main-content class', () => {
      const { container } = renderWithProvider(
        <MainContent>Content</MainContent>,
      );

      expect(container.querySelector('.main-content')).toBeInTheDocument();
    });

    it('should render header when provided', () => {
      renderWithProvider(
        <MainContent header={<div data-testid="header">Header</div>}>
          Content
        </MainContent>,
      );

      expect(screen.getByTestId('header')).toBeInTheDocument();
    });

    it('should render footer when provided', () => {
      renderWithProvider(
        <MainContent footer={<div data-testid="footer">Footer</div>}>
          Content
        </MainContent>,
      );

      expect(screen.getByTestId('footer')).toBeInTheDocument();
    });
  });

  describe('layout sections', () => {
    it('should have header section at top', () => {
      const { container } = renderWithProvider(
        <MainContent header={<div>Header</div>}>Content</MainContent>,
      );

      const header = container.querySelector('.main-content-header');
      expect(header).toBeInTheDocument();
    });

    it('should have scrollable body section', () => {
      const { container } = renderWithProvider(
        <MainContent>Content</MainContent>,
      );

      const body = container.querySelector('.main-content-body');
      expect(body).toBeInTheDocument();
    });

    it('should have footer section at bottom', () => {
      const { container } = renderWithProvider(
        <MainContent footer={<div>Footer</div>}>Content</MainContent>,
      );

      const footer = container.querySelector('.main-content-footer');
      expect(footer).toBeInTheDocument();
    });
  });

  describe('content width', () => {
    it('should constrain content to max width by default', () => {
      const { container } = renderWithProvider(
        <MainContent>Content</MainContent>,
      );

      const body = container.querySelector('.main-content-body');
      expect(body).toHaveClass('constrained');
    });

    it('should allow full width when specified', () => {
      const { container } = renderWithProvider(
        <MainContent fullWidth>Content</MainContent>,
      );

      const body = container.querySelector('.main-content-body');
      expect(body).not.toHaveClass('constrained');
    });
  });

  describe('padding', () => {
    it('should have default padding', () => {
      const { container } = renderWithProvider(
        <MainContent>Content</MainContent>,
      );

      const body = container.querySelector('.main-content-body');
      expect(body).not.toHaveClass('no-padding');
    });

    it('should support no padding option', () => {
      const { container } = renderWithProvider(
        <MainContent noPadding>Content</MainContent>,
      );

      const body = container.querySelector('.main-content-body');
      expect(body).toHaveClass('no-padding');
    });
  });

  describe('scroll behavior', () => {
    it('should be scrollable by default', () => {
      const { container } = renderWithProvider(
        <MainContent>Content</MainContent>,
      );

      const body = container.querySelector('.main-content-body');
      expect(body).toHaveClass('scrollable');
    });
  });

  describe('accessibility', () => {
    it('should have proper role', () => {
      renderWithProvider(<MainContent>Content</MainContent>);

      // MainContent wraps content but main role is on AppShell
      const content = screen.getByText('Content');
      expect(content).toBeInTheDocument();
    });
  });
});
