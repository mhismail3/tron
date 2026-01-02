/**
 * @fileoverview Welcome Box Component
 *
 * Displays the welcome banner with TRON block logo and session info.
 * Design: Bordered box with block-art TRON text, responsive to terminal width.
 */
import React from 'react';
import { Box, Text, useStdout } from 'ink';

export interface WelcomeBoxProps {
  model: string;
  workingDirectory: string;
}

// TRON logo using solid and half-height blocks (2 lines)
const TRON_LOGO = [
  '▀█▀ █▀▄ █▀█ █▄ █',
  ' █  █▀▄ █▄█ █ ▀█',
];

/**
 * Format model name for display
 */
function formatModelName(m: string): string {
  if (m.includes('claude')) {
    if (m.includes('opus-4-5')) return 'Claude Opus 4.5';
    if (m.includes('opus-4')) return 'Claude Opus 4';
    if (m.includes('sonnet-4')) return 'Claude Sonnet 4';
    if (m.includes('sonnet')) return 'Claude Sonnet';
    if (m.includes('haiku')) return 'Claude Haiku';
    return 'Claude';
  }
  if (m.includes('gpt-4o')) return 'GPT-4o';
  if (m.includes('gpt-4')) return 'GPT-4';
  if (m.includes('gemini')) return 'Gemini';
  return m;
}

/**
 * Format model name for narrow displays
 */
function formatModelNameShort(m: string): string {
  if (m.includes('opus-4-5')) return 'Opus 4.5';
  if (m.includes('opus-4')) return 'Opus 4';
  if (m.includes('sonnet-4')) return 'Sonnet 4';
  if (m.includes('sonnet')) return 'Sonnet';
  if (m.includes('haiku')) return 'Haiku';
  if (m.includes('gpt-4o')) return 'GPT-4o';
  if (m.includes('gpt-4')) return 'GPT-4';
  if (m.includes('gemini')) return 'Gemini';
  return m.slice(0, 10);
}

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
  model,
  workingDirectory,
}: WelcomeBoxProps): React.ReactElement {
  const { stdout } = useStdout();
  const terminalWidth = stdout?.columns ?? 80;

  // Responsive breakpoint
  const isNarrow = terminalWidth < 50;

  // Choose appropriate display values based on width
  const displayModel = isNarrow ? formatModelNameShort(model) : formatModelName(model);
  const maxPathLen = isNarrow ? 25 : Math.floor(terminalWidth * 0.4);
  const displayPath = formatPath(workingDirectory, maxPathLen);

  // Narrow mode: no logo, minimal layout
  if (isNarrow) {
    return (
      <Box
        flexDirection="column"
        borderStyle="round"
        borderColor="gray"
        paddingX={1}
        paddingY={0}
        marginX={1}
      >
        <Box flexDirection="row" gap={2}>
          <Text color="cyan" bold>TRON</Text>
          <Text color="yellow">{displayModel}</Text>
        </Box>
        <Text color="green">{displayPath}</Text>
      </Box>
    );
  }

  // Standard mode: TRON block logo + info
  return (
    <Box
      flexDirection="row"
      borderStyle="round"
      borderColor="gray"
      paddingX={1}
      paddingY={0}
      marginX={1}
    >
      {/* Left: TRON Block Logo */}
      <Box flexDirection="column" marginRight={2} justifyContent="center">
        {TRON_LOGO.map((line, i) => (
          <Text key={i} color="cyan">{line}</Text>
        ))}
      </Box>

      {/* Right: Session info */}
      <Box flexDirection="column" flexGrow={1} justifyContent="center">
        <Box flexDirection="row">
          <Text color="gray">Model: </Text>
          <Text color="yellow">{displayModel}</Text>
        </Box>
        <Box flexDirection="row">
          <Text color="gray">Directory: </Text>
          <Text color="green">{displayPath}</Text>
        </Box>
      </Box>
    </Box>
  );
}
