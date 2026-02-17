//! Core types for the memory system.
//!
//! Includes compaction trigger configuration, cycle information, and ledger
//! write results. All serializable types use `camelCase` for wire compatibility.

use serde::{Deserialize, Serialize};

/// Configuration for the compaction trigger.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompactionTriggerConfig {
    /// Token ratio that forces compaction (0.0–1.0). Default: 0.70.
    pub trigger_token_threshold: f64,
    /// Token ratio for alert zone (more aggressive compaction). Default: 0.50.
    pub alert_zone_threshold: f64,
    /// Turns before auto-compaction in normal zone. Default: 8.
    pub default_turn_fallback: u32,
    /// Turns before auto-compaction in alert zone. Default: 5.
    pub alert_turn_fallback: u32,
}

impl Default for CompactionTriggerConfig {
    fn default() -> Self {
        Self {
            trigger_token_threshold: 0.70,
            alert_zone_threshold: 0.50,
            default_turn_fallback: 8,
            alert_turn_fallback: 5,
        }
    }
}

/// Input to the compaction trigger decision engine.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompactionTriggerInput {
    /// Current token usage ratio (0.0–1.0).
    pub current_token_ratio: f64,
    /// Recent event types from the current cycle.
    pub recent_event_types: Vec<String>,
    /// Recent Bash tool call commands.
    pub recent_tool_calls: Vec<String>,
}

/// Result of the compaction trigger decision.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompactionTriggerResult {
    /// Whether compaction should run.
    pub compact: bool,
    /// Reason for the decision.
    pub reason: String,
}

/// Information about a completed response cycle.
///
/// Passed to [`MemoryManager::on_cycle_complete`](crate::manager::MemoryManager::on_cycle_complete)
/// at the end of each agent response cycle.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CycleInfo {
    /// Model used for the cycle.
    pub model: String,
    /// Working directory.
    pub working_directory: String,
    /// Current token usage ratio (0.0–1.0).
    pub current_token_ratio: f64,
    /// Recent event types.
    pub recent_event_types: Vec<String>,
    /// Recent Bash tool call commands.
    pub recent_tool_calls: Vec<String>,
}

/// Options for a ledger write operation.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LedgerWriteOpts {
    /// Model used for the cycle.
    pub model: String,
    /// Working directory.
    pub working_directory: String,
}

/// Result of a ledger write operation.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LedgerWriteResult {
    /// Whether an entry was written.
    pub written: bool,
    /// Reason (set when not written).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// Title of the ledger entry.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// Entry type classification.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub entry_type: Option<String>,
    /// Event ID of the persisted entry.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub event_id: Option<String>,
    /// Full payload of the entry.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub payload: Option<serde_json::Value>,
}

impl LedgerWriteResult {
    /// Create a result indicating no entry was written.
    #[must_use]
    pub fn skipped(reason: impl Into<String>) -> Self {
        Self {
            written: false,
            reason: Some(reason.into()),
            title: None,
            entry_type: None,
            event_id: None,
            payload: None,
        }
    }

    /// Create a result indicating an error (not a normal skip).
    #[must_use]
    pub fn failed(reason: impl Into<String>) -> Self {
        Self {
            written: false,
            reason: Some(reason.into()),
            title: None,
            entry_type: Some("error".to_string()),
            event_id: None,
            payload: None,
        }
    }

