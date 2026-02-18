//! Context management types.
//!
//! Shared types for context management components: threshold levels,
//! configuration, snapshots, compaction, tool results, and summarization.

use serde::{Deserialize, Serialize};
use tron_core::messages::Message;
use tron_core::tools::Tool;

use super::constants::Thresholds;

// =============================================================================
// Threshold Level
// =============================================================================

/// Context usage threshold level.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ThresholdLevel {
    /// Under 50% usage — normal operation.
    Normal,
    /// 50–70% usage — yellow zone.
    Warning,
    /// 70–85% usage — orange zone, suggest compaction.
    Alert,
    /// 85–95% usage — red zone, block new turns.
    Critical,
    /// Over 95% usage — hard limit.
    Exceeded,
}

impl ThresholdLevel {
    /// Determine threshold level for a given usage ratio.
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

// =============================================================================
// Configuration
// =============================================================================

/// Context manager configuration.
#[derive(Clone, Debug)]
pub struct ContextManagerConfig {
    /// Model identifier.
    pub model: String,
    /// Custom system prompt override.
    pub system_prompt: Option<String>,
    /// Working directory for file operations.
    pub working_directory: Option<String>,
    /// Available tools.
    pub tools: Vec<Tool>,
    /// Rules content from AGENTS.md / CLAUDE.md hierarchy.
    pub rules_content: Option<String>,
    /// Compaction settings.
    pub compaction: CompactionConfig,
}

/// Compaction configuration.
#[derive(Clone, Debug)]
pub struct CompactionConfig {
    /// Threshold ratio (0–1) to trigger compaction suggestion.
    pub threshold: f64,
    /// Ratio of messages to preserve during compaction (0.0–1.0).
    pub preserve_ratio: f64,
    /// Model context limit in tokens.
    pub context_limit: u64,
}

impl Default for CompactionConfig {
    fn default() -> Self {
        Self {
            threshold: 0.70,
            preserve_ratio: 0.20,
            context_limit: 200_000,
        }
    }
}

// =============================================================================
// Context Snapshot
// =============================================================================

/// Token breakdown by component.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenBreakdown {
    /// System prompt tokens.
    pub system_prompt: u64,
    /// Tool definition tokens.
    pub tools: u64,
    /// Rules content tokens.
    pub rules: u64,
    /// Message tokens.
    pub messages: u64,
}

/// Snapshot of current context state.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContextSnapshot {
    /// Current total token count.
    pub current_tokens: u64,
    /// Model's context limit.
    pub context_limit: u64,
    /// Usage as a fraction (0.0–1.0).
    pub usage_percent: f64,
    /// Current threshold level.
    pub threshold_level: ThresholdLevel,
    /// Token breakdown by component.
    pub breakdown: TokenBreakdown,
    /// Loaded rules files (if any).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rules: Option<RulesSnapshot>,
}

/// Information about a loaded rules file.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RulesFileSnapshot {
    /// Absolute path to the file.
    pub path: String,
    /// Path relative to working directory.
    pub relative_path: String,
    /// Level in hierarchy.
    pub level: RulesLevel,
    /// Depth from project root (-1 for global).
    pub depth: i32,
}

/// Rules level in the hierarchy.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RulesLevel {
    /// Global rules (~/.tron/).
    Global,
    /// Project-level rules (.claude/AGENTS.md).
    Project,
    /// Directory-level rules.
    Directory,
}

/// Rules section for context snapshot.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RulesSnapshot {
    /// List of loaded rules files.
    pub files: Vec<RulesFileSnapshot>,
    /// Total number of rules files.
    pub total_files: usize,
    /// Estimated token count for merged rules content.
    pub tokens: u64,
}

// =============================================================================
// Detailed Snapshot
// =============================================================================

/// Per-message token information.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DetailedMessageInfo {
    /// Index in message list.
    pub index: usize,
    /// Message role.
    pub role: String,
    /// Estimated token count.
    pub tokens: u64,
    /// Truncated summary for display.
    pub summary: String,
    /// Full content.
    pub content: String,
    /// Event ID (for deletion support).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub event_id: Option<String>,
    /// Tool calls within assistant messages.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_calls: Option<Vec<ToolCallInfo>>,
    /// Tool call ID (for tool result messages).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
    /// Error flag (for tool result messages).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_error: Option<bool>,
}

