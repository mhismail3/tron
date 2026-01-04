/**
 * @fileoverview CommandPalette Component Tests
 */

import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { CommandPalette } from '../../../src/components/overlay/CommandPalette.js';
import { ChatProvider } from '../../../src/store/context.js';

function renderWithProvider(ui: React.ReactElement) {
  return render(<ChatProvider>{ui}</ChatProvider>);
}

describe('CommandPalette', () => {
  describe('visibility', () => {
    it('should not render when not open', () => {
      const { container } = renderWithProvider(
        <CommandPalette open={false} onClose={vi.fn()} />,
      );

      expect(
        container.querySelector('.command-palette'),
      ).not.toBeInTheDocument();
    });

    it('should render when open', () => {
      const { container } = renderWithProvider(
        <CommandPalette open={true} onClose={vi.fn()} />,
      );

      expect(container.querySelector('.command-palette')).toBeInTheDocument();
    });
  });

  describe('structure', () => {
    it('should have search input', () => {
      renderWithProvider(<CommandPalette open={true} onClose={vi.fn()} />);

      expect(screen.getByRole('combobox')).toBeInTheDocument();
    });

    it('should have command list', () => {
      renderWithProvider(<CommandPalette open={true} onClose={vi.fn()} />);

      expect(screen.getByRole('listbox')).toBeInTheDocument();
    });

    it('should show commands', () => {
      renderWithProvider(<CommandPalette open={true} onClose={vi.fn()} />);

      expect(screen.getByText('/help')).toBeInTheDocument();
      expect(screen.getByText('/model')).toBeInTheDocument();
    });
  });

  describe('filtering', () => {
    it('should filter commands as user types', () => {
      renderWithProvider(<CommandPalette open={true} onClose={vi.fn()} />);

      const input = screen.getByRole('combobox');
      fireEvent.change(input, { target: { value: 'he' } });

      expect(screen.getByText('/help')).toBeInTheDocument();
    });

    it('should show no results message when no matches', () => {
      renderWithProvider(<CommandPalette open={true} onClose={vi.fn()} />);

      const input = screen.getByRole('combobox');
      fireEvent.change(input, { target: { value: 'zzzzz' } });

      expect(screen.getByText(/no commands found/i)).toBeInTheDocument();
    });
  });

  describe('keyboard navigation', () => {
    it('should highlight first item by default', () => {
      const { container } = renderWithProvider(
        <CommandPalette open={true} onClose={vi.fn()} />,
      );

      const firstItem = container.querySelector('.command-item');
      expect(firstItem).toHaveClass('active');
    });

    it('should move selection down with ArrowDown', () => {
      const { container } = renderWithProvider(
        <CommandPalette open={true} onClose={vi.fn()} />,
      );

      const input = screen.getByRole('combobox');
      fireEvent.keyDown(input, { key: 'ArrowDown' });

      const items = container.querySelectorAll('.command-item');
      expect(items[1]).toHaveClass('active');
    });

    it('should move selection up with ArrowUp', () => {
      const { container } = renderWithProvider(
        <CommandPalette open={true} onClose={vi.fn()} />,
      );

      const input = screen.getByRole('combobox');
      // Move down first
      fireEvent.keyDown(input, { key: 'ArrowDown' });
      fireEvent.keyDown(input, { key: 'ArrowDown' });
      // Then up
      fireEvent.keyDown(input, { key: 'ArrowUp' });

      const items = container.querySelectorAll('.command-item');
      expect(items[1]).toHaveClass('active');
    });

    it('should close on Escape', () => {
      const onClose = vi.fn();
      renderWithProvider(<CommandPalette open={true} onClose={onClose} />);

      const input = screen.getByRole('combobox');
      fireEvent.keyDown(input, { key: 'Escape' });

      expect(onClose).toHaveBeenCalled();
    });
  });

  describe('selection', () => {
    it('should call onSelect when Enter pressed', () => {
      const onSelect = vi.fn();
      renderWithProvider(
        <CommandPalette open={true} onClose={vi.fn()} onSelect={onSelect} />,
      );

      const input = screen.getByRole('combobox');
      fireEvent.keyDown(input, { key: 'Enter' });

      expect(onSelect).toHaveBeenCalled();
    });

    it('should call onSelect when item clicked', () => {
      const onSelect = vi.fn();
      renderWithProvider(
        <CommandPalette open={true} onClose={vi.fn()} onSelect={onSelect} />,
      );

      fireEvent.click(screen.getByText('/help'));

      expect(onSelect).toHaveBeenCalled();
    });

    it('should close after selection', () => {
      const onClose = vi.fn();
      renderWithProvider(
        <CommandPalette open={true} onClose={onClose} onSelect={vi.fn()} />,
      );

      fireEvent.click(screen.getByText('/help'));

      expect(onClose).toHaveBeenCalled();
    });
  });

  describe('initial query', () => {
    it('should use initial query if provided', () => {
      renderWithProvider(
        <CommandPalette open={true} onClose={vi.fn()} initialQuery="mod" />,
      );

      const input = screen.getByRole('combobox') as HTMLInputElement;
      expect(input.value).toBe('mod');
    });

    it('should filter based on initial query', () => {
      renderWithProvider(
        <CommandPalette open={true} onClose={vi.fn()} initialQuery="mod" />,
      );

      expect(screen.getByText('/model')).toBeInTheDocument();
    });
  });

  describe('accessibility', () => {
    it('should have dialog role', () => {
      renderWithProvider(<CommandPalette open={true} onClose={vi.fn()} />);

      expect(screen.getByRole('dialog')).toBeInTheDocument();
    });

    it('should focus input when opened', () => {
      renderWithProvider(<CommandPalette open={true} onClose={vi.fn()} />);

      expect(screen.getByRole('combobox')).toHaveFocus();
    });

    it('should have aria-activedescendant', () => {
      renderWithProvider(<CommandPalette open={true} onClose={vi.fn()} />);

      const input = screen.getByRole('combobox');
      expect(input).toHaveAttribute('aria-activedescendant');
    });
  });
});
