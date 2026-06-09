//! Provider request audit DTOs persisted before model streaming starts.
//!
//! `model.provider_request` rows are the provider-audit section source for
//! canonical replay manifests. The DTO is protocol-owned because the turn loop
//! persists it before the provider stream opens and replay later reads it from
//! durable session events without importing provider internals.
//! Provenance marker: provider-audit section source for canonical replay manifests.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::messages::Provider;

/// Canonical format marker for provider request audit events.
pub const MODEL_PROVIDER_REQUEST_AUDIT_FORMAT: &str = "tron.model_provider_request.v1";

/// Whether an audit body is an exact provider request or a provider-neutral snapshot.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderAuditPayloadKind {
    /// The body matches the provider's request envelope before the HTTP stream opens.
    ExactProviderEnvelope,
    /// The body is a provider-independent snapshot for providers without an exact envelope.
    ProviderIndependentSnapshot,
}

/// Provider request body captured for replay/audit.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderAuditPayload {
    /// Body classification.
    pub kind: ProviderAuditPayloadKind,
    /// JSON body. Exact envelopes are stored as the provider would send them.
    pub body: Value,
}

impl ProviderAuditPayload {
    /// Build an exact provider-envelope audit body.
    #[must_use]
    pub fn exact_provider_envelope(body: Value) -> Self {
        Self {
            kind: ProviderAuditPayloadKind::ExactProviderEnvelope,
            body,
        }
    }

    /// Build a provider-independent snapshot audit body.
    #[must_use]
    pub fn provider_independent_snapshot(body: Value) -> Self {
        Self {
            kind: ProviderAuditPayloadKind::ProviderIndependentSnapshot,
            body,
        }
    }
}

/// Durable audit payload written as `model.provider_request`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelProviderRequestAudit {
    /// Format marker.
    pub format: String,
    /// Canonical provider enum.
    pub provider_type: Provider,
    /// Provider label used by runtime metrics.
    pub provider_name: String,
    /// Model identifier.
    pub model: String,
    /// Effective context window used for the turn.
    pub context_window: u64,
    /// Session id used for prompt-cache routing and replay joins.
    pub session_id: String,
    /// Canonical reasoning level, when requested.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_level: Option<String>,
    /// Number of provider-visible messages in the request context.
    pub message_count: usize,
    /// Number of provider-visible capabilities in the request context.
    pub capability_count: usize,
    /// Provider stream options produced by the model responder boundary.
    pub stream_options: Value,
    /// Provider request envelope or provider-independent request-input snapshot.
    pub provider_request: ProviderAuditPayload,
}

impl ModelProviderRequestAudit {
    /// Build a canonical model-provider audit payload.
    #[must_use]
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        provider_type: Provider,
        provider_name: impl Into<String>,
        model: impl Into<String>,
        context_window: u64,
        session_id: impl Into<String>,
        reasoning_level: Option<String>,
        message_count: usize,
        capability_count: usize,
        stream_options: Value,
        provider_request: ProviderAuditPayload,
    ) -> Self {
        Self {
            format: MODEL_PROVIDER_REQUEST_AUDIT_FORMAT.to_owned(),
            provider_type,
            provider_name: provider_name.into(),
            model: model.into(),
            context_window,
            session_id: session_id.into(),
            reasoning_level,
            message_count,
            capability_count,
            stream_options,
            provider_request,
        }
    }
}
