/**
 * @fileoverview ThinkingBlock Component
 *
 * Animated thinking indicator with pulsing bars and optional thinking text.
 * Uses CSS animations for smooth, performant animation.
 */

import { useState, useCallback, type ReactNode } from 'react';
import './ThinkingBlock.css';

// =============================================================================
// Types
// =============================================================================

export interface ThinkingBlockProps {
  /** Label to show next to the bars */
  label?: string;
  /** Number of bars to display */
  barCount?: number;
  /** Thinking text content */
  thinkingText?: string;
  /** Additional CSS class */
  className?: string;
  /** Custom header content */
  header?: ReactNode;
}

// =============================================================================
// Constants
// =============================================================================

const DEFAULT_BAR_COUNT = 5;
const COLLAPSE_THRESHOLD = 200; // chars
const ANIMATION_INTERVAL_MS = 80;

// =============================================================================
// Component
// =============================================================================

export function ThinkingBlock({
  label = 'Thinking',
  barCount = DEFAULT_BAR_COUNT,
  thinkingText,
  className = '',
  header,
}: ThinkingBlockProps) {
  const [isExpanded, setIsExpanded] = useState(false);

  const handleToggle = useCallback(() => {
    setIsExpanded((prev) => !prev);
  }, []);

  // Determine if content should be collapsed by default
  const shouldCollapse = thinkingText && thinkingText.length > COLLAPSE_THRESHOLD;
  const isCollapsed = shouldCollapse && !isExpanded;

  const blockClasses = ['thinking-block', className].filter(Boolean).join(' ');

  const contentClasses = ['thinking-content', isCollapsed && 'collapsed']
    .filter(Boolean)
    .join(' ');

  return (
    <div
      className={blockClasses}
      role="status"
      aria-busy="true"
      aria-label={label}
    >
      {/* Header with bars and label */}
      <div className="thinking-header">
        {header || (
          <>
            <div className="thinking-bars">
              {Array.from({ length: barCount }, (_, i) => (
                <span
                  key={i}
                  className="thinking-bar"
                  style={{
                    animationDelay: `${i * ANIMATION_INTERVAL_MS}ms`,
                    animationName: 'thinking-pulse',
                  }}
                />
              ))}
            </div>
            <span className="thinking-label">{label}</span>
          </>
        )}

        {/* Expand/collapse button for long content */}
        {shouldCollapse && (
          <button
            className="thinking-toggle"
            onClick={handleToggle}
            aria-label={isExpanded ? 'Collapse thinking' : 'Expand thinking'}
            type="button"
          >
            {isExpanded ? '▴ Collapse' : '▾ Expand'}
          </button>
        )}
      </div>

      {/* Thinking text content */}
      {thinkingText && (
        <div className={contentClasses}>
          <pre className="thinking-text">{thinkingText}</pre>
        </div>
      )}
    </div>
  );
}
