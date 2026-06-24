//! Primitive execution identity DTOs attached to engine protocol events.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Primitive execution identity attached to provider protocol capability events.
///
/// The event names still use the historical `capability.*` labels because they
/// describe persisted event kinds, not a model-visible catalog. The identity
/// itself stays at the bare loop layer: primitive name, optional operation, and
/// trace anchors.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityEventIdentity {
    /// Provider-visible primitive name. The model-facing surface is the single
    /// `execute` orchestrator; this field remains a projection label for
    /// immutable event records rather than an execution policy source.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_primitive_name: Option<String>,
    /// Primitive operation requested inside `execute`, for example
    /// `file_write` or `trace_get`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub operation_name: Option<String>,
    /// Trace id correlating stream, ledger, and audit records.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trace_id: Option<String>,
    /// Root invocation id for the capability execution tree.
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

impl CapabilityEventIdentity {
    /// Build identity for a model-facing primitive before operation details are
    /// available.
    #[must_use]
    pub fn with_model_primitive(name: impl Into<String>) -> Self {
        Self {
            model_primitive_name: Some(name.into()),
            ..Self::default()
        }
    }

    /// Whether this identity carries no capability metadata.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self == &Self::default()
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Capability invocation summary in a batch event.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CapabilityInvocationSummary {
    /// Capability invocation ID.
    pub id: String,
    /// Model-facing primitive name.
    pub name: String,
    /// Primitive arguments.
    pub arguments: serde_json::Map<String, Value>,
}
