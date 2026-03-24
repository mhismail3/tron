//! Smart compaction trigger.
//!
//! Determines when context compaction should happen based on multiple signals:
//! 1. Token ratio exceeding threshold (safety net)
//! 2. Progress signals (commits, pushes, PRs, tags)
//! 3. Turn count fallback (lower in alert zone)
//!
//! The trigger maintains a turn counter that resets after each compaction.

use regex::Regex;
use std::sync::LazyLock;
use tracing::debug;

use super::types::{CompactionTriggerConfig, CompactionTriggerInput};

/// Result of the compaction trigger decision.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompactionTriggerResult {
    /// Whether compaction should run.
    pub compact: bool,
    /// Reason for the decision.
    pub reason: String,
}

/// Progress signal patterns matched against recent Bash tool call commands.
static PROGRESS_PATTERNS: LazyLock<[Regex; 4]> = LazyLock::new(|| {
    [
        Regex::new(r"\bgit\s+push\b").expect("valid regex"),
        Regex::new(r"\bgh\s+pr\s+create\b").expect("valid regex"),
        Regex::new(r"\bgh\s+pr\s+merge\b").expect("valid regex"),
        Regex::new(r"\bgit\s+tag\b").expect("valid regex"),
    ]
});

fn progress_patterns() -> &'static [Regex; 4] {
    &PROGRESS_PATTERNS
}

/// Multi-signal compaction trigger.
///
/// Evaluates whether compaction should run after each agent turn.
/// The decision order is:
///
/// 1. **Token threshold** — if the ratio exceeds `trigger_token_threshold`, compact.
/// 2. **Progress signals** — if a commit, push, PR, or tag is detected, compact.
/// 3. **Turn fallback** — if enough turns have elapsed, compact (threshold is
///    lower in the alert zone above `alert_zone_threshold`).
#[derive(Debug)]
pub struct CompactionTrigger {
    config: CompactionTriggerConfig,
    turns_since_compaction: u32,
    force_always: bool,
}

impl CompactionTrigger {
    /// Create a new trigger with the given configuration.
    #[must_use]
    pub fn new(config: CompactionTriggerConfig) -> Self {
        Self {
            config,
            turns_since_compaction: 0,
            force_always: false,
        }
    }

    /// Evaluate whether compaction should run.
    ///
    /// Increments the turn counter each call. Returns a result indicating
    /// whether to compact and why.
    pub fn should_compact(&mut self, input: &CompactionTriggerInput) -> CompactionTriggerResult {
        self.turns_since_compaction += 1;

        if self.force_always {
            return CompactionTriggerResult {
                compact: true,
                reason: "force-always mode (testing)".to_string(),
            };
        }

        // 1. Token threshold — safety net
        if input.current_token_ratio >= self.config.trigger_token_threshold {
            #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
            let pct = (input.current_token_ratio * 100.0) as u32;
            return CompactionTriggerResult {
                compact: true,
                reason: format!("token ratio {pct}% >= threshold"),
            };
        }

        // 2. Progress signals — event types
        if input
            .recent_event_types
            .iter()
            .any(|t| t == "worktree.commit")
        {
            return CompactionTriggerResult {
                compact: true,
                reason: "commit detected — good compaction point".to_string(),
            };
        }

        // 2b. Progress signals — tool call patterns
        let patterns = progress_patterns();
        for cmd in &input.recent_tool_calls {
            for pattern in patterns {
                if pattern.is_match(cmd) {
                    return CompactionTriggerResult {
                        compact: true,
                        reason: "progress signal: push/pr/tag detected".to_string(),
                    };
                }
            }
        }

        // 3. Turn-count fallback (lower threshold in alert zone)
        let fallback = if input.current_token_ratio >= self.config.alert_zone_threshold {
            self.config.alert_turn_fallback
        } else {
            self.config.default_turn_fallback
        };

        if self.turns_since_compaction >= fallback {
            return CompactionTriggerResult {
                compact: true,
                reason: format!(
                    "turn count fallback ({} turns)",
                    self.turns_since_compaction
                ),
            };
        }

        CompactionTriggerResult {
            compact: false,
            reason: "no trigger".to_string(),
        }
    }

