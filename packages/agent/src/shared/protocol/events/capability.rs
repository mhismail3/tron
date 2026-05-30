//! Capability identity DTOs attached to engine protocol events.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Capability identity attached to provider protocol capability events.
///
/// `capability.invocation.started` / `capability.invocation.completed` are current capability event labels,
/// but active UI identity must come from these fields. The model-facing name is
/// intentionally separate from the resolved contract/implementation so an
/// `execute` call can render the concrete capability after binding resolution.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityEventIdentity {
    /// Provider-visible primitive name. The model-facing surface is the single
    /// `execute` orchestrator; this field remains a projection label for
    /// immutable event records rather than an execution policy source.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_primitive_name: Option<String>,
    /// Stable abstract capability contract id.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub contract_id: Option<String>,
    /// Concrete implementation selected for execution.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub implementation_id: Option<String>,
    /// Engine function id backing the selected implementation.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub function_id: Option<String>,
    /// Plugin or domain manifest that owns the implementation.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plugin_id: Option<String>,
    /// Worker that registered the selected function.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub worker_id: Option<String>,
    /// Digest of the selected function schema.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub schema_digest: Option<String>,
    /// Engine catalog revision used for resolution.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub catalog_revision: Option<u64>,
    /// Trust tier assigned by registry/plugin policy.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trust_tier: Option<String>,
    /// Capability risk level.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub risk_level: Option<String>,
    /// Capability effect class.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub effect_class: Option<String>,
    /// Trace id correlating stream, ledger, and audit records.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trace_id: Option<String>,
    /// Root invocation id for the capability execution tree.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub root_invocation_id: Option<String>,
    /// Durable binding decision id selected by the registry resolver.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub binding_decision_id: Option<String>,
    /// Optional presentation theme color declared by capability metadata.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub theme_color: Option<String>,
    /// Optional capability-owned presentation metadata for native clients.
    ///
    /// This is a bounded hint projection, not authority. Clients may render
    /// `displayName`, `chipTitle`, `icon`, and `themeColor`, while execution
    /// identity and policy remain in the typed identity fields above.
    #[serde(rename = "presentationHints", skip_serializing_if = "Option::is_none")]
    pub presentation_hints: Option<Value>,
}

impl CapabilityEventIdentity {
    /// Build identity for a model-facing primitive before binding resolution.
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
