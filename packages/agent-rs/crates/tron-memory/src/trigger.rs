//! Smart compaction trigger.
//!
//! Determines when context compaction should happen based on multiple signals:
//! 1. Token ratio exceeding threshold (safety net)
//! 2. Progress signals (commits, pushes, PRs, tags)
//! 3. Turn count fallback (lower in alert zone)
//!
//! The trigger maintains a turn counter that resets after each compaction.

use regex::Regex;
use tracing::debug;

use crate::types::{CompactionTriggerConfig, CompactionTriggerInput, CompactionTriggerResult};

/// Progress signal patterns matched against recent Bash tool call commands.
///
/// These indicate the user has reached a milestone and compaction would be
/// a good checkpoint.
fn progress_patterns() -> Vec<Regex> {
    // These are compiled once per call; in a real hot path we'd use lazy_static.
    // For the expected call rate (~once per turn), this is fine.
    vec![
        Regex::new(r"\bgit\s+push\b").expect("valid regex"),
        Regex::new(r"\bgh\s+pr\s+create\b").expect("valid regex"),
        Regex::new(r"\bgh\s+pr\s+merge\b").expect("valid regex"),
        Regex::new(r"\bgit\s+tag\b").expect("valid regex"),
    ]
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
        if input.recent_event_types.iter().any(|t| t == "worktree.commit") {
            return CompactionTriggerResult {
                compact: true,
                reason: "commit detected — good compaction point".to_string(),
            };
        }

        // 2b. Progress signals — tool call patterns
        let patterns = progress_patterns();
        for cmd in &input.recent_tool_calls {
            for pattern in &patterns {
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

    // --- Token threshold ---

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
    fn test_zero_token_ratio() {
        let mut trigger = CompactionTrigger::new(CompactionTriggerConfig::default());
        let result = trigger.should_compact(&default_input(0.0));
        assert!(!result.compact);
    }

    // --- Progress signals: event types ---

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

    // --- Progress signals: tool call patterns ---

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
        assert!(result.reason.contains("progress signal"));
    }

    #[test]
    fn test_gh_pr_create_triggers() {
        let mut trigger = CompactionTrigger::new(CompactionTriggerConfig::default());
        let input = CompactionTriggerInput {
            current_token_ratio: 0.3,
            recent_event_types: Vec::new(),
            recent_tool_calls: vec!["gh pr create --title 'fix'".to_string()],
        };
        let result = trigger.should_compact(&input);
        assert!(result.compact);
    }

    #[test]
    fn test_gh_pr_merge_triggers() {
        let mut trigger = CompactionTrigger::new(CompactionTriggerConfig::default());
        let input = CompactionTriggerInput {
            current_token_ratio: 0.3,
            recent_event_types: Vec::new(),
            recent_tool_calls: vec!["gh pr merge 42".to_string()],
        };
        let result = trigger.should_compact(&input);
        assert!(result.compact);
    }

    #[test]
    fn test_git_tag_triggers() {
        let mut trigger = CompactionTrigger::new(CompactionTriggerConfig::default());
        let input = CompactionTriggerInput {
            current_token_ratio: 0.3,
            recent_event_types: Vec::new(),
            recent_tool_calls: vec!["git tag v1.0".to_string()],
        };
        let result = trigger.should_compact(&input);
        assert!(result.compact);
    }

    #[test]
    fn test_git_status_not_a_progress_signal() {
        let mut trigger = CompactionTrigger::new(CompactionTriggerConfig::default());
        let input = CompactionTriggerInput {
            current_token_ratio: 0.3,
            recent_event_types: Vec::new(),
            recent_tool_calls: vec!["git status".to_string()],
        };
        let result = trigger.should_compact(&input);
        assert!(!result.compact);
    }

    // --- Turn fallback: normal zone ---

    #[test]
    fn test_turn_fallback_normal_triggers() {
        let mut trigger = CompactionTrigger::new(CompactionTriggerConfig::default());
        // 8 turns at ratio 0.3 (normal zone, default fallback = 8)
        for _ in 0..7 {
            let result = trigger.should_compact(&default_input(0.3));
            assert!(!result.compact);
        }
        let result = trigger.should_compact(&default_input(0.3));
        assert!(result.compact);
        assert!(result.reason.contains("turn count fallback"));
        assert!(result.reason.contains("8 turns"));
    }

    #[test]
    fn test_turn_fallback_normal_not_yet() {
        let mut trigger = CompactionTrigger::new(CompactionTriggerConfig::default());
        for _ in 0..6 {
            let _ = trigger.should_compact(&default_input(0.3));
        }
        let result = trigger.should_compact(&default_input(0.3));
        assert!(!result.compact); // Only 7 turns, need 8
    }

    // --- Turn fallback: alert zone ---

    #[test]
    fn test_turn_fallback_alert_triggers() {
        let mut trigger = CompactionTrigger::new(CompactionTriggerConfig::default());
        // 5 turns at ratio 0.55 (alert zone, alert fallback = 5)
        for _ in 0..4 {
            let result = trigger.should_compact(&default_input(0.55));
            assert!(!result.compact);
        }
        let result = trigger.should_compact(&default_input(0.55));
        assert!(result.compact);
        assert!(result.reason.contains("5 turns"));
    }

    #[test]
    fn test_turn_fallback_alert_not_yet() {
        let mut trigger = CompactionTrigger::new(CompactionTriggerConfig::default());
        for _ in 0..3 {
            let _ = trigger.should_compact(&default_input(0.55));
        }
        let result = trigger.should_compact(&default_input(0.55));
        assert!(!result.compact); // Only 4 turns, need 5
    }

    // --- No signals ---

    #[test]
    fn test_no_signals_no_trigger() {
        let mut trigger = CompactionTrigger::new(CompactionTriggerConfig::default());
        let result = trigger.should_compact(&CompactionTriggerInput {
            current_token_ratio: 0.3,
            recent_event_types: vec!["message.user".to_string()],
            recent_tool_calls: vec!["ls -la".to_string()],
        });
        assert!(!result.compact);
        assert_eq!(result.reason, "no trigger");
    }

    // --- Reset ---

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

    // --- Force always ---

    #[test]
    fn test_force_always_triggers() {
        let mut trigger = CompactionTrigger::new(CompactionTriggerConfig::default());
        trigger.set_force_always(true);
        let result = trigger.should_compact(&default_input(0.0));
        assert!(result.compact);
        assert!(result.reason.contains("force-always"));
    }

    #[test]
    fn test_force_always_disabled() {
        let mut trigger = CompactionTrigger::new(CompactionTriggerConfig::default());
        trigger.set_force_always(true);
        trigger.set_force_always(false);
        let result = trigger.should_compact(&default_input(0.0));
        assert!(!result.compact);
    }

    // --- Custom config ---

    #[test]
    fn test_custom_config_thresholds() {
        let config = CompactionTriggerConfig {
            trigger_token_threshold: 0.90,
            alert_zone_threshold: 0.60,
            default_turn_fallback: 12,
            alert_turn_fallback: 8,
        };
        let mut trigger = CompactionTrigger::new(config);

        // 0.85 doesn't trigger with 0.90 threshold
        let result = trigger.should_compact(&default_input(0.85));
        assert!(!result.compact);

        // 0.91 does trigger
        let result = trigger.should_compact(&default_input(0.91));
        assert!(result.compact);
    }

    // --- Turn counter increments ---

    #[test]
    fn test_turns_increment_each_call() {
        let mut trigger = CompactionTrigger::new(CompactionTriggerConfig::default());
        assert_eq!(trigger.turns_since_compaction(), 0);
        let _ = trigger.should_compact(&default_input(0.3));
        assert_eq!(trigger.turns_since_compaction(), 1);
        let _ = trigger.should_compact(&default_input(0.3));
        assert_eq!(trigger.turns_since_compaction(), 2);
    }
}
