/**
 * @fileoverview Smart Compaction Trigger
 *
 * Determines when context compaction should happen based on
 * multiple signals: token ratio, progress events, and turn count.
 */

// =============================================================================
// Types
// =============================================================================

export interface CompactionTriggerInput {
  /** Current token usage ratio (0-1) */
  currentTokenRatio: number;
  /** Recent event types from the current cycle */
  recentEventTypes: string[];
  /** Recent Bash tool call commands */
  recentToolCalls: string[];
}

export interface CompactionTriggerResult {
  compact: boolean;
  reason: string;
}

export interface CompactionTriggerConfig {
  /** Token ratio that forces compaction (0-1) */
  triggerTokenThreshold?: number;
  /** Token ratio where compaction becomes more aggressive (0-1) */
  alertZoneThreshold?: number;
  /** Turns before auto-compaction in normal zone */
  defaultTurnFallback?: number;
  /** Turns before auto-compaction in alert zone */
  alertTurnFallback?: number;
}

// =============================================================================
// Constants (defaults)
// =============================================================================

const DEFAULT_TOKEN_THRESHOLD = 0.70;
const DEFAULT_ALERT_ZONE_THRESHOLD = 0.50;
const DEFAULT_DEFAULT_TURN_FALLBACK = 8;
const DEFAULT_ALERT_TURN_FALLBACK = 5;

const PROGRESS_TOOL_PATTERNS = [
  /\bgit\s+push\b/,
  /\bgh\s+pr\s+create\b/,
  /\bgh\s+pr\s+merge\b/,
  /\bgit\s+tag\b/,
];

// =============================================================================
// CompactionTrigger
// =============================================================================

export class CompactionTrigger {
  private turnsSinceCompaction = 0;
  private forceAlwaysEnabled = false;
  private tokenThreshold: number;
  private alertZoneThreshold: number;
  private defaultTurnFallback: number;
  private alertTurnFallback: number;

  constructor(config: CompactionTriggerConfig = {}) {
    this.tokenThreshold = config.triggerTokenThreshold ?? DEFAULT_TOKEN_THRESHOLD;
    this.alertZoneThreshold = config.alertZoneThreshold ?? DEFAULT_ALERT_ZONE_THRESHOLD;
    this.defaultTurnFallback = config.defaultTurnFallback ?? DEFAULT_DEFAULT_TURN_FALLBACK;
    this.alertTurnFallback = config.alertTurnFallback ?? DEFAULT_ALERT_TURN_FALLBACK;
  }

  setForceAlways(enabled: boolean): void {
    this.forceAlwaysEnabled = enabled;
  }

  shouldCompact(input: CompactionTriggerInput): CompactionTriggerResult {
    this.turnsSinceCompaction++;

    if (this.forceAlwaysEnabled) {
      return { compact: true, reason: 'force-always mode (testing)' };
    }

    // 1. Token threshold — safety net
    if (input.currentTokenRatio >= this.tokenThreshold) {
      return { compact: true, reason: `token ratio ${(input.currentTokenRatio * 100).toFixed(0)}% >= threshold` };
    }

    // 2. Progress signals
    if (input.recentEventTypes.includes('worktree.commit')) {
      return { compact: true, reason: 'commit detected — good compaction point' };
    }

    for (const cmd of input.recentToolCalls) {
      for (const pattern of PROGRESS_TOOL_PATTERNS) {
        if (pattern.test(cmd)) {
          return { compact: true, reason: 'progress signal: push/pr/tag detected' };
        }
      }
    }

    // 3. Turn-count fallback (lower in alert zone)
    const fallback = input.currentTokenRatio >= this.alertZoneThreshold
      ? this.alertTurnFallback
      : this.defaultTurnFallback;

    if (this.turnsSinceCompaction >= fallback) {
      return { compact: true, reason: `turn count fallback (${this.turnsSinceCompaction} turns)` };
    }

    return { compact: false, reason: 'no trigger' };
  }

  reset(): void {
    this.turnsSinceCompaction = 0;
  }
}

// =============================================================================
// Factory
// =============================================================================

export function createCompactionTrigger(config?: CompactionTriggerConfig): CompactionTrigger {
  return new CompactionTrigger(config);
}