/// Tool call information for detailed snapshot.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ToolCallInfo {
    /// Tool call ID.
    pub id: String,
    /// Tool name.
    pub name: String,
    /// Estimated token count.
    pub tokens: u64,
    /// Arguments JSON string.
    pub arguments: String,
}

/// Detailed context snapshot with per-message breakdown.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DetailedContextSnapshot {
    /// Base snapshot fields.
    #[serde(flatten)]
    pub snapshot: ContextSnapshot,
    /// Per-message details.
    pub messages: Vec<DetailedMessageInfo>,
    /// Effective system-level context.
    pub system_prompt_content: String,
    /// Tool clarification content (for Codex providers).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_clarification_content: Option<String>,
    /// Tool descriptions.
    pub tools_content: Vec<String>,
}

// =============================================================================
// Pre-Turn Validation
// =============================================================================

/// Result of pre-turn validation.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreTurnValidation {
    /// Whether the turn can proceed.
    pub can_proceed: bool,
    /// Whether compaction is recommended.
    pub needs_compaction: bool,
    /// Current token count.
    pub current_tokens: u64,
    /// Model's context limit.
    pub context_limit: u64,
}

// =============================================================================
// Compaction
// =============================================================================

/// Preview of what compaction would do (without modifying state).
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompactionPreview {
    /// Message-only tokens before compaction.
    pub tokens_before: u64,
    /// Estimated tokens after compaction.
    pub tokens_after: u64,
    /// Compression ratio (`tokens_after / tokens_before`).
    pub compression_ratio: f64,
    /// Number of messages preserved.
    pub preserved_messages: usize,
    /// Number of messages summarized.
    pub summarized_messages: usize,
    /// Generated summary text.
    pub summary: String,
    /// Structured data extracted from the conversation.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub extracted_data: Option<ExtractedData>,
}

/// Result of executing compaction.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompactionResult {
    /// Whether compaction was successful.
    pub success: bool,
    /// Message-only tokens before compaction.
    pub tokens_before: u64,
    /// Estimated tokens after compaction.
    pub tokens_after: u64,
    /// Compression ratio.
    pub compression_ratio: f64,
    /// Generated summary text.
    pub summary: String,
    /// Structured data extracted from the conversation.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub extracted_data: Option<ExtractedData>,
}

// =============================================================================
// Tool Result Processing
// =============================================================================

/// Processed tool result (potentially truncated).
#[derive(Clone, Debug)]
pub struct ProcessedToolResult {
    /// Tool call ID.
    pub tool_call_id: String,
    /// Content (possibly truncated).
    pub content: String,
    /// Whether the content was truncated.
    pub truncated: bool,
    /// Original size before truncation (if truncated).
    pub original_size: Option<usize>,
}

// =============================================================================
// Session Memory
// =============================================================================

/// A session memory entry written mid-session.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SessionMemoryEntry {
    /// Title of the memory entry.
    pub title: String,
    /// Content of the memory entry.
    pub content: String,
    /// Estimated token count.
    pub tokens: u64,
}

// =============================================================================
// Serialization / Export
// =============================================================================

/// Exported context state for persistence.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ExportedState {
    /// Model identifier.
    pub model: String,
    /// System prompt.
    pub system_prompt: String,
    /// Tool definitions.
    pub tools: Vec<Tool>,
    /// Conversation messages.
    pub messages: Vec<Message>,
}

// =============================================================================
// Summarization
// =============================================================================

/// Structured data extracted from conversation context during summarization.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtractedData {
    /// The main goal or task being worked on.
    #[serde(default)]
    pub current_goal: String,
    /// Actions/steps that have been completed.
    #[serde(default)]
    pub completed_steps: Vec<String>,
    /// Tasks that were mentioned but not completed.
    #[serde(default)]
    pub pending_tasks: Vec<String>,
    /// Key decisions made and their rationale.
    #[serde(default)]
    pub key_decisions: Vec<KeyDecision>,
    /// Files that have been modified.
    #[serde(default)]
    pub files_modified: Vec<String>,
    /// Topics that were discussed.
    #[serde(default)]
    pub topics_discussed: Vec<String>,
    /// User preferences or constraints expressed.
    #[serde(default)]
    pub user_preferences: Vec<String>,
    /// Critical context that must be preserved.
    #[serde(default)]
    pub important_context: Vec<String>,
    /// Key reasoning insights from thinking blocks.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub thinking_insights: Vec<String>,
}

