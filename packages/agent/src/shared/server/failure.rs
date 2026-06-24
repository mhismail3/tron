//! Canonical server-side failure envelope and vocabulary.
//!
//! Active runtime, transport, capability, provider, durable-event, and replay
//! paths convert failures into this envelope before exposing them to clients or
//! storing structured failure details. The envelope is intentionally
//! transport-neutral; individual protocol layers may keep their existing wire
//! fields while adding these fields.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Engine validation or typed-id failure.
pub const ENGINE_INVALID_ID: &str = "ENGINE_INVALID_ID";
/// Engine function id parse failure.
pub const ENGINE_INVALID_FUNCTION_ID: &str = "ENGINE_INVALID_FUNCTION_ID";
/// Engine namespace authorization failure.
pub const ENGINE_NAMESPACE_DENIED: &str = "ENGINE_NAMESPACE_DENIED";
/// Engine delivery mode is not implemented.
pub const ENGINE_UNSUPPORTED_DELIVERY_MODE: &str = "ENGINE_UNSUPPORTED_DELIVERY_MODE";
/// Engine delivery mode is not allowed by a function definition.
pub const ENGINE_DELIVERY_MODE_NOT_ALLOWED: &str = "ENGINE_DELIVERY_MODE_NOT_ALLOWED";
/// Engine ledger or durable store operation failed.
pub const ENGINE_LEDGER_FAILURE: &str = "ENGINE_LEDGER_FAILURE";
/// Historical stored invocation failure replayed from the ledger.
pub const ENGINE_STORED_INVOCATION_ERROR: &str = "ENGINE_STORED_INVOCATION_ERROR";
/// Engine schema definition is invalid.
pub const ENGINE_INVALID_SCHEMA: &str = "ENGINE_INVALID_SCHEMA";
/// Engine invocation payload violates a declared schema.
pub const ENGINE_SCHEMA_VIOLATION: &str = "ENGINE_SCHEMA_VIOLATION";
/// Engine policy rejected a request.
pub const ENGINE_POLICY_VIOLATION: &str = "ENGINE_POLICY_VIOLATION";
/// Engine function exists but cannot currently be routed.
pub const ENGINE_NOT_ROUTABLE: &str = "ENGINE_NOT_ROUTABLE";
/// Engine domain capability preserved a native failure envelope.
pub const ENGINE_DOMAIN_FAILURE: &str = "ENGINE_DOMAIN_FAILURE";
/// Engine worker transport failed before a result arrived.
pub const ENGINE_WORKER_TRANSPORT_FAILURE: &str = "ENGINE_WORKER_TRANSPORT_FAILURE";
/// Engine handler returned an application failure.
pub const ENGINE_HANDLER_FAILED: &str = "ENGINE_HANDLER_FAILED";

