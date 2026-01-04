/**
 * @fileoverview Welcome Box Component
 *
 * Displays the welcome banner with TRON block logo and session info.
 * Design: Bordered box with block-art TRON text, responsive to terminal width.
 */
import React from 'react';
import { Box, Text, useStdout } from 'ink';
import { inkColors } from '../theme.js';

export interface WelcomeBoxProps {
  model: string;
  workingDirectory: string;
  gitBranch?: string;
}

// TRON logo using block characters (5 lines)
const TRON_LOGO = [
  '████████╗██████╗  ██████╗ ███╗   ██╗',
  '╚══██╔══╝██╔══██╗██╔═══██╗████╗  ██║',
  '   ██║   ██████╔╝██║   ██║██╔██╗ ██║',
  '   ██║   ██╔══██╗╚██████╔╝██║ ╚████║',
  '   ╚═╝   ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═══╝',
];

/**
 * Format path for display with ~ substitution
 */
function formatPath(p: string, maxLen: number): string {
  const home = process.env.HOME ?? '';
  let formatted = p;
  if (home && p.startsWith(home)) {
    formatted = '~' + p.slice(home.length);
  }
  if (formatted.length > maxLen) {
    formatted = '...' + formatted.slice(-(maxLen - 3));
  }
  return formatted;
}

export function WelcomeBox({
  workingDirectory,
  gitBranch,
}: WelcomeBoxProps): React.ReactElement {
  const { stdout } = useStdout();
  const terminalWidth = stdout?.columns ?? 80;

  // Responsive breakpoint - logo is ~36 chars wide
  const isNarrow = terminalWidth < 60;
  const maxPathLen = isNarrow ? 25 : Math.floor(terminalWidth * 0.4);
  const displayPath = formatPath(workingDirectory, maxPathLen);

  // Format directory with optional git branch
  const directoryDisplay = gitBranch
    ? `${displayPath} (${gitBranch})`
    : displayPath;

  // Narrow mode: no logo, minimal layout
  if (isNarrow) {
    return (
      <Box
        flexDirection="column"
        borderStyle="round"
        borderColor={inkColors.border}
        paddingX={1}
        paddingY={0}
        marginX={1}
        width="100%"
      >
        <Box flexDirection="row" justifyContent="flex-end">
          <Text color={inkColors.logo} bold>TRON</Text>
        </Box>
        <Box flexDirection="row" justifyContent="flex-end">
          <Text color={inkColors.label}>Directory: </Text>
          <Text color={inkColors.value}>{directoryDisplay}</Text>
        </Box>
      </Box>
    );
  }

  // Standard mode: TRON block logo + directory (right-aligned, vertically centered)
  return (
    <Box
      flexDirection="row"
      borderStyle="round"
      borderColor={inkColors.border}
      paddingX={1}
      paddingY={0}
      marginX={1}
      width="100%"
    >
      {/* Left: TRON Block Logo */}
      <Box flexDirection="column" marginRight={2} justifyContent="center">
        {TRON_LOGO.map((line, i) => (
          <Text key={i} color={inkColors.logo}>{line}</Text>
        ))}
      </Box>

      {/* Right: Directory info - right-aligned and vertically centered */}
      <Box flexDirection="column" flexGrow={1} justifyContent="center" alignItems="flex-end">
        <Box flexDirection="row">
          <Text color={inkColors.label}>Directory: </Text>
          <Text color={inkColors.value}>{directoryDisplay}</Text>
        </Box>
      </Box>
    </Box>
  );
}
