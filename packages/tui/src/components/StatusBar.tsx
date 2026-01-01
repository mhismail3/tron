/**
 * @fileoverview Status Bar Component
 *
 * Displays current status and errors.
 */
import React from 'react';
import { Box, Text } from 'ink';
import type { StatusBarProps } from '../types.js';

export function StatusBar({ status, error }: StatusBarProps): React.ReactElement {
  return (
    <Box flexDirection="row" justifyContent="space-between" paddingX={1}>
      {/* Status */}
      <Box>
        <Text color="gray">
          {getStatusIcon(status)} {status}
        </Text>
      </Box>

      {/* Error if present */}
      {error && (
        <Box>
          <Text color="red">⚠ {error}</Text>
        </Box>
      )}

      {/* Help hint */}
      <Box>
        <Text color="gray">Ctrl+C: exit │ Ctrl+L: clear</Text>
      </Box>
    </Box>
  );
}

function getStatusIcon(status: string): string {
  switch (status.toLowerCase()) {
    case 'ready':
      return '●';
    case 'thinking...':
      return '◐';
    case 'processing':
      return '◑';
    case 'error':
      return '○';
    default:
      return '◌';
  }
}
