/**
 * @fileoverview Model Switcher Submenu Component
 *
 * An interactive submenu for selecting and switching between AI models.
 * Features:
 * - Scrollable list of models organized by tier
 * - Rich model metadata display (context window, cost, capabilities)
 * - Visual indicators for current model and recommendations
 * - Arrow key navigation with selection
 */
import React, { useMemo } from 'react';
import { Box, Text } from 'ink';
import {
  ANTHROPIC_MODELS,
  getTierIcon,
  formatContextWindow,
  type ModelInfo,
} from '@tron/agent';
import { inkColors } from '../theme.js';

// =============================================================================
// Types
// =============================================================================

export interface ModelSwitcherProps {
  /** Currently selected model ID */
  currentModel: string;
  /** Index of highlighted model in the list */
  selectedIndex: number;
  /** Callback when a model is selected */
  onSelect: (model: ModelInfo) => void;
  /** Callback to cancel model selection */
  onCancel: () => void;
  /** Maximum number of visible models at once */
  maxVisible?: number;
}

// =============================================================================
// Component
// =============================================================================

export function ModelSwitcher({
  currentModel,
  selectedIndex,
  onSelect: _onSelect,
  onCancel: _onCancel,
  maxVisible = 6,
}: ModelSwitcherProps): React.ReactElement {
  // Get all models sorted by tier, then legacy status, then date
  // Order: current models first (by tier), then legacy models (by tier)
  const models = useMemo(() => {
    const tierOrder = { opus: 0, sonnet: 1, haiku: 2 };
    return [...ANTHROPIC_MODELS].sort((a, b) => {
      // First: non-legacy before legacy
      const legacyDiff = (a.legacy ? 1 : 0) - (b.legacy ? 1 : 0);
      if (legacyDiff !== 0) return legacyDiff;
      // Then: by tier (opus, sonnet, haiku)
      const tierDiff = tierOrder[a.tier] - tierOrder[b.tier];
      if (tierDiff !== 0) return tierDiff;
      // Within same tier and legacy status, sort by release date (newest first)
      return b.releaseDate.localeCompare(a.releaseDate);
    });
  }, []);

  // Calculate visible range for scrolling
  const visibleRange = useMemo(() => {
    const total = models.length;
    if (total <= maxVisible) {
      return { start: 0, end: total };
    }

    // Center selection in visible range
    const halfVisible = Math.floor(maxVisible / 2);
    let start = Math.max(0, selectedIndex - halfVisible);
    let end = start + maxVisible;

    if (end > total) {
      end = total;
      start = Math.max(0, end - maxVisible);
    }

    return { start, end };
  }, [models.length, selectedIndex, maxVisible]);

  const visibleModels = models.slice(visibleRange.start, visibleRange.end);
  const hasMoreAbove = visibleRange.start > 0;
  const hasMoreBelow = visibleRange.end < models.length;

  return (
    <Box
      flexDirection="column"
      borderStyle="round"
      borderColor={inkColors.menuBorder}
      paddingX={1}
    >
      {/* Header */}
      <Box marginBottom={0}>
        <Text color={inkColors.menuHeader} bold>Switch Model</Text>
        <Text color={inkColors.label}> ({selectedIndex + 1}/{models.length})</Text>
      </Box>

      {/* Current model indicator */}
      <Box marginBottom={0}>
        <Text color={inkColors.dim}>Current: </Text>
        <Text color={inkColors.value}>{currentModel}</Text>
      </Box>

      {/* Scroll up indicator */}
      {hasMoreAbove && (
        <Text color={inkColors.dim}>  {'\u2191'} more</Text>
      )}

      {/* Model list */}
      {visibleModels.map((model, idx) => {
        const actualIndex = visibleRange.start + idx;
        const isSelected = actualIndex === selectedIndex;
        const isCurrent = model.id === currentModel;

        return (
          <ModelRow
            key={model.id}
            model={model}
            isSelected={isSelected}
            isCurrent={isCurrent}
          />
        );
      })}

      {/* Scroll down indicator */}
      {hasMoreBelow && (
        <Text color={inkColors.dim}>  {'\u2193'} more</Text>
      )}

      {/* Keyboard hints */}
      <Box
        marginTop={0}
        borderStyle="single"
        borderTop
        borderBottom={false}
        borderLeft={false}
        borderRight={false}
        borderColor={inkColors.border}
      >
        <Text color={inkColors.dim}>{'\u2191\u2193'} navigate  Enter select  Esc cancel</Text>
      </Box>
    </Box>
  );
}

