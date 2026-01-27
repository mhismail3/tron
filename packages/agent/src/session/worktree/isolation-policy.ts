/**
 * @fileoverview Isolation Policy
 *
 * Determines when sessions need isolated worktrees.
 * Extracted from WorktreeCoordinator for testability and modularity.
 */

import type { SessionId } from '../../events/types.js';

// =============================================================================
// Types
// =============================================================================

/**
 * Isolation mode determines when to create worktrees.
 */
export type IsolationMode = 'lazy' | 'always' | 'never';

/**
 * Options that affect isolation decisions.
 */
export interface IsolationOptions {
  /** Force isolation even if not needed */
  forceIsolation?: boolean;
  /** Parent session for fork operations */
  parentSessionId?: SessionId;
}

/**
 * Dependencies for IsolationPolicy.
 */
export interface IsolationPolicyDeps {
  /** Current isolation mode */
  isolationMode: IsolationMode;
  /** Get the current main directory owner */
  getMainDirectoryOwner: () => string | null;
}

// =============================================================================
// IsolationPolicy
// =============================================================================

/**
 * Determines when sessions need isolated worktrees.
 *
 * Isolation is needed when:
 * - Mode is 'always' (every session gets isolation)
 * - Force isolation is requested
 * - Session is forked from another
 * - Another session already owns the main directory
 */
export class IsolationPolicy {
  private isolationMode: IsolationMode;
  private getMainDirectoryOwner: () => string | null;

  constructor(deps: IsolationPolicyDeps) {
    this.isolationMode = deps.isolationMode;
    this.getMainDirectoryOwner = deps.getMainDirectoryOwner;
  }

  /**
   * Determine if a session needs an isolated worktree.
   */
  shouldIsolate(sessionId: SessionId, options: IsolationOptions = {}): boolean {
    // Never mode - always use main directory
    if (this.isolationMode === 'never') {
      return false;
    }

    // Always mode - always isolate
    if (this.isolationMode === 'always') {
      return true;
    }

    // Force isolation requested
    if (options.forceIsolation) {
      return true;
    }

    // Forked session - must isolate
    if (options.parentSessionId) {
      return true;
    }

    // Another session already owns the main directory
    const mainOwner = this.getMainDirectoryOwner();
    if (mainOwner && mainOwner !== (sessionId as string)) {
      return true;
    }

    // First session in lazy mode - no isolation needed
    return false;
  }

  /**
   * Get the current isolation mode.
   */
  getMode(): IsolationMode {
    return this.isolationMode;
  }
}

// =============================================================================
// Factory
// =============================================================================

/**
 * Create an IsolationPolicy instance.
 */
export function createIsolationPolicy(deps: IsolationPolicyDeps): IsolationPolicy {
  return new IsolationPolicy(deps);
}
