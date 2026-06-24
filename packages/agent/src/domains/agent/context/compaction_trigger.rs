//! Smart compaction trigger.
//!
//! Determines when context compaction should happen based on token pressure.

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

/// Token-pressure compaction trigger.
///
/// Evaluates whether compaction should run after each agent turn.
/// The primitive loop compacts only when the token ratio exceeds
/// `trigger_token_threshold`; task-specific progress signals are agent-owned
/// state, not host policy.
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
            recent_capability_invocations: Vec::new(),
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
    fn test_no_turn_count_recovery_even_after_many_turns() {
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