    /// Reset the turn counter (called after compaction completes).
    pub fn reset(&mut self) {
        debug!(
            turns = self.turns_since_compaction,
            "Resetting compaction trigger"
        );
        self.turns_since_compaction = 0;
    }

    /// Enable force-always mode (every call triggers compaction). For testing.
    pub fn set_force_always(&mut self, enabled: bool) {
        self.force_always = enabled;
    }

    /// Get the current turn count since last compaction.
    #[must_use]
    pub fn turns_since_compaction(&self) -> u32 {
        self.turns_since_compaction
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn default_input(ratio: f64) -> CompactionTriggerInput {
        CompactionTriggerInput {
            current_token_ratio: ratio,
            recent_event_types: Vec::new(),
            recent_tool_calls: Vec::new(),
        }
    }

    #[test]
    fn test_token_threshold_triggers() {
        let mut trigger = CompactionTrigger::new(CompactionTriggerConfig::default());
        let result = trigger.should_compact(&default_input(0.75));
        assert!(result.compact);
        assert!(result.reason.contains("token ratio"));
        assert!(result.reason.contains("75%"));
    }

    #[test]
    fn test_token_threshold_exact_boundary() {
        let mut trigger = CompactionTrigger::new(CompactionTriggerConfig::default());
        let result = trigger.should_compact(&default_input(0.70));
        assert!(result.compact);
    }

    #[test]
    fn test_below_token_threshold_no_trigger() {
        let mut trigger = CompactionTrigger::new(CompactionTriggerConfig::default());
        let result = trigger.should_compact(&default_input(0.69));
        assert!(!result.compact);
    }

    #[test]
    fn test_worktree_commit_triggers() {
        let mut trigger = CompactionTrigger::new(CompactionTriggerConfig::default());
        let input = CompactionTriggerInput {
            current_token_ratio: 0.3,
            recent_event_types: vec!["worktree.commit".to_string()],
            recent_tool_calls: Vec::new(),
        };
        let result = trigger.should_compact(&input);
        assert!(result.compact);
        assert!(result.reason.contains("commit"));
    }

    #[test]
    fn test_git_push_triggers() {
        let mut trigger = CompactionTrigger::new(CompactionTriggerConfig::default());
        let input = CompactionTriggerInput {
            current_token_ratio: 0.3,
            recent_event_types: Vec::new(),
            recent_tool_calls: vec!["git push origin main".to_string()],
        };
        let result = trigger.should_compact(&input);
        assert!(result.compact);
    }

    #[test]
    fn test_turn_fallback_normal_triggers() {
        let mut trigger = CompactionTrigger::new(CompactionTriggerConfig::default());
        for _ in 0..24 {
            let result = trigger.should_compact(&default_input(0.3));
            assert!(!result.compact);
        }
        let result = trigger.should_compact(&default_input(0.3));
        assert!(result.compact);
        assert!(result.reason.contains("turn count fallback"));
    }

    #[test]
    fn test_reset_clears_turn_count() {
        let mut trigger = CompactionTrigger::new(CompactionTriggerConfig::default());
        for _ in 0..5 {
            let _ = trigger.should_compact(&default_input(0.3));
        }
        assert_eq!(trigger.turns_since_compaction(), 5);
        trigger.reset();
        assert_eq!(trigger.turns_since_compaction(), 0);
    }

    #[test]
    fn test_force_always_triggers() {
        let mut trigger = CompactionTrigger::new(CompactionTriggerConfig::default());
        trigger.set_force_always(true);
        let result = trigger.should_compact(&default_input(0.0));
        assert!(result.compact);
        assert!(result.reason.contains("force-always"));
    }
}
