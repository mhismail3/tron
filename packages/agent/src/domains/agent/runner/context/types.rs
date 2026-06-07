//! Primitive context management types.
//!
//! These types describe the bare agent loop context: soul/system prompt,
//! provider-visible capabilities, environment metadata, messages, and compaction
//! state. Behavior instructions learned by the agent live in agent-owned state,
//! not in separate context planes.

use crate::shared::messages::Message;
use crate::shared::model_capabilities::ModelCapability;
use serde::{Deserialize, Serialize};

use super::constants::Thresholds;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ThresholdLevel {
    Normal,
    Warning,
    Alert,
    Critical,
    Exceeded,
}

impl ThresholdLevel {
    #[must_use]
    pub fn from_ratio(ratio: f64) -> Self {
        if ratio >= Thresholds::EXCEEDED {
            Self::Exceeded
        } else if ratio >= Thresholds::CRITICAL {
            Self::Critical
        } else if ratio >= Thresholds::ALERT {
            Self::Alert
        } else if ratio >= Thresholds::WARNING {
            Self::Warning
        } else {
            Self::Normal
        }
    }
}

#[derive(Clone, Debug)]
pub struct ContextManagerConfig {
    pub model: String,
    pub system_prompt: Option<String>,
    pub working_directory: Option<String>,
    pub capabilities: Vec<ModelCapability>,
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

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenBreakdown {
    pub system_prompt: u64,
    pub capabilities: u64,
    pub environment: u64,
    pub messages: u64,
    pub provider_adjustment: u64,
}

impl TokenBreakdown {
    #[must_use]
    pub fn total(&self) -> u64 {
        self.system_prompt
            + self.capabilities
            + self.environment
            + self.messages
            + self.provider_adjustment
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContextSnapshot {
    pub current_tokens: u64,
    pub context_limit: u64,
    pub usage_percent: f64,
    pub threshold_level: ThresholdLevel,
    pub breakdown: TokenBreakdown,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DetailedMessageInfo {
    pub index: usize,
    pub role: String,
    pub tokens: u64,
    pub summary: String,
    pub content: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub event_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub capability_invocations: Option<Vec<CapabilityInvocationDraftInfo>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub invocation_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_error: Option<bool>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CapabilityInvocationDraftInfo {
    pub id: String,
    pub name: String,
    pub tokens: u64,
    pub arguments: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DetailedContextSnapshot {
    #[serde(flatten)]
    pub snapshot: ContextSnapshot,
    pub messages: Vec<DetailedMessageInfo>,
    pub system_prompt_content: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub capability_clarification_content: Option<String>,
    pub capabilities_content: Vec<CapabilitySummary>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CapabilitySummary {
    pub name: String,
    pub description: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreTurnValidation {
    pub can_proceed: bool,
    pub needs_compaction: bool,
    pub current_tokens: u64,
    pub context_limit: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompactionPreview {
    pub tokens_before: u64,
    pub tokens_after: u64,
    pub compression_ratio: f64,
    pub preserved_messages: usize,
    pub summarized_messages: usize,
    pub preserved_turns: usize,
    pub summarized_turns: usize,
    pub summary: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub extracted_data: Option<ExtractedData>,
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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub extracted_data: Option<ExtractedData>,
}

#[derive(Clone, Debug)]
pub struct ProcessedCapabilityResult {
    pub invocation_id: String,
    pub content: String,
    pub truncated: bool,
    pub original_size: Option<usize>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ExportedState {
    pub model: String,
    pub system_prompt: String,
    pub capabilities: Vec<ModelCapability>,
    pub messages: Vec<Message>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtractedData {
    #[serde(default)]
    pub current_goal: String,
    #[serde(default)]
    pub completed_steps: Vec<String>,
    #[serde(default)]
    pub pending_tasks: Vec<String>,
    #[serde(default)]
    pub key_decisions: Vec<KeyDecision>,
    #[serde(default)]
    pub files_modified: Vec<String>,
    #[serde(default)]
    pub topics_discussed: Vec<String>,
    #[serde(default)]
    pub user_preferences: Vec<String>,
    #[serde(default)]
    pub important_context: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub thinking_insights: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct KeyDecision {
    pub decision: String,
    pub reason: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SummaryResult {
    pub extracted_data: ExtractedData,
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

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompactionTriggerInput {
    pub current_token_ratio: f64,
    pub recent_event_types: Vec<String>,
    pub recent_capability_invocations: Vec<String>,
}

pub use crate::shared::messages::Provider;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn threshold_level_from_ratio() {
        assert_eq!(ThresholdLevel::from_ratio(0.0), ThresholdLevel::Normal);
        assert_eq!(ThresholdLevel::from_ratio(0.49), ThresholdLevel::Normal);
        assert_eq!(ThresholdLevel::from_ratio(0.50), ThresholdLevel::Warning);
        assert_eq!(ThresholdLevel::from_ratio(0.69), ThresholdLevel::Warning);
        assert_eq!(ThresholdLevel::from_ratio(0.70), ThresholdLevel::Alert);
        assert_eq!(ThresholdLevel::from_ratio(0.84), ThresholdLevel::Alert);
        assert_eq!(ThresholdLevel::from_ratio(0.85), ThresholdLevel::Critical);
        assert_eq!(ThresholdLevel::from_ratio(0.94), ThresholdLevel::Critical);
        assert_eq!(ThresholdLevel::from_ratio(0.95), ThresholdLevel::Exceeded);
    }

    #[test]
    fn context_snapshot_serde() {
        let snapshot = ContextSnapshot {
            current_tokens: 5000,
            context_limit: 200_000,
            usage_percent: 0.025,
            threshold_level: ThresholdLevel::Normal,
            breakdown: TokenBreakdown {
                system_prompt: 1000,
                capabilities: 2000,
                environment: 30,
                messages: 1500,
                provider_adjustment: 470,
            },
        };
        let json = serde_json::to_value(&snapshot).unwrap();
        assert_eq!(json["currentTokens"], 5000);
        assert_eq!(json["thresholdLevel"], "normal");
        assert_eq!(json["breakdown"]["providerAdjustment"], 470);
    }

    #[test]
    fn token_breakdown_total_sums_all() {
        let b = TokenBreakdown {
            system_prompt: 100,
            capabilities: 200,
            environment: 15,
            messages: 500,
            provider_adjustment: 5,
        };
        assert_eq!(b.total(), 820);
    }

    #[test]
    fn extracted_data_serde_roundtrip() {
        let data = ExtractedData {
            current_goal: "Implement auth".into(),
            completed_steps: vec!["Login flow".into()],
            key_decisions: vec![KeyDecision {
                decision: "Use JWT".into(),
                reason: "Stateless".into(),
            }],
            files_modified: vec!["auth.rs".into()],
            ..Default::default()
        };
        let json = serde_json::to_string(&data).unwrap();
        let back: ExtractedData = serde_json::from_str(&json).unwrap();
        assert_eq!(back.current_goal, "Implement auth");
        assert_eq!(back.key_decisions[0].decision, "Use JWT");
    }

    #[test]
    fn threshold_parity_defaults() {
        let compaction_cfg = CompactionConfig::default();
        let trigger_cfg = CompactionTriggerConfig::default();
        assert!(
            (compaction_cfg.threshold - trigger_cfg.trigger_token_threshold).abs() < f64::EPSILON
        );
    }
}