/// Provider HTTP/network failure.
pub const PROVIDER_HTTP_ERROR: &str = "PROVIDER_HTTP_ERROR";
/// Provider JSON serialization/deserialization failure.
pub const PROVIDER_JSON_ERROR: &str = "PROVIDER_JSON_ERROR";
/// Provider SSE parsing failure.
pub const PROVIDER_SSE_PARSE_ERROR: &str = "PROVIDER_SSE_PARSE_ERROR";
/// Provider authentication failure.
pub const PROVIDER_AUTH_ERROR: &str = "PROVIDER_AUTH_ERROR";
/// Provider/model registry rejected the model.
pub const PROVIDER_UNSUPPORTED_MODEL: &str = "PROVIDER_UNSUPPORTED_MODEL";
/// Provider returned a rate-limit failure.
pub const PROVIDER_RATE_LIMITED: &str = "PROVIDER_RATE_LIMITED";
/// Provider returned an API failure.
pub const PROVIDER_API_ERROR: &str = "PROVIDER_API_ERROR";
/// Provider stream/request was cancelled.
pub const PROVIDER_CANCELLED: &str = "PROVIDER_CANCELLED";
/// Provider-specific error without narrower classification.
pub const PROVIDER_OTHER_ERROR: &str = "PROVIDER_OTHER_ERROR";
/// Provider-neutral model responder failure.
pub const MODEL_RESPONSE_ERROR: &str = "MODEL_RESPONSE_ERROR";
/// Provider-neutral model responder auth failure.
pub const MODEL_AUTH_ERROR: &str = "MODEL_AUTH_ERROR";
/// Provider request audit construction failure.
pub const MODEL_PROVIDER_REQUEST_AUDIT_FAILED: &str = "MODEL_PROVIDER_REQUEST_AUDIT_FAILED";
/// Runtime capability execution failure.
pub const RUNTIME_CAPABILITY_ERROR: &str = "RUNTIME_CAPABILITY_ERROR";
/// Runtime context-management failure.
pub const RUNTIME_CONTEXT_ERROR: &str = "RUNTIME_CONTEXT_ERROR";
/// Runtime cancellation.
pub const RUNTIME_CANCELLED: &str = "RUNTIME_CANCELLED";
/// Runtime max-turns guard failure.
pub const RUNTIME_MAX_TURNS: &str = "RUNTIME_MAX_TURNS";
/// Runtime server capacity failure.
pub const RUNTIME_SERVER_BUSY: &str = "RUNTIME_SERVER_BUSY";
/// Runtime persistence failure.
pub const RUNTIME_PERSISTENCE_ERROR: &str = "RUNTIME_PERSISTENCE_ERROR";
/// Runtime run result reported an error after the original source boundary.
pub const RUNTIME_RUN_ERROR: &str = "RUNTIME_RUN_ERROR";
/// Runtime failed to resolve the live engine capability surface.
pub const ENGINE_TOOL_SURFACE_FAILED: &str = "ENGINE_TOOL_SURFACE_FAILED";
/// Runtime failed to persist the provider request audit record.
pub const MODEL_PROVIDER_REQUEST_AUDIT_PERSIST_FAILED: &str =
    "MODEL_PROVIDER_REQUEST_AUDIT_PERSIST_FAILED";
/// Runtime failed to create the streaming journal.
pub const JOURNAL_CREATE_FAILED: &str = "JOURNAL_CREATE_FAILED";
/// Runtime failed to persist the assistant message.
pub const ASSISTANT_PERSIST_FAILED: &str = "ASSISTANT_PERSIST_FAILED";
/// Requested model-facing capability primitive is not present in the resolved surface.
pub const CAPABILITY_PRIMITIVE_NOT_FOUND: &str = "CAPABILITY_PRIMITIVE_NOT_FOUND";
/// Capability execution requires an engine host but none is available.
pub const CAPABILITY_ENGINE_HOST_UNAVAILABLE: &str = "CAPABILITY_ENGINE_HOST_UNAVAILABLE";
/// Engine invocation completed without a capability result payload.
pub const CAPABILITY_ENGINE_RESULT_MISSING: &str = "CAPABILITY_ENGINE_RESULT_MISSING";
/// Engine invocation returned a payload that is not a valid capability result.
pub const CAPABILITY_RESULT_INVALID: &str = "CAPABILITY_RESULT_INVALID";

/// Stable public failure category.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FailureCategory {
    /// Client input, schema, JSON, or protocol validation failure.
    InvalidRequest,
    /// Requested model id is unsupported.
    InvalidModel,
    /// Requested resource does not exist.
    NotFound,
    /// Resource or feature is currently unavailable.
    Unavailable,
    /// Request conflicts with existing state, ownership, idempotency, or load.
    Conflict,
    /// Authentication or authorization failure.
    Auth,
    /// Network transport failure.
    Network,
    /// Provider or server rate limiting.
    RateLimit,
    /// Provider API failure.
    Api,
    /// JSON, SSE, or provider stream parsing failure.
    Parse,
    /// User or system cancellation.
    Cancelled,
    /// Model-requested primitive execution failure.
    Capability,
    /// Engine policy, routing, schema, worker, or ledger failure.
    Engine,
    /// Event store, ledger, journal, replay, or storage failure.
    Persistence,
    /// Unexpected server failure after sanitization.
    Internal,
    /// Historical/imported failure that cannot be narrowed further.
    Unknown,
}

impl FailureCategory {
    /// Wire spelling for this category.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::InvalidRequest => "invalid_request",
            Self::InvalidModel => "invalid_model",
            Self::NotFound => "not_found",
            Self::Unavailable => "unavailable",
            Self::Conflict => "conflict",
            Self::Auth => "auth",
            Self::Network => "network",
            Self::RateLimit => "rate_limit",
            Self::Api => "api",
            Self::Parse => "parse",
            Self::Cancelled => "cancelled",
            Self::Capability => "capability",
            Self::Engine => "engine",
            Self::Persistence => "persistence",
            Self::Internal => "internal",
            Self::Unknown => "unknown",
        }
    }
}

