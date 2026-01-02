/**
 * @fileoverview Header Component
 *
 * Displays welcome banner with session info.
 * Design: Clean header with TRON branding, model info, and directory.
 */
import React from 'react';
import { Box, Text, useStdout } from 'ink';
import type { HeaderProps } from '../types.js';

export function Header({
  sessionId: _sessionId,
  workingDirectory,
  model,
  tokenUsage: _tokenUsage,
}: HeaderProps): React.ReactElement {
  const { stdout } = useStdout();
  const terminalWidth = stdout?.columns ?? 80;

  // Format model name for display
  const formatModelName = (m: string): string => {
    // claude-opus-4-5-20250514 -> Claude Opus 4.5
    // claude-sonnet-4-20250514 -> Claude Sonnet 4
    // gpt-4o -> GPT-4o
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
  };

  // Truncate path for display
  const formatPath = (p: string): string => {
    // Replace home directory with ~
    const home = process.env.HOME ?? '';
    let formatted = p;
    if (home && p.startsWith(home)) {
      formatted = '~' + p.slice(home.length);
    }
    // Truncate if too long
    const maxLen = Math.floor(terminalWidth * 0.5);
    if (formatted.length > maxLen) {
      formatted = '...' + formatted.slice(-(maxLen - 3));
    }
    return formatted;
  };

  const displayModel = formatModelName(model);
  const displayPath = formatPath(workingDirectory);

  return (
    <Box flexDirection="column" marginBottom={1}>
      {/* Header banner */}
      <Box flexDirection="row" paddingX={1} paddingY={0}>
        <Box flexDirection="column" flexGrow={1}>
          {/* Title row */}
          <Box flexDirection="row" gap={2}>
            <Text color="cyan" bold>TRON</Text>
            <Text color="gray">│</Text>
            <Text color="white">Model: </Text>
            <Text color="yellow">{displayModel}</Text>
          </Box>
          {/* Directory row */}
          <Box flexDirection="row">
            <Text color="white">Directory: </Text>
            <Text color="green">{displayPath}</Text>
          </Box>
        </Box>
        {/* Right side branding */}
        <Box flexDirection="column" alignItems="flex-end">
          <Text color="gray" dimColor>Built by</Text>
          <Text color="gray" dimColor>Moose</Text>
        </Box>
      </Box>
    </Box>
  );
}
