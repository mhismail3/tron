/**
 * @fileoverview Header Component
 *
 * Displays session info, working directory, model, and token usage.
 */
import React from 'react';
import { Box, Text } from 'ink';
import type { HeaderProps } from '../types.js';

export function Header({
  sessionId: _sessionId,
  workingDirectory,
  model,
  tokenUsage,
}: HeaderProps): React.ReactElement {
  // Truncate working directory if too long
  const maxPathLength = 40;
  const displayPath =
    workingDirectory.length > maxPathLength
      ? '...' + workingDirectory.slice(-maxPathLength + 3)
      : workingDirectory;

  // Format token count
  const formatTokens = (n: number): string => {
    if (n >= 1000000) return `${(n / 1000000).toFixed(1)}M`;
    if (n >= 1000) return `${(n / 1000).toFixed(1)}k`;
    return n.toString();
  };

  return (
    <Box
      flexDirection="row"
      justifyContent="space-between"
      paddingX={1}
      paddingY={0}
      borderStyle="single"
      borderColor="blue"
    >
      {/* Left side: Session and path */}
      <Box flexDirection="row" gap={2}>
        <Text color="cyan" bold>
          TRON
        </Text>
        <Text color="gray">│</Text>
        <Text color="green">{displayPath}</Text>
      </Box>

      {/* Right side: Model and tokens */}
      <Box flexDirection="row" gap={2}>
        <Text color="yellow">{model.split('-').slice(0, 2).join('-')}</Text>
        <Text color="gray">│</Text>
        <Text color="magenta">
          ↓{formatTokens(tokenUsage.input)} ↑{formatTokens(tokenUsage.output)}
        </Text>
      </Box>
    </Box>
  );
}
