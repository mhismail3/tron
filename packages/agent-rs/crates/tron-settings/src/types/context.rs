//! Context management settings.
//!
//! Configuration for compaction, memory (embeddings, ledger), rules, and tasks.

use serde::{Deserialize, Serialize};

/// Container for all context management settings.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ContextSettings {
    /// Context compaction settings.
    pub compactor: CompactorSettings,
    /// Memory system settings.
    pub memory: MemorySettings,
    /// Rules discovery settings.
    pub rules: RulesSettings,
    /// Task context injection settings.
    pub tasks: TaskContextSettings,
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
    /// Number of recent turns to preserve during compaction.
    pub preserve_recent_count: usize,
    /// Approximate characters per token for estimation.
    pub chars_per_token: usize,
    /// Token buffer reserved for responses.
    pub buffer_tokens: usize,
    /// Force compaction on every turn (testing only).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub force_always: Option<bool>,
    /// Context usage ratio that triggers compaction.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trigger_token_threshold: Option<f64>,
    /// Context usage ratio for the alert zone.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub alert_zone_threshold: Option<f64>,
    /// Default number of recent turns to keep when compacting.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_turn_fallback: Option<usize>,
    /// Number of recent turns to keep in the alert zone.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub alert_turn_fallback: Option<usize>,
}

impl Default for CompactorSettings {
    fn default() -> Self {
        Self {
            max_tokens: 25_000,
            compaction_threshold: 0.85,
            target_tokens: 10_000,
            preserve_recent_count: 5,
            chars_per_token: 4,
            buffer_tokens: 4000,
            force_always: None,
            trigger_token_threshold: Some(0.70),
            alert_zone_threshold: Some(0.50),
            default_turn_fallback: Some(8),
            alert_turn_fallback: Some(5),
        }
    }
}

/// Memory system settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MemorySettings {
    /// Maximum number of memory entries to retain.
    pub max_entries: usize,
    /// Embedding model settings.
    pub embedding: MemoryEmbeddingSettings,
    /// Automatic memory injection settings.
    pub auto_inject: MemoryAutoInjectSettings,
    /// Memory ledger settings.
    pub ledger: MemoryLedgerSettings,
}

impl Default for MemorySettings {
    fn default() -> Self {
        Self {
            max_entries: 1000,
            embedding: MemoryEmbeddingSettings::default(),
            auto_inject: MemoryAutoInjectSettings::default(),
            ledger: MemoryLedgerSettings::default(),
        }
    }
}

/// Embedding model configuration for semantic memory.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MemoryEmbeddingSettings {
    /// Whether embeddings are enabled.
    pub enabled: bool,
    /// ONNX model identifier.
    pub model: String,
    /// Quantization dtype (e.g., `"q4"`).
    pub dtype: String,
    /// Output embedding dimensions (Matryoshka truncation).
    pub dimensions: usize,
    /// Local model cache directory.
    pub cache_dir: String,
    /// Maximum tokens for workspace lesson injection.
    pub max_workspace_lessons_tokens: usize,
    /// Maximum tokens for cross-project memory injection.
    pub max_cross_project_tokens: usize,
    /// Top-K results for cross-project search.
    pub cross_project_top_k: usize,
}

impl Default for MemoryEmbeddingSettings {
    fn default() -> Self {
        Self {
            enabled: true,
            model: "onnx-community/Qwen3-Embedding-0.6B-ONNX".to_string(),
            dtype: "q4".to_string(),
            dimensions: 512,
            cache_dir: "~/.tron/mods/models".to_string(),
            max_workspace_lessons_tokens: 2000,
            max_cross_project_tokens: 1000,
            cross_project_top_k: 5,
        }
    }
}

/// Automatic memory injection settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MemoryAutoInjectSettings {
    /// Whether auto-injection is enabled.
    pub enabled: bool,
    /// Number of memories to auto-inject (1–10).
    pub count: usize,
}

impl Default for MemoryAutoInjectSettings {
    fn default() -> Self {
        Self {
            enabled: true,
            count: 5,
        }
    }
}

/// Memory ledger settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MemoryLedgerSettings {
    /// Whether the memory ledger is enabled.
    pub enabled: bool,
}

impl Default for MemoryLedgerSettings {
    fn default() -> Self {
        Self { enabled: true }
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

/// Task context injection settings.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TaskContextSettings {
    /// Automatic task context injection settings.
    pub auto_inject: TaskAutoInjectSettings,
}

/// Automatic task context injection settings.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TaskAutoInjectSettings {
    /// Whether to auto-inject task context into prompts.
    pub enabled: bool,
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
        assert_eq!(c.preserve_recent_count, 5);
        assert_eq!(c.trigger_token_threshold, Some(0.70));
    }

    #[test]
    fn compactor_serde_camel_case() {
        let c = CompactorSettings::default();
        let json = serde_json::to_value(&c).unwrap();
        assert!(json.get("maxTokens").is_some());
        assert!(json.get("compactionThreshold").is_some());
        assert!(json.get("charsPerToken").is_some());
    }

    #[test]
    fn compactor_omits_none_fields() {
        let mut c = CompactorSettings::default();
        c.force_always = None;
        let json = serde_json::to_value(&c).unwrap();
        assert!(json.get("forceAlways").is_none());
    }

    #[test]
    fn memory_defaults() {
        let m = MemorySettings::default();
        assert_eq!(m.max_entries, 1000);
        assert!(m.embedding.enabled);
        assert_eq!(m.embedding.dtype, "q4");
        assert_eq!(m.embedding.dimensions, 512);
        assert!(m.auto_inject.enabled);
        assert_eq!(m.auto_inject.count, 5);
        assert!(m.ledger.enabled);
    }

    #[test]
    fn rules_defaults() {
        let r = RulesSettings::default();
        assert!(r.discover_standalone_files);
    }

    #[test]
    fn task_defaults() {
        let t = TaskContextSettings::default();
        assert!(!t.auto_inject.enabled);
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
        // Other compactor fields should be defaults
        assert_eq!(ctx.compactor.preserve_recent_count, 5);
        // Other sections should be defaults
        assert!(ctx.memory.embedding.enabled);
    }
}