    /// Create a result indicating a successful write.
    #[must_use]
    pub fn written(
        title: String,
        entry_type: String,
        event_id: String,
        payload: serde_json::Value,
    ) -> Self {
        Self {
            written: true,
            reason: None,
            title: Some(title),
            entry_type: Some(entry_type),
            event_id: Some(event_id),
            payload: Some(payload),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compaction_trigger_config_defaults() {
        let config = CompactionTriggerConfig::default();
        assert!((config.trigger_token_threshold - 0.70).abs() < f64::EPSILON);
        assert!((config.alert_zone_threshold - 0.50).abs() < f64::EPSILON);
        assert_eq!(config.default_turn_fallback, 8);
        assert_eq!(config.alert_turn_fallback, 5);
    }

    #[test]
    fn test_compaction_trigger_config_serde_roundtrip() {
        let config = CompactionTriggerConfig::default();
        let json = serde_json::to_string(&config).unwrap();
        let deserialized: CompactionTriggerConfig = serde_json::from_str(&json).unwrap();
        assert!((deserialized.trigger_token_threshold - 0.70).abs() < f64::EPSILON);
    }

    #[test]
    fn test_compaction_trigger_input_serde() {
        let input = CompactionTriggerInput {
            current_token_ratio: 0.65,
            recent_event_types: vec!["message.user".to_string()],
            recent_tool_calls: vec!["git push".to_string()],
        };
        let json = serde_json::to_string(&input).unwrap();
        let deserialized: CompactionTriggerInput = serde_json::from_str(&json).unwrap();
        assert!((deserialized.current_token_ratio - 0.65).abs() < f64::EPSILON);
    }

    #[test]
    fn test_compaction_trigger_result_serde() {
        let result = CompactionTriggerResult {
            compact: true,
            reason: "token threshold".to_string(),
        };
        let json = serde_json::to_string(&result).unwrap();
        let deserialized: CompactionTriggerResult = serde_json::from_str(&json).unwrap();
        assert!(deserialized.compact);
    }

    #[test]
    fn test_cycle_info_serde() {
        let info = CycleInfo {
            model: "claude-opus-4-6".to_string(),
            working_directory: "/tmp".to_string(),
            current_token_ratio: 0.5,
            recent_event_types: vec![],
            recent_tool_calls: vec![],
        };
        let json = serde_json::to_string(&info).unwrap();
        assert!(json.contains("currentTokenRatio"));
    }

    #[test]
    fn test_ledger_write_opts_serde() {
        let opts = LedgerWriteOpts {
            model: "claude-opus-4-6".to_string(),
            working_directory: "/tmp".to_string(),
        };
        let json = serde_json::to_string(&opts).unwrap();
        assert!(json.contains("workingDirectory"));
    }

    #[test]
    fn test_ledger_write_result_failed() {
        let result = LedgerWriteResult::failed("database temporarily busy");
        assert!(!result.written);
        assert_eq!(result.entry_type.as_deref(), Some("error"));
        assert_eq!(result.reason.as_deref(), Some("database temporarily busy"));
        assert!(result.title.is_none());
        assert!(result.event_id.is_none());
        assert!(result.payload.is_none());
    }

    #[test]
    fn test_ledger_write_result_failed_serde_includes_entry_type() {
        let result = LedgerWriteResult::failed("db error");
        let json = serde_json::to_string(&result).unwrap();
        assert!(json.contains("\"entryType\":\"error\""));
        assert!(json.contains("\"reason\":\"db error\""));
    }

    #[test]
    fn test_ledger_write_result_skipped() {
        let result = LedgerWriteResult::skipped("no content");
        assert!(!result.written);
        assert_eq!(result.reason.as_deref(), Some("no content"));
        assert!(result.title.is_none());
    }

    #[test]
    fn test_ledger_write_result_written() {
        let result = LedgerWriteResult::written(
            "My title".to_string(),
            "feature".to_string(),
            "evt-1".to_string(),
            serde_json::json!({"key": "val"}),
        );
        assert!(result.written);
        assert_eq!(result.title.as_deref(), Some("My title"));
        assert_eq!(result.event_id.as_deref(), Some("evt-1"));
    }

    #[test]
    fn test_ledger_write_result_serde_skips_none() {
        let result = LedgerWriteResult::skipped("reason");
        let json = serde_json::to_string(&result).unwrap();
        assert!(!json.contains("title"));
        assert!(!json.contains("eventId"));
        assert!(!json.contains("payload"));
    }

    #[test]
    fn test_ledger_write_result_serde_roundtrip() {
        let result = LedgerWriteResult::written(
            "title".to_string(),
            "bugfix".to_string(),
            "evt-2".to_string(),
            serde_json::json!({}),
        );
        let json = serde_json::to_string(&result).unwrap();
        let deserialized: LedgerWriteResult = serde_json::from_str(&json).unwrap();
        assert!(deserialized.written);
        assert_eq!(deserialized.entry_type.as_deref(), Some("bugfix"));
    }
}
