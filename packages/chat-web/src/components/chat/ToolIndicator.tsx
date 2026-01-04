/**
 * @fileoverview ToolIndicator Component
 *
 * Shows the currently running tool with animated status.
 */

import './ToolIndicator.css';

// =============================================================================
// Types
// =============================================================================

export interface ToolIndicatorProps {
  /** Tool name */
  toolName: string;
  /** Tool input/command */
  toolInput?: string | null;
}

// =============================================================================
// Component
// =============================================================================

export function ToolIndicator({ toolName, toolInput }: ToolIndicatorProps) {
  return (
    <div className="tool-indicator" role="status" aria-label={`Running ${toolName}`}>
      <div className="tool-indicator-header">
        <span className="tool-indicator-spinner">◐</span>
        <span className="tool-indicator-name">{toolName}</span>
        <span className="tool-indicator-status">running...</span>
      </div>

      {toolInput && (
        <div className="tool-indicator-input">
          <pre className="tool-input-text">{toolInput}</pre>
        </div>
      )}
    </div>
  );
}