impl std::fmt::Display for FailureCategory {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Stable origin for the layer that classified a failure.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FailureOrigin {
    /// Generic server capability or helper path.
    Server,
    /// Engine kernel, host, worker, or durability layer.
    Engine,
    /// Provider-native error source.
    ModelProvider,
    /// Provider-neutral model responder boundary.
    ModelResponder,
    /// Agent runtime and turn loop.
    AgentRuntime,
    /// Model-requested primitive invocation path.
    Capability,
    /// Client transport adapter.
    Transport,
    /// Session event store and reconstruction path.
    EventStore,
    /// Auth credential or OAuth path.
    Auth,
    /// Replay/export path.
    Replay,
}

impl FailureOrigin {
    /// Wire spelling for this origin.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Server => "server",
            Self::Engine => "engine",
            Self::ModelProvider => "model_provider",
            Self::ModelResponder => "model_responder",
            Self::AgentRuntime => "agent_runtime",
            Self::Capability => "capability",
            Self::Transport => "transport",
            Self::EventStore => "event_store",
            Self::Auth => "auth",
            Self::Replay => "replay",
        }
    }
}

impl std::fmt::Display for FailureOrigin {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Trace and runtime references attached to a failure when available.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FailureReferences {
    /// Engine trace id.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trace_id: Option<String>,
    /// Engine invocation id.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub invocation_id: Option<String>,
    /// Parent engine invocation id.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_invocation_id: Option<String>,
    /// Session id.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// Durable source event id.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_event_id: Option<String>,
}

/// Canonical public failure envelope.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FailureEnvelope {
    /// Stable machine-readable public code.
    pub code: String,
    /// Stable public category.
    pub category: FailureCategory,
    /// Sanitized public message.
    pub message: String,
    /// Whether retrying the same request without user changes may succeed.
    pub retryable: bool,
    /// Whether the user/operator can reasonably recover from this condition.
    pub recoverable: bool,
    /// Layer that classified this failure.
    pub origin: FailureOrigin,
    /// Provider name when the failure came from a model provider.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    /// Model id when known.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// HTTP status code or provider status code when safe to expose.
    #[serde(rename = "statusCode", skip_serializing_if = "Option::is_none")]
    pub status_code: Option<u16>,
    /// Provider-specific or layer-specific error type/code.
    #[serde(rename = "errorType", skip_serializing_if = "Option::is_none")]
    pub error_type: Option<String>,
    /// Retry delay in milliseconds when provided by the upstream source.
    #[serde(rename = "retryAfterMs", skip_serializing_if = "Option::is_none")]
    pub retry_after_ms: Option<u64>,
    /// Suggested user/operator action.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub suggestion: Option<String>,
    /// Safe structured details.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
    /// Optional trace/session/invocation references.
    #[serde(flatten)]
    pub references: FailureReferences,
}

impl FailureEnvelope {
    /// Create a canonical failure envelope.
    #[must_use]
    pub fn new(
        code: impl Into<String>,
        category: FailureCategory,
        message: impl Into<String>,
        retryable: bool,
        recoverable: bool,
        origin: FailureOrigin,
    ) -> Self {
        Self {
            code: code.into(),
            category,
            message: message.into(),
            retryable,
            recoverable,
            origin,
            provider: None,
            model: None,
            status_code: None,
            error_type: None,
            retry_after_ms: None,
            suggestion: None,
            details: None,
            references: FailureReferences::default(),
        }
    }

    /// Attach provider/model identity.
    #[must_use]
    pub fn with_provider_model(
        mut self,
        provider: impl Into<String>,
        model: impl Into<String>,
    ) -> Self {
        self.provider = Some(provider.into());
        self.model = Some(model.into());
        self
    }

    /// Attach safe structured details.
    #[must_use]
    pub fn with_details(mut self, details: Option<Value>) -> Self {
        self.details = details;
        self
    }

