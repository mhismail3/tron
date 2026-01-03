/**
 * @fileoverview Pulsing Bar Thinking Indicator
 *
 * Animated bars that pulse up and down randomly to indicate thinking/processing.
 * Uses block characters: ▁ ▂ ▃ ▄ ▅
 */
import React, { useState, useEffect, useRef } from 'react';
import { Text, Box } from 'ink';
import { inkColors, thinkingBars, icons } from '../theme.js';

// =============================================================================
// Types
// =============================================================================

export interface ThinkingIndicatorProps {
  /** Label to show next to the bars */
  label?: string;
  /** Color for the bars */
  color?: string;
  /** Number of bars to display */
  barCount?: number;
}

// =============================================================================
// Component
// =============================================================================

export function ThinkingIndicator({
  label = 'Thinking',
  color = inkColors.spinner,
  barCount = thinkingBars.width,
}: ThinkingIndicatorProps): React.ReactElement {
  // Each bar has its own height (index into chars array)
  const [barHeights, setBarHeights] = useState<number[]>(
    Array(barCount).fill(0).map(() => Math.floor(Math.random() * thinkingBars.chars.length))
  );

  // Direction of each bar: 1 = rising, -1 = falling
  const directions = useRef<number[]>(
    Array(barCount).fill(0).map(() => (Math.random() > 0.5 ? 1 : -1))
  );

  useEffect(() => {
    const timer = setInterval(() => {
      setBarHeights((prev) => {
        return prev.map((height, idx) => {
          // Randomly decide if this bar should move
          if (Math.random() > 0.7) {
            // Small chance to change direction
            if (Math.random() > 0.8) {
              const currentDir = directions.current[idx] ?? 1;
              directions.current[idx] = -currentDir;
            }
          }

          // Calculate new height
          const dir = directions.current[idx] ?? 1;
          let newHeight = height + dir;

          // Bounce at boundaries
          if (newHeight >= thinkingBars.chars.length) {
            newHeight = thinkingBars.chars.length - 2;
            directions.current[idx] = -1;
          } else if (newHeight < 0) {
            newHeight = 1;
            directions.current[idx] = 1;
          }

          return newHeight;
        });
      });
    }, thinkingBars.intervalMs);

    return () => clearInterval(timer);
  }, [barCount]);

  return (
    <Box flexDirection="row" gap={1}>
      <Text color={inkColors.dim}>{icons.thinking}</Text>
      <Box flexDirection="row">
        {barHeights.map((height, idx) => (
          <Text key={idx} color={color}>
            {thinkingBars.chars[height] ?? thinkingBars.chars[0]}
          </Text>
        ))}
      </Box>
      <Text color={inkColors.label}>{label}</Text>
    </Box>
  );
}

export default ThinkingIndicator;
