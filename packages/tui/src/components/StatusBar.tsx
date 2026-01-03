/**
 * @fileoverview Status Bar Component
 *
 * Displays metrics footer: model, token usage, cost, and git info.
 * Design: Clean metrics line below the prompt box.
 */
import React from 'react';
import { Box, Text } from 'ink';
import { inkColors } from '../theme.js';

export interface StatusBarProps {
  status: string;
  error: string | null;
  tokenUsage?: { input: number; output: number };
  model?: string;
  gitBranch?: string;
  gitWorktree?: string;
  contextLimit?: number; // Max context tokens for the model
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

// Context limits per model (in tokens)
const CONTEXT_LIMITS: Record<string, number> = {
  'opus': 200000,
  'sonnet': 200000,
  'haiku': 200000,
  'gpt-4o': 128000,
  'gpt-4': 128000,
  'gemini': 1000000,
  'default': 200000,
};

function formatTokens(n: number): string {
  if (n >= 1000000) return `${(n / 1000000).toFixed(1)}M`;
  if (n >= 1000) return `${Math.round(n / 1000)}K`;
  return n.toString();
}

function estimateCost(model: string, input: number, output: number): string {
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

function getContextLimit(model: string): number {
  const modelLower = model.toLowerCase();
  for (const [key, limit] of Object.entries(CONTEXT_LIMITS)) {
    if (modelLower.includes(key)) {
      return limit;
    }
  }
  return CONTEXT_LIMITS['default']!;
}

export function StatusBar({
  tokenUsage,
  model = '',
  gitBranch,
  gitWorktree,
  contextLimit,
}: StatusBarProps): React.ReactElement {
  const totalInput = tokenUsage?.input ?? 0;
  const totalOutput = tokenUsage?.output ?? 0;
  const totalTokens = totalInput + totalOutput;
  const limit = contextLimit ?? getContextLimit(model);
  const usagePercent = limit > 0 ? Math.round((totalInput / limit) * 100) : 0;

  return (
    <Box flexDirection="row" justifyContent="space-between" paddingX={2} marginTop={0}>
      {/* Left: Model, Tokens, Cost - all uniform color */}
      <Box flexDirection="row" gap={2}>
        {model && (
          <Text color={inkColors.statusBar}>{formatModelShort(model)}</Text>
        )}

        {totalTokens > 0 ? (
          <>
            <Text color={inkColors.statusBar}>
              {formatTokens(totalInput)}/{formatTokens(totalOutput)}
            </Text>
            <Text color={inkColors.statusBar}>({usagePercent}%)</Text>
            <Text color={inkColors.statusBar}>
              {estimateCost(model, totalInput, totalOutput)}
            </Text>
          </>
        ) : (
          <Text color={inkColors.statusBar}>—</Text>
        )}
      </Box>

      {/* Right: Git Info - same uniform color */}
      <Box flexDirection="row" gap={2}>
        {gitWorktree && (
          <Text color={inkColors.statusBar}>{gitWorktree}</Text>
        )}

        {gitBranch && (
          <Text color={inkColors.statusBar}>{gitBranch}</Text>
        )}

        {!gitBranch && !gitWorktree && totalTokens === 0 && (
          <Text color={inkColors.statusBar}>Ctrl+C: exit</Text>
        )}
      </Box>
    </Box>
  );
}