    /// Attach a status code.
    #[must_use]
    pub fn with_status_code(mut self, status_code: Option<u16>) -> Self {
        self.status_code = status_code;
        self
    }

    /// Attach a provider/layer error type.
    #[must_use]
    pub fn with_error_type(mut self, error_type: Option<String>) -> Self {
        self.error_type = error_type;
        self
    }

    /// Attach a retry-after delay in milliseconds.
    #[must_use]
    pub fn with_retry_after_ms(mut self, retry_after_ms: Option<u64>) -> Self {
        self.retry_after_ms = retry_after_ms;
        self
    }

    /// Attach a suggested user/operator action.
    #[must_use]
    pub fn with_suggestion(mut self, suggestion: Option<String>) -> Self {
        self.suggestion = suggestion;
        self
    }

    /// Attach an engine trace id.
    #[must_use]
    pub fn with_trace_id(mut self, trace_id: Option<String>) -> Self {
        self.references.trace_id = trace_id;
        self
    }

    /// Attach an invocation id.
    #[must_use]
    pub fn with_invocation_id(mut self, invocation_id: Option<String>) -> Self {
        self.references.invocation_id = invocation_id;
        self
    }

    /// Attach a parent invocation id.
    #[must_use]
    pub fn with_parent_invocation_id(mut self, parent_invocation_id: Option<String>) -> Self {
        self.references.parent_invocation_id = parent_invocation_id;
        self
    }

    /// Attach a session id.
    #[must_use]
    pub fn with_session_id(mut self, session_id: Option<String>) -> Self {
        self.references.session_id = session_id;
        self
    }

    /// Attach a durable source event id.
    #[must_use]
    pub fn with_source_event_id(mut self, source_event_id: Option<String>) -> Self {
        self.references.source_event_id = source_event_id;
        self
    }

    /// Serialize this envelope as JSON details.
    #[must_use]
    pub fn to_value(&self) -> Value {
        serde_json::to_value(self).expect("FailureEnvelope serializes")
    }

    /// Return `details` with the full canonical envelope embedded under
    /// `failure`, preserving existing safe detail fields when they are objects.
    #[must_use]
    pub fn details_with_failure(&self) -> Value {
        let mut object = match self.details.clone() {
            Some(Value::Object(object)) => object,
            Some(value) => {
                let mut object = serde_json::Map::new();
                let _ = object.insert("details".to_owned(), value);
                object
            }
            None => serde_json::Map::new(),
        };
        let _ = object.insert("failure".to_owned(), self.to_value());
        Value::Object(object)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn failure_envelope_serializes_canonical_wire_fields() {
        let failure = FailureEnvelope::new(
            "PROVIDER_RATE_LIMITED",
            FailureCategory::RateLimit,
            "Rate limited",
            true,
            true,
            FailureOrigin::ModelProvider,
        )
        .with_provider_model("openai", "gpt-5.5")
        .with_status_code(Some(429))
        .with_error_type(Some("rate_limit_exceeded".to_owned()))
        .with_retry_after_ms(Some(1200))
        .with_trace_id(Some("trace-1".to_owned()))
        .with_details(Some(json!({"requestId": "safe"})));

        let value = failure.to_value();

        assert_eq!(value["code"], "PROVIDER_RATE_LIMITED");
        assert_eq!(value["category"], "rate_limit");
        assert_eq!(value["origin"], "model_provider");
        assert_eq!(value["provider"], "openai");
        assert_eq!(value["model"], "gpt-5.5");
        assert_eq!(value["statusCode"], 429);
        assert_eq!(value["errorType"], "rate_limit_exceeded");
        assert_eq!(value["retryAfterMs"], 1200);
        assert_eq!(value["traceId"], "trace-1");
        assert_eq!(value["details"]["requestId"], "safe");
    }

    #[test]
    fn details_with_failure_preserves_existing_details() {
        let failure = FailureEnvelope::new(
            "INVALID_PARAMS",
            FailureCategory::InvalidRequest,
            "bad input",
            false,
            true,
            FailureOrigin::Transport,
        )
        .with_details(Some(json!({"field": "prompt"})));

        let details = failure.details_with_failure();

        assert_eq!(details["field"], "prompt");
        assert_eq!(details["failure"]["code"], "INVALID_PARAMS");
        assert_eq!(details["failure"]["category"], "invalid_request");
    }
}
