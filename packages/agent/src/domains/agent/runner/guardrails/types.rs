//! Core types for the guardrail system.
//!
//! Defines severity levels, rule tiers, scopes, evaluation contexts,
//! and result types used throughout the guardrail engine.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Severity of a triggered guardrail rule.
///
/// Determines what action is taken when a rule matches:
/// - `Block`: Stop tool execution entirely
/// - `Warn`: Log a warning but continue
/// - `Audit`: Silently log for analysis
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    /// Block tool execution.
    Block,
    /// Warn but allow execution.
    Warn,
    /// Silent audit log only.
    Audit,
}

impl std::fmt::Display for Severity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Block => write!(f, "block"),
            Self::Warn => write!(f, "warn"),
            Self::Audit => write!(f, "audit"),
        }
    }
}

/// Rule tier determines whether a rule can be disabled.
///
/// - `Core`: Immutable, always active. Cannot be disabled by configuration.
/// - `Standard`: Can be disabled via settings.
/// - `Custom`: User-defined rules.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RuleTier {
    /// Core rules cannot be disabled.
    Core,
    /// Standard rules can be disabled via configuration.
    Standard,
    /// Custom user-defined rules.
    Custom,
}

impl std::fmt::Display for RuleTier {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Core => write!(f, "core"),
            Self::Standard => write!(f, "standard"),
            Self::Custom => write!(f, "custom"),
        }
    }
}

/// Where a rule applies.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Scope {
    /// Applies to all tools globally.
    Global,
    /// Applies to specific tools only.
    Tool,
}

impl std::fmt::Display for Scope {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Global => write!(f, "global"),
            Self::Tool => write!(f, "tool"),
        }
    }
}

/// Context passed to rule evaluation.
///
/// Contains the tool name, arguments, and optional session/call metadata
/// needed to evaluate guardrail rules.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EvaluationContext {
    /// Tool being invoked (e.g., "Bash", "Write", "Edit").
    pub tool_name: String,
    /// Arguments passed to the tool as a JSON object.
    pub tool_arguments: serde_json::Value,
    /// Session ID for audit logging.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// Tool call ID.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
}

/// Result of evaluating a single rule.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuleEvaluationResult {
    /// ID of the rule that was evaluated.
    pub rule_id: String,
    /// Whether the rule was triggered.
    pub triggered: bool,
    /// Severity of the triggered rule (present only if triggered).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub severity: Option<Severity>,
    /// Reason for triggering (for user display).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// Detailed information for audit log.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<serde_json::Value>,
}

impl RuleEvaluationResult {
    /// Create a non-triggered result for the given rule.
    pub fn not_triggered(rule_id: impl Into<String>) -> Self {
        Self {
            rule_id: rule_id.into(),
            triggered: false,
            severity: None,
            reason: None,
            details: None,
        }
    }

    /// Create a triggered result with severity and reason.
    pub fn triggered(
        rule_id: impl Into<String>,
        severity: Severity,
        reason: impl Into<String>,
    ) -> Self {
        Self {
            rule_id: rule_id.into(),
            triggered: true,
            severity: Some(severity),
            reason: Some(reason.into()),
            details: None,
        }
    }

    /// Add details to this result.
    #[must_use]
    pub fn with_details(mut self, details: serde_json::Value) -> Self {
        self.details = Some(details);
        self
    }
}

/// Final result of evaluating all applicable rules for a tool call.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GuardrailEvaluation {
    /// Whether the tool should be blocked.
    pub blocked: bool,
    /// Reason for blocking (if blocked).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub block_reason: Option<String>,
    /// All rules that were triggered.
    pub triggered_rules: Vec<RuleEvaluationResult>,
    /// Whether there were any warnings.
    pub has_warnings: bool,
    /// Warning messages.
    pub warnings: Vec<String>,
    /// Evaluation timestamp (ISO 8601).
    pub timestamp: String,
    /// Duration in milliseconds.
    pub duration_ms: u64,
}

/// Audit log entry recording a guardrail evaluation.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuditEntry {
    /// Unique entry ID.
    pub id: String,
    /// Timestamp (ISO 8601).
    pub timestamp: String,
    /// Session ID.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// Tool being invoked.
    pub tool_name: String,
    /// Tool call ID.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
    /// Evaluation result.
    pub evaluation: GuardrailEvaluation,
    /// Tool arguments (may be redacted).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_arguments: Option<serde_json::Value>,
}

/// Statistics about audit log entries.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuditStats {
    /// Total number of entries.
    pub total: usize,
    /// Number of blocked evaluations.
    pub blocked: usize,
    /// Number of evaluations with warnings.
    pub warnings: usize,
    /// Number of evaluations that passed.
    pub passed: usize,
    /// Counts by tool name.
    pub by_tool: HashMap<String, usize>,
    /// Counts by rule ID.
    pub by_rule: HashMap<String, usize>,
}

/// Options for creating the guardrail engine.
#[derive(Debug, Default)]
pub struct GuardrailEngineOptions {
    /// Enable audit logging (default: true).
    pub enable_audit: Option<bool>,
    /// Maximum audit entries to keep in memory.
    pub max_audit_entries: Option<usize>,
    /// Custom rules to add at initialization.
    pub custom_rules: Vec<super::rules::GuardrailRule>,
    /// Rule overrides (by rule ID).
    pub rule_overrides: HashMap<String, RuleOverride>,
}

/// Override settings for a specific rule.
#[derive(Debug, Clone, Default)]
pub struct RuleOverride {
    /// Whether the rule is enabled.
    pub enabled: Option<bool>,
}

/// Parameters for logging an audit entry.
pub struct AuditEntryParams {
    /// Session ID.
    pub session_id: Option<String>,
    /// Tool name.
    pub tool_name: String,
    /// Tool call ID.
    pub tool_call_id: Option<String>,
    /// Tool arguments (will be redacted).
    pub tool_arguments: Option<serde_json::Value>,
    /// Evaluation result.
    pub evaluation: GuardrailEvaluation,
}