// =============================================================================
// Model Row Sub-component
// =============================================================================

interface ModelRowProps {
  model: ModelInfo;
  isSelected: boolean;
  isCurrent: boolean;
}

function ModelRow({ model, isSelected, isCurrent }: ModelRowProps): React.ReactElement {
  const tierIcon = getTierIcon(model.tier);
  const contextStr = formatContextWindow(model.contextWindow);

  // Wrap selected row in a border for clear visual indication
  const rowContent = (
    <Box flexDirection="column">
      {/* Main row */}
      <Box flexDirection="row">
        {/* Selection indicator */}
        <Text color={isSelected ? inkColors.menuSelected : inkColors.label}>
          {isSelected ? '\u25B6 ' : '  '}
        </Text>

        {/* Tier indicator */}
        <Text color={isSelected ? inkColors.menuSelected : getTierColor(model.tier)}>
          {tierIcon}{' '}
        </Text>

        {/* Model name */}
        <Text color={isSelected ? inkColors.menuSelected : inkColors.menuItem} bold={isSelected}>
          {model.shortName}
        </Text>

        {/* Current indicator - highlight strongly */}
        {isCurrent && (
          <Text color={inkColors.accent} bold> (current)</Text>
        )}

        {/* Legacy badge - only show when NOT selected to reduce noise */}
        {model.legacy && !isSelected && (
          <Text color={inkColors.dim}> (legacy)</Text>
        )}
      </Box>

      {/* Details row (only for selected) */}
      {isSelected && (
        <Box flexDirection="row" marginLeft={2}>
          <Text color={inkColors.dim}>
            {contextStr} ctx
          </Text>
          <Text color={inkColors.dim}> {'\u2022'} </Text>
          <Text color={inkColors.dim}>
            {model.maxOutput.toLocaleString()} max out
          </Text>
          {model.supportsThinking && (
            <>
              <Text color={inkColors.dim}> {'\u2022'} </Text>
              <Text color={inkColors.mint}>thinking</Text>
            </>
          )}
          {model.legacy && (
            <>
              <Text color={inkColors.dim}> {'\u2022'} </Text>
              <Text color={inkColors.warning}>legacy</Text>
            </>
          )}
        </Box>
      )}

      {/* Description (only for selected) */}
      {isSelected && (
        <Box marginLeft={2}>
          <Text color={inkColors.value}>{model.description}</Text>
        </Box>
      )}
    </Box>
  );

  // Add border around selected item for clear visual grouping
  if (isSelected) {
    return (
      <Box
        flexDirection="column"
        borderStyle="single"
        borderColor={inkColors.menuSelected}
        paddingX={1}
        marginY={0}
      >
        {rowContent}
      </Box>
    );
  }

  return rowContent;
}

// =============================================================================
// Helper Functions
// =============================================================================

function getTierColor(tier: 'opus' | 'sonnet' | 'haiku'): string {
  switch (tier) {
    case 'opus': return inkColors.accent;      // Bright green for most capable
    case 'sonnet': return inkColors.menuItem;  // Default for balanced
    case 'haiku': return inkColors.mint;       // Mint for fast
  }
}

// =============================================================================
// Exports
// =============================================================================

export { ANTHROPIC_MODELS };
