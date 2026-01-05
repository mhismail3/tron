/**
 * @fileoverview Worktree status bar component
 *
 * Displays worktree information for a session including branch,
 * commit count, and actions for committing and merging.
 */

import React from 'react';
import type { WorktreeStatus } from '../../store/worktree-store.js';

interface WorktreeStatusBarProps {
  /** Worktree status for the current session */
  status?: WorktreeStatus;
  /** Whether operations are in progress */
  isLoading?: boolean;
  /** Callback to commit changes */
  onCommit?: () => void;
  /** Callback to merge worktree to main */
  onMerge?: () => void;
}

export function WorktreeStatusBar({
  status,
  isLoading = false,
  onCommit,
  onMerge,
}: WorktreeStatusBarProps): React.ReactElement | null {
  // Don't render if no worktree
  if (!status?.hasWorktree || !status.worktree) {
    return null;
  }

  const { branch, path, hasUncommittedChanges, commitCount = 0, isolated } = status.worktree;

  const commitLabel = commitCount === 1 ? '1 commit' : `${commitCount} commits`;
  const canCommit = hasUncommittedChanges && !isLoading;
  const canMerge = commitCount > 0 && !isLoading;

  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 'var(--space-md)',
        padding: 'var(--space-xs) var(--space-sm)',
        background: 'var(--bg-surface)',
        borderRadius: 'var(--radius-sm)',
        border: '1px solid var(--border-subtle)',
        fontSize: 'var(--text-xs)',
        fontFamily: 'var(--font-mono)',
      }}
    >
      {/* Branch indicator */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 'var(--space-xs)',
        }}
        title={path}
      >
        <span style={{ color: 'var(--accent)', opacity: 0.7 }}>⎇</span>
        <span style={{ color: 'var(--text-secondary)' }}>{branch}</span>
        {hasUncommittedChanges && (
          <span
            style={{
              color: 'var(--warning)',
              fontSize: 'var(--text-2xs)',
            }}
            title="Uncommitted changes"
          >
            ●
          </span>
        )}
      </div>

      {/* Isolated badge */}
      {isolated && (
        <span
          style={{
            padding: '1px 6px',
            background: 'var(--bg-elevated)',
            border: '1px solid var(--border-default)',
            borderRadius: 'var(--radius-full)',
            color: 'var(--text-muted)',
            fontSize: 'var(--text-2xs)',
            textTransform: 'uppercase',
            letterSpacing: '0.05em',
          }}
        >
          Isolated
        </span>
      )}

      {/* Commit count */}
      <span style={{ color: 'var(--text-muted)' }}>
        {commitLabel}
      </span>

      {/* Loading indicator */}
      {isLoading && (
        <span
          style={{
            color: 'var(--text-dim)',
            animation: 'pulse 1s infinite',
          }}
        >
          ...
        </span>
      )}

      {/* Actions */}
      <div style={{ display: 'flex', gap: 'var(--space-xs)', marginLeft: 'auto' }}>
        {/* Commit button */}
        {onCommit && (
          <button
            onClick={onCommit}
            disabled={!canCommit}
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 'var(--space-2xs)',
              padding: 'var(--space-2xs) var(--space-sm)',
              background: canCommit ? 'var(--accent-subtle)' : 'transparent',
              border: `1px solid ${canCommit ? 'var(--accent)' : 'var(--border-subtle)'}`,
              borderRadius: 'var(--radius-sm)',
              color: canCommit ? 'var(--accent)' : 'var(--text-dim)',
              fontSize: 'var(--text-xs)',
              fontFamily: 'var(--font-mono)',
              cursor: canCommit ? 'pointer' : 'not-allowed',
              opacity: canCommit ? 1 : 0.5,
              transition: 'all var(--transition-fast)',
            }}
            title={hasUncommittedChanges ? 'Commit changes' : 'No changes to commit'}
          >
            <span style={{ fontSize: '10px' }}>✓</span>
            <span>Commit</span>
          </button>
        )}

        {/* Merge button */}
        {onMerge && (
          <button
            onClick={onMerge}
            disabled={!canMerge}
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 'var(--space-2xs)',
              padding: 'var(--space-2xs) var(--space-sm)',
              background: canMerge ? 'var(--success-subtle)' : 'transparent',
              border: `1px solid ${canMerge ? 'var(--success)' : 'var(--border-subtle)'}`,
              borderRadius: 'var(--radius-sm)',
              color: canMerge ? 'var(--success)' : 'var(--text-dim)',
              fontSize: 'var(--text-xs)',
              fontFamily: 'var(--font-mono)',
              cursor: canMerge ? 'pointer' : 'not-allowed',
              opacity: canMerge ? 1 : 0.5,
              transition: 'all var(--transition-fast)',
            }}
            title={commitCount > 0 ? 'Merge to main' : 'No commits to merge'}
          >
            <span style={{ fontSize: '10px' }}>⎇</span>
            <span>Merge</span>
          </button>
        )}
      </div>
    </div>
  );
}
