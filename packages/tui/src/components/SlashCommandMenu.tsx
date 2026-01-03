/**
 * @fileoverview Slash Command Menu Component
 *
 * An interactive menu for selecting slash commands.
 * Supports arrow key navigation, filtering, and keyboard shortcuts.
 */
import React, { useMemo } from 'react';
import { Box, Text } from 'ink';
import { SlashCommand, filterCommands } from '../commands/slash-commands.js';
import { inkColors } from '../theme.js';

// =============================================================================
// Types
// =============================================================================

export interface SlashCommandMenuProps {
  commands: SlashCommand[];
  filter: string;
  selectedIndex: number;
  onSelect: (command: SlashCommand) => void;
  onCancel: () => void;
  maxVisible?: number;
}

// =============================================================================
// Component
// =============================================================================

export function SlashCommandMenu({
  commands,
  filter,
  selectedIndex,
  maxVisible = 5,
}: SlashCommandMenuProps): React.ReactElement {
  // Filter commands based on current input
  const filteredCommands = useMemo(() => {
    return filterCommands(commands, filter);
  }, [commands, filter]);

  // Calculate visible range for scrolling
  const visibleRange = useMemo(() => {
    const total = filteredCommands.length;
    if (total <= maxVisible) {
      return { start: 0, end: total };
    }

    // Center selection in visible range
    const halfVisible = Math.floor(maxVisible / 2);
    let start = Math.max(0, selectedIndex - halfVisible);
    let end = start + maxVisible;

    if (end > total) {
      end = total;
      start = Math.max(0, end - maxVisible);
    }

    return { start, end };
  }, [filteredCommands.length, selectedIndex, maxVisible]);

  // No matching commands
  if (filteredCommands.length === 0) {
    return (
      <Box
        flexDirection="column"
        borderStyle="round"
        borderColor={inkColors.border}
        paddingX={1}
      >
        <Text color={inkColors.dim}>No matching commands</Text>
      </Box>
    );
  }

  const visibleCommands = filteredCommands.slice(visibleRange.start, visibleRange.end);
  const hasMoreAbove = visibleRange.start > 0;
  const hasMoreBelow = visibleRange.end < filteredCommands.length;

  return (
    <Box flexDirection="column" borderStyle="round" borderColor={inkColors.menuBorder} paddingX={1}>
      {/* Header */}
      <Box marginBottom={0}>
        <Text color={inkColors.menuHeader} bold>Commands</Text>
        <Text color={inkColors.label}> ({selectedIndex + 1}/{filteredCommands.length})</Text>
      </Box>

      {/* Scroll up indicator */}
      {hasMoreAbove && (
        <Text color={inkColors.dim}>  ↑ more</Text>
      )}

      {/* Command list */}
      {visibleCommands.map((cmd, idx) => {
        const actualIndex = visibleRange.start + idx;
        const isSelected = actualIndex === selectedIndex;

        return (
          <Box key={cmd.name} flexDirection="row">
            <Text color={isSelected ? inkColors.menuSelected : inkColors.label}>
              {isSelected ? '> ' : '  '}
            </Text>
            <Text color={isSelected ? inkColors.menuSelected : inkColors.menuItem} bold={isSelected}>
              /{cmd.name}
            </Text>
            {cmd.shortcut && (
              <Text color={inkColors.dim}> ({cmd.shortcut})</Text>
            )}
            <Text color={inkColors.label}> - </Text>
            <Text color={isSelected ? inkColors.value : inkColors.dim}>
              {cmd.description}
            </Text>
          </Box>
        );
      })}

      {/* Scroll down indicator */}
      {hasMoreBelow && (
        <Text color={inkColors.dim}>  ↓ more</Text>
      )}

      {/* Keyboard hints */}
      <Box marginTop={0} borderStyle="single" borderTop borderBottom={false} borderLeft={false} borderRight={false} borderColor={inkColors.border}>
        <Text color={inkColors.dim}>↑↓ navigate  Enter select  Esc cancel</Text>
      </Box>
    </Box>
  );
}
