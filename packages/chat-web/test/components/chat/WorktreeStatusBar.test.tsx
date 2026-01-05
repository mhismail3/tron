/**
 * @fileoverview WorktreeStatusBar Tests
 */

import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { WorktreeStatusBar } from '../../../src/components/chat/WorktreeStatusBar.js';
import type { WorktreeStatus } from '../../../src/store/worktree-store.js';

describe('WorktreeStatusBar', () => {
  const defaultWorktreeStatus: WorktreeStatus = {
    hasWorktree: true,
    worktree: {
      isolated: true,
      branch: 'session/abc123',
      baseCommit: 'def456',
      path: '/path/to/.worktrees/abc123',
      hasUncommittedChanges: false,
      commitCount: 0,
    },
  };

  describe('when no worktree', () => {
    it('should render nothing when hasWorktree is false', () => {
      const { container } = render(
        <WorktreeStatusBar status={{ hasWorktree: false }} />
      );
      expect(container.firstChild).toBeNull();
    });

    it('should render nothing when status is undefined', () => {
      const { container } = render(<WorktreeStatusBar />);
      expect(container.firstChild).toBeNull();
    });
  });

  describe('when has worktree', () => {
    it('should display the branch name', () => {
      render(<WorktreeStatusBar status={defaultWorktreeStatus} />);
      expect(screen.getByText('session/abc123')).toBeDefined();
    });

    it('should display isolated indicator', () => {
      render(<WorktreeStatusBar status={defaultWorktreeStatus} />);
      expect(screen.getByText('Isolated')).toBeDefined();
    });

    it('should show "0 commits" when no commits', () => {
      render(<WorktreeStatusBar status={defaultWorktreeStatus} />);
      expect(screen.getByText('0 commits')).toBeDefined();
    });

    it('should show correct commit count', () => {
      render(
        <WorktreeStatusBar
          status={{
            ...defaultWorktreeStatus,
            worktree: {
              ...defaultWorktreeStatus.worktree!,
              commitCount: 5,
            },
          }}
        />
      );
      expect(screen.getByText('5 commits')).toBeDefined();
    });

    it('should show "1 commit" singular', () => {
      render(
        <WorktreeStatusBar
          status={{
            ...defaultWorktreeStatus,
            worktree: {
              ...defaultWorktreeStatus.worktree!,
              commitCount: 1,
            },
          }}
        />
      );
      expect(screen.getByText('1 commit')).toBeDefined();
    });

    it('should indicate uncommitted changes', () => {
      render(
        <WorktreeStatusBar
          status={{
            ...defaultWorktreeStatus,
            worktree: {
              ...defaultWorktreeStatus.worktree!,
              hasUncommittedChanges: true,
            },
          }}
        />
      );
      expect(screen.getByText('●')).toBeDefined(); // Changed indicator
    });

    it('should not show changed indicator when no uncommitted changes', () => {
      const { container } = render(
        <WorktreeStatusBar status={defaultWorktreeStatus} />
      );
      // The ● indicator should not be present
      expect(container.textContent).not.toContain('●');
    });
  });

  describe('commit button', () => {
    it('should call onCommit when clicked', () => {
      const onCommit = vi.fn();
      render(
        <WorktreeStatusBar
          status={{
            ...defaultWorktreeStatus,
            worktree: {
              ...defaultWorktreeStatus.worktree!,
              hasUncommittedChanges: true,
            },
          }}
          onCommit={onCommit}
        />
      );

      const commitButton = screen.getByRole('button', { name: /commit/i });
      fireEvent.click(commitButton);

      expect(onCommit).toHaveBeenCalledTimes(1);
    });

    it('should be disabled when no uncommitted changes', () => {
      const onCommit = vi.fn();
      render(
        <WorktreeStatusBar
          status={defaultWorktreeStatus}
          onCommit={onCommit}
        />
      );

      const commitButton = screen.getByRole('button', { name: /commit/i });
      expect(commitButton).toHaveProperty('disabled', true);
    });

    it('should be disabled when isLoading', () => {
      const onCommit = vi.fn();
      render(
        <WorktreeStatusBar
          status={{
            ...defaultWorktreeStatus,
            worktree: {
              ...defaultWorktreeStatus.worktree!,
              hasUncommittedChanges: true,
            },
          }}
          onCommit={onCommit}
          isLoading={true}
        />
      );

      const commitButton = screen.getByRole('button', { name: /commit/i });
      expect(commitButton).toHaveProperty('disabled', true);
    });

    it('should not render commit button when onCommit is not provided', () => {
      render(
        <WorktreeStatusBar
          status={{
            ...defaultWorktreeStatus,
            worktree: {
              ...defaultWorktreeStatus.worktree!,
              hasUncommittedChanges: true,
            },
          }}
        />
      );

      expect(screen.queryByRole('button', { name: /commit/i })).toBeNull();
    });
  });

  describe('merge button', () => {
    it('should call onMerge when clicked', () => {
      const onMerge = vi.fn();
      render(
        <WorktreeStatusBar
          status={{
            ...defaultWorktreeStatus,
            worktree: {
              ...defaultWorktreeStatus.worktree!,
              commitCount: 3,
            },
          }}
          onMerge={onMerge}
        />
      );

      const mergeButton = screen.getByRole('button', { name: /merge/i });
      fireEvent.click(mergeButton);

      expect(onMerge).toHaveBeenCalledTimes(1);
    });

    it('should be disabled when no commits', () => {
      const onMerge = vi.fn();
      render(
        <WorktreeStatusBar
          status={defaultWorktreeStatus}
          onMerge={onMerge}
        />
      );

      const mergeButton = screen.getByRole('button', { name: /merge/i });
      expect(mergeButton).toHaveProperty('disabled', true);
    });

    it('should be disabled when isLoading', () => {
      const onMerge = vi.fn();
      render(
        <WorktreeStatusBar
          status={{
            ...defaultWorktreeStatus,
            worktree: {
              ...defaultWorktreeStatus.worktree!,
              commitCount: 3,
            },
          }}
          onMerge={onMerge}
          isLoading={true}
        />
      );

      const mergeButton = screen.getByRole('button', { name: /merge/i });
      expect(mergeButton).toHaveProperty('disabled', true);
    });

    it('should not render merge button when onMerge is not provided', () => {
      render(
        <WorktreeStatusBar
          status={{
            ...defaultWorktreeStatus,
            worktree: {
              ...defaultWorktreeStatus.worktree!,
              commitCount: 3,
            },
          }}
        />
      );

      expect(screen.queryByRole('button', { name: /merge/i })).toBeNull();
    });
  });

  describe('loading state', () => {
    it('should show loading indicator when isLoading', () => {
      render(
        <WorktreeStatusBar
          status={defaultWorktreeStatus}
          isLoading={true}
        />
      );

      expect(screen.getByText('...')).toBeDefined();
    });
  });

  describe('accessibility', () => {
    it('should have accessible branch name', () => {
      render(<WorktreeStatusBar status={defaultWorktreeStatus} />);

      const branchElement = screen.getByTitle('/path/to/.worktrees/abc123');
      expect(branchElement).toBeDefined();
    });
  });
});
