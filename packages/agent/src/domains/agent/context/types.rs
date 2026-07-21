//! Primitive context management types.
//!
//! These types describe the bare agent loop context: soul/system prompt,
//! provider-visible direct tools, environment metadata, messages, and
//! compaction state. Persistent adaptation belongs to worker bundles rather
//! than a separate generic prompt-state plane.

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug)]
pub struct ContextManagerConfig {
    pub system_prompt: Option<String>,
    pub working_directory: Option<String>,
    pub compaction: CompactionConfig,
}

#[derive(Clone, Debug)]
pub struct CompactionConfig {
    pub threshold: f64,
    pub preserve_recent_turns: usize,
    pub context_limit: u64,
}

impl Default for CompactionConfig {
    fn default() -> Self {
        Self {
            threshold: 0.70,
            preserve_recent_turns: 5,
            context_limit: 200_000,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompactionResult {
    pub success: bool,
    pub tokens_before: u64,
    pub tokens_after: u64,
    pub compression_ratio: f64,
    pub preserved_turns: usize,
    pub summarized_turns: usize,
    pub preserved_messages: usize,
    pub summary: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SummaryResult {
    pub narrative: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompactionTriggerConfig {
    pub trigger_token_threshold: f64,
}

impl Default for CompactionTriggerConfig {
    fn default() -> Self {
        Self {
            trigger_token_threshold: 0.70,
        }
    }
}

impl From<&crate::domains::settings::CompactorSettings> for CompactionTriggerConfig {
    fn from(cs: &crate::domains::settings::CompactorSettings) -> Self {
        let defaults = Self::default();
        Self {
            trigger_token_threshold: cs
                .trigger_token_threshold
                .unwrap_or(defaults.trigger_token_threshold),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn threshold_parity_defaults() {
        let compaction_cfg = CompactionConfig::default();
        let trigger_cfg = CompactionTriggerConfig::default();
        assert!(
            (compaction_cfg.threshold - trigger_cfg.trigger_token_threshold).abs() < f64::EPSILON
        );
    }
}
