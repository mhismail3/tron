//! High-level Tron agent event support types and macro.

use serde::{Deserialize, Serialize};

/// Common fields for all agent events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BaseEvent {
    /// Session this event belongs to.
    pub session_id: String,
    /// ISO 8601 timestamp.
    pub timestamp: String,
    /// Monotonic per-session sequence number, assigned at emission time.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sequence: Option<i64>,
    /// Engine trace id for events emitted inside an engine invocation chain.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trace_id: Option<String>,
    /// Parent engine invocation id for events emitted by a child invocation.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_invocation_id: Option<String>,
}

impl BaseEvent {
    /// Create a new base event with the current UTC timestamp.
    #[must_use]
    pub fn now(session_id: impl Into<String>) -> Self {
        Self {
            session_id: session_id.into(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            sequence: None,
            trace_id: None,
            parent_invocation_id: None,
        }
    }

    /// Attach a sequence number.
    #[must_use]
    pub fn with_sequence(mut self, seq: i64) -> Self {
        self.sequence = Some(seq);
        self
    }

    /// Attach engine trace context.
    #[must_use]
    pub fn with_trace_context(
        mut self,
        trace_id: Option<String>,
        parent_invocation_id: Option<String>,
    ) -> Self {
        self.trace_id = trace_id;
        self.parent_invocation_id = parent_invocation_id;
        self
    }
}

/// Hook completion result.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HookResult {
    /// Hook allowed the operation to continue.
    Continue,
    /// Hook blocked the operation.
    Block,
    /// Hook modified the operation.
    Modify,
}

/// Background hook completion result.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BackgroundHookResult {
    /// All hooks succeeded.
    Continue,
    /// At least one hook failed.
    Error,
}

/// Info about a dynamically activated scoped rule.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivatedRuleInfo {
    /// Path relative to project root (e.g., `src/context/.claude/CLAUDE.md`).
    pub relative_path: String,
    /// Directory this rule applies to (e.g., `src/context`).
    pub scope_dir: String,
}

/// Compaction trigger reason.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CompactionReason {
    /// Token threshold exceeded.
    ThresholdExceeded,
    /// Progress signal detected (commit, push, PR, tag).
    ProgressSignal,
    /// User requested compaction.
    Manual,
}

// ─────────────────────────────────────────────────────────────────────────────
// tron_events! macro — generates TronEvent enum, base(), event_type()
// ─────────────────────────────────────────────────────────────────────────────

/// Declarative macro that generates [`TronEvent`], its `base()` and
/// `event_type()` accessors, and a compile-time `VARIANT_COUNT`.
///
/// Adding a new variant requires ONE edit (inside this invocation).
/// The compiler enforces exhaustive matching everywhere else.
#[path = "tron/catalog.rs"]
mod catalog;

pub use catalog::TronEvent;
#[cfg(test)]
pub(crate) use catalog::VARIANT_COUNT;
