/**
 * @fileoverview Animated Spinner Component
 *
 * A lightweight animated spinner for "Thinking" states.
 * Uses ASCII/Unicode characters - NO emojis.
 */
import React, { useState, useEffect } from 'react';
import { Text } from 'ink';
import { inkColors } from '../theme.js';

// Braille spinner frames (smooth animation)
const SPINNER_FRAMES = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
const FRAME_INTERVAL = 80; // ms between frames

export interface SpinnerProps {
  /** Label to show next to spinner */
  label?: string;
  /** Color of the spinner */
  color?: string;
}

export function Spinner({ label = 'Thinking', color = inkColors.spinner }: SpinnerProps): React.ReactElement {
  const [frameIndex, setFrameIndex] = useState(0);

  useEffect(() => {
    const timer = setInterval(() => {
      setFrameIndex((current) => (current + 1) % SPINNER_FRAMES.length);
    }, FRAME_INTERVAL);

    return () => clearInterval(timer);
  }, []);

  const frame = SPINNER_FRAMES[frameIndex] ?? SPINNER_FRAMES[0];

  return (
    <Text>
      <Text color={color}>{frame}</Text>
      <Text color={inkColors.label}> {label}</Text>
    </Text>
  );
}
