//! Tool execution context attached to engine protocol events.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Causal and presentation context attached to provider tool events.
///
/// The durable `tool.*` event names describe persisted event kinds, not a
/// model-visible catalog. This context stays at the bare loop layer and never
/// controls execution.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolEventIdentity {
    /// Trace id correlating stream, ledger, and audit records.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trace_id: Option<String>,
    /// Root invocation id for the tool execution tree.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub root_invocation_id: Option<String>,
    /// Optional runtime-owned presentation theme color.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub theme_color: Option<String>,
    /// Optional runtime-owned presentation metadata for native clients.
    ///
    /// This is a bounded hint projection, not authority. Clients may render
    /// `displayName`, `chipTitle`, `summary`/`subtitle`, lifecycle labels,
    /// `icon`, and `themeColor`; execution truth remains in trace records.
    #[serde(rename = "presentationHints", skip_serializing_if = "Option::is_none")]
    pub presentation_hints: Option<Value>,
}

impl ToolEventIdentity {
    /// Whether this identity carries no tool metadata.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self == &Self::default()
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Tool invocation summary in a batch event.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ToolInvocationSummary {
    /// Tool invocation ID.
    pub id: String,
    /// Model-facing tool name.
    pub name: String,
    /// Primitive arguments.
    pub arguments: serde_json::Map<String, Value>,
}
