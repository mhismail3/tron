//! Context management settings.
//!
//! Configuration for compaction and rules.

use serde::{Deserialize, Serialize};

/// Container for all context management settings.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ContextSettings {
    /// Context compaction settings.
    pub compactor: CompactorSettings,
    /// Rules discovery settings.
    pub rules: RulesSettings,
}

/// Context compaction settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CompactorSettings {
    /// Maximum token budget for summarized context.
    pub max_tokens: usize,
    /// Ratio of context window usage that triggers compaction (0.0–1.0).
    pub compaction_threshold: f64,
    /// Target token count after compaction.
    pub target_tokens: usize,
    /// Maximum ratio (0.0–1.0) of context limit that preserved turns can consume.
    pub max_preserved_ratio: f64,
    /// Approximate characters per token for estimation.
    pub chars_per_token: usize,
    /// Token buffer reserved for responses.
    pub buffer_tokens: usize,
    /// Context usage ratio that triggers compaction.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trigger_token_threshold: Option<f64>,
    /// Number of recent messages to preserve during compaction.
    pub preserve_recent_count: usize,
}

impl Default for CompactorSettings {
    fn default() -> Self {
        Self {
            max_tokens: 25_000,
            compaction_threshold: 0.85,
            target_tokens: 10_000,
            max_preserved_ratio: 0.20,
            chars_per_token: 4,
            buffer_tokens: 4000,
            trigger_token_threshold: Some(0.70),
            preserve_recent_count: 5,
        }
    }
}

/// Rules discovery settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RulesSettings {
    /// Whether to discover standalone rule files (AGENTS.md, CLAUDE.md).
    pub discover_standalone_files: bool,
}

impl Default for RulesSettings {
    fn default() -> Self {
        Self {
            discover_standalone_files: true,
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compactor_defaults() {
        let c = CompactorSettings::default();
        assert_eq!(c.max_tokens, 25_000);
        assert!((c.compaction_threshold - 0.85).abs() < f64::EPSILON);
        assert!((c.max_preserved_ratio - 0.20).abs() < f64::EPSILON);
        assert_eq!(c.trigger_token_threshold, Some(0.70));
        assert_eq!(c.preserve_recent_count, 5);
    }

    #[test]
    fn compactor_serde_camel_case() {
        let c = CompactorSettings::default();
        let json = serde_json::to_value(&c).unwrap();
        assert!(json.get("maxTokens").is_some());
        assert!(json.get("compactionThreshold").is_some());
        assert!(json.get("charsPerToken").is_some());
        assert_eq!(json["preserveRecentCount"], 5);
    }

    #[test]
    fn compactor_preserve_recent_count_round_trip() {
        let json = serde_json::json!({
            "preserveRecentCount": 8
        });
        let c: CompactorSettings = serde_json::from_value(json).unwrap();
        assert_eq!(c.preserve_recent_count, 8);
        let serialized = serde_json::to_value(&c).unwrap();
        assert_eq!(serialized["preserveRecentCount"], 8);
    }

    #[test]
    fn compactor_preserve_recent_count_defaults_when_absent() {
        let json = serde_json::json!({});
        let c: CompactorSettings = serde_json::from_value(json).unwrap();
        assert_eq!(c.preserve_recent_count, 5);
    }

    #[test]
    fn rules_defaults() {
        let r = RulesSettings::default();
        assert!(r.discover_standalone_files);
    }

    #[test]
    fn context_partial_json() {
        let json = serde_json::json!({
            "compactor": {
                "maxTokens": 50000
            }
        });
        let ctx: ContextSettings = serde_json::from_value(json).unwrap();
        assert_eq!(ctx.compactor.max_tokens, 50_000);
        assert!((ctx.compactor.max_preserved_ratio - 0.20).abs() < f64::EPSILON);
        assert!(ctx.rules.discover_standalone_files);
    }
}
