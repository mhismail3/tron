/**
 * GenericResultViewer Component
 *
 * Fallback viewer for tool results that don't have
 * specialized viewers. Provides:
 * - Scrollable content area
 * - Collapse/expand
 * - Variant styling (success, error, info, default)
 * - Optional icon
 */

import { useState, useCallback } from 'react';
import './GenericResultViewer.css';

export interface GenericResultViewerProps {
  content: string;
  variant?: 'default' | 'success' | 'error' | 'info' | 'warning';
  icon?: string;
  maxHeight?: number;
}

export function GenericResultViewer({
  content,
  variant = 'default',
  icon,
  maxHeight = 400,
}: GenericResultViewerProps) {
  const [isExpanded, setIsExpanded] = useState(true);

  const lines = content.split('\n');
  const lineCount = lines.filter((l) => l.trim()).length;
  const isLong = lineCount > 10;

  const toggleExpand = useCallback(() => {
    setIsExpanded((prev) => !prev);
  }, []);

  // Get default icon based on variant if not provided
  const displayIcon =
    icon ||
    (variant === 'success'
      ? '✓'
      : variant === 'error'
        ? '✗'
        : variant === 'warning'
          ? '⚠'
          : variant === 'info'
            ? 'ℹ'
            : '◇');

  return (
    <div className={`generic-viewer generic-viewer--${variant}`}>
      {/* Header */}
      <div className="generic-header">
        <div className="generic-header-left">
          <span className="generic-icon">{displayIcon}</span>
          <span className="generic-summary">
            {lineCount} line{lineCount !== 1 ? 's' : ''}
          </span>
        </div>
        <div className="generic-header-right">
          {isLong && (
            <button
              className="generic-toggle"
              onClick={toggleExpand}
              aria-expanded={isExpanded}
            >
              {isExpanded ? '▾ Collapse' : '▸ Expand'}
            </button>
          )}
        </div>
      </div>

      {/* Content */}
      {isExpanded && (
        <div className="generic-content" style={{ maxHeight }}>
          <pre className="generic-text">{content}</pre>
        </div>
      )}
    </div>
  );
}

export default GenericResultViewer;
