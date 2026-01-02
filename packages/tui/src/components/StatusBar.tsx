/**
 * @fileoverview Status Bar Component
 *
 * Displays current status, token usage, cost estimate, and git info.
 * Design: Clean footer with essential session metrics.
 */
import React from 'react';
import { Box, Text } from 'ink';

export interface StatusBarProps {
  status: string;
  error: string | null;
  tokenUsage?: { input: number; output: number };
  model?: string;
  gitBranch?: string;
  gitWorktree?: string;
}

// Approximate cost per 1M tokens (rough estimates)
const COST_PER_MILLION: Record<string, { input: number; output: number }> = {
  'opus': { input: 15, output: 75 },
  'sonnet': { input: 3, output: 15 },
  'haiku': { input: 0.25, output: 1.25 },
  'gpt-4o': { input: 2.5, output: 10 },
  'gpt-4': { input: 30, output: 60 },
  'gemini': { input: 0.075, output: 0.3 },
  'default': { input: 3, output: 15 },
};

function getStatusIcon(status: string): { icon: string; color: string } {
  const s = status.toLowerCase();
  if (s === 'ready') return { icon: '●', color: 'green' };
  if (s.includes('thinking') || s.includes('processing')) return { icon: '◐', color: 'yellow' };
  if (s.includes('running')) return { icon: '◑', color: 'blue' };
  if (s.includes('error')) return { icon: '○', color: 'red' };
  if (s.includes('hook')) return { icon: '◉', color: 'magenta' };
  return { icon: '◌', color: 'gray' };
}

function formatTokens(n: number): string {
  if (n >= 1000000) return `${(n / 1000000).toFixed(1)}M`;
  if (n >= 1000) return `${Math.round(n / 1000)}K`;
  return n.toString();
}

function estimateCost(model: string, input: number, output: number): string {
  // Find matching cost tier
  let tier = COST_PER_MILLION['default']!;
  const modelLower = model.toLowerCase();
  for (const [key, value] of Object.entries(COST_PER_MILLION)) {
    if (modelLower.includes(key)) {
      tier = value;
      break;
    }
  }

  const cost = (input / 1000000) * tier.input + (output / 1000000) * tier.output;
  if (cost < 0.01) return '$0.00';
  if (cost < 1) return `$${cost.toFixed(2)}`;
  return `$${cost.toFixed(2)}`;
}

function formatModelShort(model: string): string {
  if (model.includes('opus-4-5')) return 'Opus 4.5';
  if (model.includes('opus-4')) return 'Opus 4';
  if (model.includes('sonnet-4')) return 'Sonnet 4';
  if (model.includes('sonnet')) return 'Sonnet';
  if (model.includes('haiku')) return 'Haiku';
  if (model.includes('gpt-4o')) return 'GPT-4o';
  if (model.includes('gpt-4')) return 'GPT-4';
  if (model.includes('gemini')) return 'Gemini';
  return model.slice(0, 12);
}

export function StatusBar({
  status,
  error,
  tokenUsage,
  model = '',
  gitBranch,
  gitWorktree,
}: StatusBarProps): React.ReactElement {
  const { icon, color } = getStatusIcon(status);
  const totalTokens = (tokenUsage?.input ?? 0) + (tokenUsage?.output ?? 0);

  return (
    <Box flexDirection="row" justifyContent="space-between" paddingX={1} marginTop={1}>
      {/* Left: Status */}
      <Box flexDirection="row" gap={2}>
        <Box>
          <Text color={color as any}>{icon}</Text>
          <Text color="white"> {status}</Text>
        </Box>

        {/* Error if present */}
        {error && (
          <Text color="red"> │ {error.slice(0, 40)}{error.length > 40 ? '...' : ''}</Text>
        )}
      </Box>

      {/* Right: Metrics */}
      <Box flexDirection="row" gap={2}>
        {model && (
          <Text color="gray">{formatModelShort(model)}</Text>
        )}

        {tokenUsage && totalTokens > 0 && (
          <>
            <Text color="gray">│</Text>
            <Text color="magenta">
              {formatTokens(tokenUsage.input)}/{formatTokens(tokenUsage.output)}
            </Text>
            <Text color="gray">│</Text>
            <Text color="green">
              {estimateCost(model, tokenUsage.input, tokenUsage.output)}
            </Text>
          </>
        )}

        {gitWorktree && (
          <>
            <Text color="gray">│</Text>
            <Text color="gray">Worktree: </Text>
            <Text color="blue">{gitWorktree}</Text>
          </>
        )}

        {gitBranch && (
          <>
            <Text color="gray">│</Text>
            <Text color="gray">Branch: </Text>
            <Text color="blue">{gitBranch}</Text>
          </>
        )}

        {!gitBranch && !gitWorktree && !tokenUsage && (
          <Text color="gray">Ctrl+C: exit │ Ctrl+L: clear</Text>
        )}
      </Box>
    </Box>
  );
}
