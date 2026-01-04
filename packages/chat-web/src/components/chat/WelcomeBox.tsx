/**
 * @fileoverview WelcomeBox Component
 *
 * Displays session information at the start of a conversation.
 */

import './WelcomeBox.css';

// =============================================================================
// Types
// =============================================================================

export interface WelcomeBoxProps {
  /** Current model */
  model: string;
  /** Working directory path */
  workingDirectory: string;
  /** Git branch name */
  gitBranch?: string;
}

// =============================================================================
// Component
// =============================================================================

export function WelcomeBox({
  model,
  workingDirectory,
  gitBranch,
}: WelcomeBoxProps) {
  // Extract project name from path
  const projectName = workingDirectory.split('/').pop() || workingDirectory;

  // Format model name for display
  const displayModel = model.replace('claude-', '').replace(/-\d+$/, '');

  return (
    <div className="welcome-box" role="banner" aria-label="Session information">
      <div className="welcome-header">
        <span className="welcome-icon">✦</span>
        <span className="welcome-title">Tron Chat</span>
      </div>

      <div className="welcome-details">
        <div className="welcome-row">
          <span className="welcome-label">Model</span>
          <span className="welcome-value">{displayModel}</span>
        </div>

        <div className="welcome-row">
          <span className="welcome-label">Project</span>
          <span className="welcome-value">{projectName}</span>
        </div>

        {gitBranch && (
          <div className="welcome-row">
            <span className="welcome-label">Branch</span>
            <span className="welcome-value git-branch">
              <span className="branch-icon">⎇</span>
              {gitBranch}
            </span>
          </div>
        )}

        <div className="welcome-row">
          <span className="welcome-label">Path</span>
          <span className="welcome-value path">{workingDirectory}</span>
        </div>
      </div>

      <div className="welcome-footer">
        <span className="welcome-hint">Type a message to start</span>
      </div>
    </div>
  );
}
