//! Smart compaction trigger.
//!
//! Determines when context compaction should happen based on two signals:
//! 1. Token ratio exceeding threshold (primary trigger)
//! 2. Progress signals (commits, pushes, PRs, tags)

use regex::Regex;
use std::sync::LazyLock;

use super::types::CompactionTriggerConfig;
use super::types::CompactionTriggerInput;

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
#[derive(Debug)]
pub struct CompactionTrigger {
    config: CompactionTriggerConfig,
}

impl CompactionTrigger {
    /// Create a new trigger with the given configuration.
    #[must_use]
    pub fn new(config: CompactionTriggerConfig) -> Self {
        Self { config }
    }

    /// Evaluate whether compaction should run.
    pub fn should_compact(&mut self, input: &CompactionTriggerInput) -> CompactionTriggerResult {
        // 1. Token threshold — primary trigger
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

        CompactionTriggerResult {
            compact: false,
            reason: "no trigger".to_string(),
        }
    }

    /// Reset the trigger state (called after compaction completes).
    pub fn reset(&mut self) {
        // No mutable state to reset — trigger is purely functional.
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
    fn test_no_turn_fallback_even_after_many_turns() {
        let mut trigger = CompactionTrigger::new(CompactionTriggerConfig::default());
        // Even after 100 turns at low ratio, should NOT trigger
        for _ in 0..100 {
            let result = trigger.should_compact(&default_input(0.3));
            assert!(!result.compact, "should not trigger on turn count alone");
        }
    }

    #[test]
    fn test_reset_is_noop() {
        let mut trigger = CompactionTrigger::new(CompactionTriggerConfig::default());
        trigger.reset();
        let result = trigger.should_compact(&default_input(0.3));
        assert!(!result.compact);
    }
}
