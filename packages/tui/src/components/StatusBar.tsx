/**
 * @fileoverview Status Bar Component
 *
 * Displays metrics footer: model, token usage, cost, and git info.
 * Design: Clean metrics line below the prompt box.
 *
 * Uses centralized usage tracking from @tron/core for accurate cost calculations.
 */
import React from 'react';
import { Box, Text } from 'ink';
import { inkColors } from '../theme.js';
import {
  calculateCost,
  formatCost,
  formatTokens,
  getContextLimit,
} from '@tron/core';

export interface StatusBarProps {
  status: string;
  error: string | null;
  tokenUsage?: {
    input: number;
    output: number;
    cacheCreation?: number;
    cacheRead?: number;
  };
  model?: string;
  gitBranch?: string;
  gitWorktree?: string;
  contextLimit?: number;
  /** Estimated tokens in current context (for accurate % calculation) */
  contextTokens?: number;
}

function formatModelShort(model: string): string {
  if (model.includes('opus-4-5')) return 'Opus 4.5';
  if (model.includes('opus-4')) return 'Opus 4';
  if (model.includes('sonnet-4-5')) return 'Sonnet 4.5';
  if (model.includes('sonnet-4')) return 'Sonnet 4';
  if (model.includes('sonnet')) return 'Sonnet';
  if (model.includes('haiku')) return 'Haiku';
  if (model.includes('gpt-4o')) return 'GPT-4o';
  if (model.includes('gpt-4')) return 'GPT-4';
  if (model.includes('gemini')) return 'Gemini';
  return model.slice(0, 12);
}

export function StatusBar({
  tokenUsage,
  model = '',
  gitBranch,
  gitWorktree,
  contextLimit,
  contextTokens,
}: StatusBarProps): React.ReactElement {
  const totalInput = tokenUsage?.input ?? 0;
  const totalOutput = tokenUsage?.output ?? 0;
  const totalTokens = totalInput + totalOutput;
  const limit = contextLimit ?? getContextLimit(model);

  // Use contextTokens if provided (more accurate), otherwise fall back to input tokens
  const contextSize = contextTokens ?? totalInput;
  const usagePercent = limit > 0 ? Math.round((contextSize / limit) * 100) : 0;

  // Calculate cost using the centralized module (handles cache pricing correctly)
  const cost = totalTokens > 0
    ? calculateCost(model, {
        inputTokens: totalInput,
        outputTokens: totalOutput,
        cacheCreationTokens: tokenUsage?.cacheCreation,
        cacheReadTokens: tokenUsage?.cacheRead,
      })
    : null;

  return (
    <Box flexDirection="row" justifyContent="space-between" paddingX={2} marginTop={0}>
      {/* Left: Model, Tokens, Cost - all uniform color */}
      <Box flexDirection="row" gap={2}>
        {model && (
          <Text color={inkColors.statusBar}>{formatModelShort(model)}</Text>
        )}

        {totalTokens > 0 && (
          <>
            <Text color={inkColors.statusBar}>
              {formatTokens(totalInput)}/{formatTokens(totalOutput)}
            </Text>
            <Text color={inkColors.statusBar}>({usagePercent}%)</Text>
            <Text color={inkColors.statusBar}>
              {cost ? formatCost(cost) : '$0.00'}
            </Text>
          </>
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
