/**
 * @fileoverview Status Indicator Component
 *
 * Displays current status with colored icon.
 * Design: Simple status display outside the main boxes.
 */
import React from 'react';
import { Box, Text } from 'ink';

export interface StatusIndicatorProps {
  status: string;
  error?: string | null;
}

function getStatusIcon(status: string): { icon: string; color: string } {
  const s = status.toLowerCase();
  if (s === 'ready') return { icon: '○', color: 'green' };
  if (s.includes('thinking') || s.includes('processing')) return { icon: '◐', color: 'yellow' };
  if (s.includes('running')) return { icon: '◑', color: 'blue' };
  if (s.includes('error')) return { icon: '○', color: 'red' };
  if (s.includes('hook')) return { icon: '◉', color: 'magenta' };
  if (s.includes('initializing')) return { icon: '◌', color: 'gray' };
  return { icon: '◌', color: 'gray' };
}

export function StatusIndicator({
  status,
  error,
}: StatusIndicatorProps): React.ReactElement {
  const { icon, color } = getStatusIcon(status);

  return (
    <Box flexDirection="row" paddingX={2} marginY={0}>
      <Text color={color as any}>{icon}</Text>
      <Text color="white"> {status}</Text>
      {error && (
        <Text color="red"> - {error.slice(0, 50)}{error.length > 50 ? '...' : ''}</Text>
      )}
    </Box>
  );
}
