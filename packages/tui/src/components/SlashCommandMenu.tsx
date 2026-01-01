/**
 * @fileoverview Slash Command Menu Component
 *
 * An interactive menu for selecting slash commands.
 * Supports arrow key navigation, filtering, and keyboard shortcuts.
 */
import React, { useMemo } from 'react';
import { Box, Text } from 'ink';
import { SlashCommand, filterCommands } from '../commands/slash-commands.js';

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
        borderColor="gray"
        paddingX={1}
      >
        <Text color="gray" dimColor>No matching commands</Text>
      </Box>
    );
  }

  const visibleCommands = filteredCommands.slice(visibleRange.start, visibleRange.end);
  const hasMoreAbove = visibleRange.start > 0;
  const hasMoreBelow = visibleRange.end < filteredCommands.length;

  return (
    <Box flexDirection="column" borderStyle="round" borderColor="cyan" paddingX={1}>
      {/* Header */}
      <Box marginBottom={0}>
        <Text color="cyan" bold>Commands</Text>
        <Text color="gray"> ({selectedIndex + 1}/{filteredCommands.length})</Text>
      </Box>

      {/* Scroll up indicator */}
      {hasMoreAbove && (
        <Text color="gray" dimColor>  ↑ more</Text>
      )}

      {/* Command list */}
      {visibleCommands.map((cmd, idx) => {
        const actualIndex = visibleRange.start + idx;
        const isSelected = actualIndex === selectedIndex;

        return (
          <Box key={cmd.name} flexDirection="row">
            <Text color={isSelected ? 'cyan' : 'gray'}>
              {isSelected ? '> ' : '  '}
            </Text>
            <Text color={isSelected ? 'cyan' : 'white'} bold={isSelected}>
              /{cmd.name}
            </Text>
            {cmd.shortcut && (
              <Text color="gray" dimColor> ({cmd.shortcut})</Text>
            )}
            <Text color="gray"> - </Text>
            <Text color={isSelected ? 'white' : 'gray'} dimColor={!isSelected}>
              {cmd.description}
            </Text>
          </Box>
        );
      })}

      {/* Scroll down indicator */}
      {hasMoreBelow && (
        <Text color="gray" dimColor>  ↓ more</Text>
      )}

      {/* Keyboard hints */}
      <Box marginTop={0} borderStyle="single" borderTop borderBottom={false} borderLeft={false} borderRight={false} borderColor="gray">
        <Text color="gray" dimColor>↑↓ navigate  Enter select  Esc cancel</Text>
      </Box>
    </Box>
  );
}