/// A key decision with rationale.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct KeyDecision {
    /// What was decided.
    pub decision: String,
    /// Why it was decided.
    pub reason: String,
}

/// Result of summarization containing structured data and narrative.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SummaryResult {
    /// Structured extracted data.
    pub extracted_data: ExtractedData,
    /// Human-readable narrative summary.
    pub narrative: String,
}

/// Provider type re-export for context module convenience.
pub use tron_core::messages::ProviderType;

// =============================================================================
// Tests
// =============================================================================

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
        assert_eq!(ThresholdLevel::from_ratio(1.0), ThresholdLevel::Exceeded);
    }

    #[test]
    fn threshold_level_serde_roundtrip() {
        for level in [
            ThresholdLevel::Normal,
            ThresholdLevel::Warning,
            ThresholdLevel::Alert,
            ThresholdLevel::Critical,
            ThresholdLevel::Exceeded,
        ] {
            let json = serde_json::to_string(&level).unwrap();
            let back: ThresholdLevel = serde_json::from_str(&json).unwrap();
            assert_eq!(level, back);
        }
    }

    #[test]
    fn compaction_config_default() {
        let cfg = CompactionConfig::default();
        assert!((cfg.threshold - 0.70).abs() < f64::EPSILON);
        assert!((cfg.preserve_ratio - 0.20).abs() < f64::EPSILON);
    }

    #[test]
    fn extracted_data_default() {
        let data = ExtractedData::default();
        assert!(data.current_goal.is_empty());
        assert!(data.completed_steps.is_empty());
        assert!(data.key_decisions.is_empty());
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
        assert_eq!(back.key_decisions.len(), 1);
        assert_eq!(back.key_decisions[0].decision, "Use JWT");
    }

    #[test]
    fn summary_result_serde() {
        let result = SummaryResult {
            narrative: "User worked on auth.".into(),
            extracted_data: ExtractedData::default(),
        };
        let json = serde_json::to_string(&result).unwrap();
        let back: SummaryResult = serde_json::from_str(&json).unwrap();
        assert_eq!(back.narrative, "User worked on auth.");
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
                tools: 2000,
                rules: 500,
                messages: 1500,
            },
            rules: None,
        };
        let json = serde_json::to_value(&snapshot).unwrap();
        assert_eq!(json["currentTokens"], 5000);
        assert_eq!(json["thresholdLevel"], "normal");
        assert_eq!(json["breakdown"]["systemPrompt"], 1000);
    }

    #[test]
    fn pre_turn_validation_serde() {
        let v = PreTurnValidation {
            can_proceed: true,
            needs_compaction: false,
            current_tokens: 5000,
            context_limit: 200_000,
        };
        let json = serde_json::to_value(&v).unwrap();
        assert_eq!(json["canProceed"], true);
        assert_eq!(json["needsCompaction"], false);
    }

    #[test]
    fn compaction_result_serde() {
        let result = CompactionResult {
            success: true,
            tokens_before: 50_000,
            tokens_after: 10_000,
            compression_ratio: 0.2,
            summary: "User worked on auth.".into(),
            extracted_data: None,
        };
        let json = serde_json::to_value(&result).unwrap();
        assert_eq!(json["success"], true);
        assert_eq!(json["tokensBefore"], 50_000);
    }

    #[test]
    fn rules_level_serde() {
        assert_eq!(
            serde_json::to_string(&RulesLevel::Global).unwrap(),
            "\"global\""
        );
        assert_eq!(
            serde_json::to_string(&RulesLevel::Project).unwrap(),
            "\"project\""
        );
        assert_eq!(
            serde_json::to_string(&RulesLevel::Directory).unwrap(),
            "\"directory\""
        );
    }

    #[test]
    fn session_memory_entry_serde() {
        let entry = SessionMemoryEntry {
            title: "Test".into(),
            content: "Content".into(),
            tokens: 10,
        };
        let json = serde_json::to_string(&entry).unwrap();
        let back: SessionMemoryEntry = serde_json::from_str(&json).unwrap();
        assert_eq!(back.title, "Test");
        assert_eq!(back.tokens, 10);
    }
}
