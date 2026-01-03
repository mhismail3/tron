/**
 * @fileoverview Status Indicator Component
 *
 * Displays current status with colored icon.
 * Design: Simple status display outside the main boxes.
 */
import React from 'react';
import { Box, Text } from 'ink';
import { inkColors } from '../theme.js';

export interface StatusIndicatorProps {
  status: string;
  error?: string | null;
}

function getStatusIcon(status: string): { icon: string; color: string } {
  const s = status.toLowerCase();
  if (s === 'ready') return { icon: '○', color: inkColors.statusReady };
  if (s.includes('thinking') || s.includes('processing')) return { icon: '◐', color: inkColors.statusThinking };
  if (s.includes('running')) return { icon: '◑', color: inkColors.statusRunning };
  if (s.includes('error')) return { icon: '○', color: inkColors.statusError };
  if (s.includes('hook')) return { icon: '◉', color: inkColors.statusHook };
  if (s.includes('initializing')) return { icon: '◌', color: inkColors.statusInit };
  return { icon: '◌', color: inkColors.statusInit };
}

export function StatusIndicator({
  status,
  error,
}: StatusIndicatorProps): React.ReactElement {
  const { icon, color } = getStatusIcon(status);

  return (
    <Box flexDirection="row" paddingX={2} marginY={0}>
      <Text color={color}>{icon}</Text>
      <Text color={inkColors.value}> {status}</Text>
      {error && (
        <Text color={inkColors.error}> - {error.slice(0, 50)}{error.length > 50 ? '...' : ''}</Text>
      )}
    </Box>
  );
}
