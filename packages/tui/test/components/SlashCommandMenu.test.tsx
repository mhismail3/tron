/**
 * @fileoverview SlashCommandMenu Component Tests
 */
import { describe, it, expect, vi } from 'vitest';
import React from 'react';
import { render } from 'ink-testing-library';
import { SlashCommandMenu } from '../../src/components/SlashCommandMenu.js';
import { BUILT_IN_COMMANDS } from '../../src/commands/slash-commands.js';

describe('SlashCommandMenu Component', () => {
  const defaultProps = {
    commands: BUILT_IN_COMMANDS,
    filter: '',
    selectedIndex: 0,
    onSelect: vi.fn(),
    onCancel: vi.fn(),
  };

  it('should render command list', () => {
    const { lastFrame } = render(<SlashCommandMenu {...defaultProps} />);
    const frame = lastFrame() ?? '';

    // Should show command names
    expect(frame).toContain('model');
    expect(frame).toContain('help');
    expect(frame).toContain('clear');
  });

  it('should show descriptions', () => {
    const { lastFrame } = render(<SlashCommandMenu {...defaultProps} />);
    const frame = lastFrame() ?? '';

    expect(frame).toContain('Change the current model');
    expect(frame).toContain('Show available commands');
  });

  it('should highlight selected item', () => {
    const { lastFrame } = render(<SlashCommandMenu {...defaultProps} selectedIndex={0} />);
    const frame = lastFrame() ?? '';

    // First item should have indicator
    expect(frame).toContain('>');
  });

  it('should filter commands based on filter prop', () => {
    const { lastFrame } = render(<SlashCommandMenu {...defaultProps} filter="mod" />);
    const frame = lastFrame() ?? '';

    expect(frame).toContain('model');
    expect(frame).not.toContain('help');
    expect(frame).not.toContain('clear');
  });

  it('should show empty state when no commands match', () => {
    const { lastFrame } = render(<SlashCommandMenu {...defaultProps} filter="xyz" />);
    const frame = lastFrame() ?? '';

    expect(frame).toContain('No matching commands');
  });

  it('should show keyboard hints', () => {
    const { lastFrame } = render(<SlashCommandMenu {...defaultProps} />);
    const frame = lastFrame() ?? '';

    // Should show navigation hints
    expect(frame.toLowerCase()).toMatch(/enter|esc|↑|↓/);
  });

  it('should handle custom command list', () => {
    const customCommands = [
      { name: 'custom', description: 'A custom command' },
    ];

    const { lastFrame } = render(
      <SlashCommandMenu
        {...defaultProps}
        commands={customCommands}
      />
    );
    const frame = lastFrame() ?? '';

    expect(frame).toContain('custom');
    expect(frame).toContain('A custom command');
  });

  it('should limit visible items', () => {
    const { lastFrame } = render(
      <SlashCommandMenu {...defaultProps} maxVisible={3} />
    );
    const frame = lastFrame() ?? '';

    // Should show scroll indicator if more items than visible
    if (BUILT_IN_COMMANDS.length > 3) {
      expect(frame).toMatch(/\d+\/\d+|more|↓/);
    }
  });
});
