/**
 * @fileoverview AppShell Component Tests
 *
 * Tests for the main layout shell with sidebar and content areas.
 */

import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { AppShell } from '../../../src/components/layout/AppShell.js';
import { ChatProvider } from '../../../src/store/context.js';

// Wrapper with provider
function renderWithProvider(ui: React.ReactElement) {
  return render(<ChatProvider>{ui}</ChatProvider>);
}

describe('AppShell', () => {
  describe('structure', () => {
    it('should render sidebar and main content areas', () => {
      renderWithProvider(
        <AppShell
          sidebar={<div data-testid="sidebar">Sidebar</div>}
          main={<div data-testid="main">Main</div>}
        />,
      );

      expect(screen.getByTestId('sidebar')).toBeInTheDocument();
      expect(screen.getByTestId('main')).toBeInTheDocument();
    });

    it('should have app-shell class', () => {
      const { container } = renderWithProvider(
        <AppShell sidebar={<div />} main={<div />} />,
      );

      expect(container.querySelector('.app-shell')).toBeInTheDocument();
    });

    it('should render sidebar in aside element', () => {
      renderWithProvider(
        <AppShell
          sidebar={<div data-testid="sidebar-content">Sidebar</div>}
          main={<div />}
        />,
      );

      const aside = screen.getByRole('complementary');
      expect(aside).toContainElement(screen.getByTestId('sidebar-content'));
    });

    it('should render main content in main element', () => {
      renderWithProvider(
        <AppShell
          sidebar={<div />}
          main={<div data-testid="main-content">Main</div>}
        />,
      );

      const main = screen.getByRole('main');
      expect(main).toContainElement(screen.getByTestId('main-content'));
    });
  });

  describe('sidebar visibility', () => {
    it('should show sidebar by default on desktop', () => {
      renderWithProvider(<AppShell sidebar={<div />} main={<div />} />);

      const aside = screen.getByRole('complementary');
      expect(aside).not.toHaveClass('collapsed');
    });

    it('should toggle sidebar when toggle button clicked', () => {
      renderWithProvider(<AppShell sidebar={<div />} main={<div />} />);

      const toggleButton = screen.getByRole('button', { name: /toggle sidebar/i });
      const aside = screen.getByRole('complementary');

      // Initially visible
      expect(aside).not.toHaveClass('collapsed');

      // Click to collapse
      fireEvent.click(toggleButton);
      expect(aside).toHaveClass('collapsed');

      // Click to expand
      fireEvent.click(toggleButton);
      expect(aside).not.toHaveClass('collapsed');
    });

    it('should support controlled sidebar state', () => {
      const onToggle = vi.fn();
      renderWithProvider(
        <AppShell
          sidebar={<div />}
          main={<div />}
          sidebarOpen={false}
          onSidebarToggle={onToggle}
        />,
      );

      const aside = screen.getByRole('complementary');
      expect(aside).toHaveClass('collapsed');

      const toggleButton = screen.getByRole('button', { name: /toggle sidebar/i });
      fireEvent.click(toggleButton);

      expect(onToggle).toHaveBeenCalledWith(true);
    });
  });

  describe('responsive behavior', () => {
    it('should apply mobile class when isMobile prop is true', () => {
      const { container } = renderWithProvider(
        <AppShell sidebar={<div />} main={<div />} isMobile={true} />,
      );

      expect(container.querySelector('.app-shell')).toHaveClass('mobile');
    });

    it('should render overlay when sidebar open on mobile', () => {
      renderWithProvider(
        <AppShell
          sidebar={<div />}
          main={<div />}
          isMobile={true}
          sidebarOpen={true}
        />,
      );

      expect(screen.getByTestId('sidebar-overlay')).toBeInTheDocument();
    });

    it('should close sidebar when overlay clicked on mobile', () => {
      const onToggle = vi.fn();
      renderWithProvider(
        <AppShell
          sidebar={<div />}
          main={<div />}
          isMobile={true}
          sidebarOpen={true}
          onSidebarToggle={onToggle}
        />,
      );

      fireEvent.click(screen.getByTestId('sidebar-overlay'));
      expect(onToggle).toHaveBeenCalledWith(false);
    });
  });

  describe('accessibility', () => {
    it('should have proper ARIA landmarks', () => {
      renderWithProvider(<AppShell sidebar={<div />} main={<div />} />);

      expect(screen.getByRole('complementary')).toBeInTheDocument();
      expect(screen.getByRole('main')).toBeInTheDocument();
    });

    it('should have accessible toggle button', () => {
      renderWithProvider(<AppShell sidebar={<div />} main={<div />} />);

      const toggleButton = screen.getByRole('button', { name: /toggle sidebar/i });
      expect(toggleButton).toHaveAttribute('aria-expanded');
    });
  });
});
