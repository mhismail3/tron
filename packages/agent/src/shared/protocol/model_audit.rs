//! Provider request audit DTOs persisted before model streaming starts.
//!
//! `model.provider_request` rows are the provider-audit section source for
//! canonical replay manifests. The DTO is protocol-owned because the turn loop
//! persists it before the provider stream opens and replay later reads it from
//! durable session events without importing provider internals.
//! Provenance marker: provider-audit section source for canonical replay manifests.

use std::sync::LazyLock;

use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use thiserror::Error;

use super::messages::{Context, Message, Provider};
use crate::shared::foundation::redaction::redact_sensitive_content;

/// Request-local provenance retained beside, but never inside, one message.
///
/// Message bodies remain canonical in the agent message store. This
/// protocol-neutral sidecar carries only durable identifiers and an honest
/// generated/source label for provider-request inspection.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct MessageAuditSource {
    /// Durable session events that contributed to the message.
    pub event_ids: Vec<String>,
    /// Worker/tool invocation that produced a tool-result message.
    pub invocation_id: Option<String>,
    /// `durable_event`, `worker_invocation`, or `generated`.
    pub source_kind: String,
}

impl MessageAuditSource {
    /// Mark a message as generated inside the active runtime.
    #[must_use]
    pub fn generated() -> Self {
        Self {
            source_kind: "generated".to_owned(),
            ..Self::default()
        }
    }

    /// Build a durable event-backed source.
    #[must_use]
    pub fn events(event_ids: Vec<String>) -> Self {
        Self {
            event_ids,
            source_kind: "durable_event".to_owned(),
            ..Self::default()
        }
    }

    /// Build a tool/worker invocation-backed source.
    #[must_use]
    pub fn invocation(invocation_id: impl Into<String>, event_id: Option<String>) -> Self {
        Self {
            event_ids: event_id.into_iter().collect(),
            invocation_id: Some(invocation_id.into()),
            source_kind: "worker_invocation".to_owned(),
        }
    }
}

/// Canonical format marker for provider request audit events.
pub const MODEL_PROVIDER_REQUEST_AUDIT_FORMAT: &str = "tron.model_provider_request.v3";
/// Previous provider-request audit format retained for read compatibility.
pub const LEGACY_MODEL_PROVIDER_REQUEST_AUDIT_FORMAT: &str = "tron.model_provider_request.v2";
/// Maximum serialized JSON size accepted for a single provider request audit body.
///
/// Provider audit rows are durable replay inputs, but they are not a bulk blob
/// transport. Oversized request envelopes are projected to deterministic digest
/// evidence before the provider stream opens so every response retains matching
/// bounded request evidence.
pub const MAX_PROVIDER_AUDIT_PAYLOAD_BYTES: usize = 1_048_576;
/// Maximum string value retained inline in provider request audit evidence.
///
/// Provider wire requests may legitimately contain inline media or other bulk
/// values. The provider receives those bytes unchanged, while durable audit
/// evidence records a deterministic projection rather than duplicating bulk
/// content into the session event log. If the remaining request structure is
/// itself too large, the audit retains a whole-envelope byte count and digest.
pub const MAX_PROVIDER_AUDIT_INLINE_STRING_BYTES: usize = 16_384;

/// Provider audit payload validation failure.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum ProviderAuditPayloadError {
    /// Serialized payload exceeded [`MAX_PROVIDER_AUDIT_PAYLOAD_BYTES`].
    #[error(
        "provider request audit payload is too large: {actual_bytes} bytes exceeds {max_bytes} bytes"
    )]
    TooLarge {
        /// Actual serialized size in bytes.
        actual_bytes: usize,
        /// Maximum accepted serialized size in bytes.
        max_bytes: usize,
    },
    /// Serialized size could not be calculated.
    #[error("failed to serialize provider request audit payload: {0}")]
    Serialize(String),
}

/// Whether an audit body is exact, bulk-projected, or provider-neutral.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderAuditPayloadKind {
    /// The body matches the provider's request envelope before the HTTP stream opens.
    ExactProviderEnvelope,
    /// The body preserves the provider envelope structure while projecting
    /// bulk string values to bounded byte-count and digest evidence.
    ProviderEnvelopeProjection,
    /// The body is a provider-independent snapshot for providers without an exact envelope.
    ProviderIndependentSnapshot,
    /// A provider-independent snapshot whose bulk content or total structure
    /// required bounded projection.
    ProviderIndependentProjection,
}

/// One ordered provider-neutral contribution to the effective system prompt.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SystemContextContribution {
    /// Stable contribution kind such as `base_instructions` or
    /// `continuity_context`.
    pub kind: String,
    /// User-facing source label.
    pub label: String,
    /// Exact redacted contribution text in provider-neutral order.
    pub content: String,
    /// UTF-8 byte count before provider adaptation.
    pub byte_count: usize,
    /// Digest of the unredacted provider-neutral contribution.
    pub sha256: String,
    /// Request-specific source evidence.
    #[serde(default, skip_serializing_if = "Value::is_null")]
    pub provenance: Value,
}

impl SystemContextContribution {
    /// Build one redacted, integrity-bound contribution.
    #[must_use]
    pub fn new(
        kind: impl Into<String>,
        label: impl Into<String>,
        content: impl Into<String>,
        provenance: Value,
    ) -> Self {
        let content = content.into();
        Self {
            kind: kind.into(),
            label: label.into(),
            byte_count: content.len(),
            sha256: sha256_label(content.as_bytes()),
            content: redact_provider_audit_text(&content),
            provenance: redact_sensitive_json(provenance),
        }
    }
}

/// Result of evaluating one automatic context source for this request.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AutomaticContextEvaluation {
    /// Stable source kind.
    pub kind: String,
    /// `injected`, `empty`, `unavailable`, `failed`, `skipped`, or
    /// `deterministic_fallback`.
    pub outcome: String,
    /// Selection mechanism used for this request.
    pub mechanism: String,
    /// Exact redacted narrative when one was injected.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub narrative: Option<String>,
    /// Owning policy worker, when one ran.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worker_id: Option<String>,
    /// Immutable owning worker version.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worker_version: Option<String>,
    /// Durable hook invocation.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub invocation_id: Option<String>,
    /// Bounded source records or selected inbox items.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub sources: Vec<Value>,
    /// Sanitized fallback/failure explanation.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

/// Provider-visible message inventory entry.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContextMessageManifest {
    /// Zero-based position in the provider-neutral message sequence.
    pub ordinal: usize,
    /// Provider-neutral message role.
    pub role: String,
    /// Content forms projected into the message.
    pub content_kinds: Vec<String>,
    /// Serialized provider-neutral message size.
    pub byte_count: usize,
    /// Digest of the unredacted provider-neutral message.
    pub sha256: String,
    /// Bounded redacted human-readable preview.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preview: Option<String>,
    /// Whether the audit contains exact text or projected media metadata.
    pub projection: String,
    /// Durable source classification, or `generated` when no event exists.
    pub source_kind: String,
    /// Durable session events that contributed to this message, when known.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub source_event_ids: Vec<String>,
    /// Source worker invocation for worker-result messages, when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub invocation_id: Option<String>,
}

/// Provider-neutral environment contribution.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContextEnvironmentManifest {
    /// Redacted working-directory projection supplied to the provider.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub working_directory: Option<String>,
    /// Redacted server-origin projection supplied to the provider.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub server_origin: Option<String>,
    /// Digest of the unredacted provider-neutral environment fields.
    pub sha256: String,
}

/// Canonical explanation of one finalized provider request context.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContextManifest {
    /// Ordered system contributions whose concatenation is the system prompt.
    pub system_contributions: Vec<SystemContextContribution>,
    /// Provider-visible message inventory in exact order.
    pub messages: Vec<ContextMessageManifest>,
    /// Exact provider-neutral tool/surface evidence, including selected and
    /// omitted direct workers.
    pub tool_surface: Value,
    /// Outcomes from every automatic context source evaluated for the request.
    pub automatic_context: Vec<AutomaticContextEvaluation>,
    /// Provider-neutral environment contribution.
    pub environment: ContextEnvironmentManifest,
    /// Digest of the unredacted finalized system prompt.
    pub system_prompt_sha256: String,
    /// Digest of the unredacted finalized message sequence.
    pub messages_sha256: String,
    /// Digest of the unredacted finalized tool definitions.
    pub tools_sha256: String,
    /// Digest of the complete unredacted provider-neutral context.
    pub context_sha256: String,
}

impl ContextManifest {
    /// Finalize and verify one provider-neutral context manifest.
    ///
    /// The contribution sequence is authoritative for system-prompt
    /// construction. Any divergence fails before the provider stream opens.
    pub fn build(
        context: &Context,
        system_contributions: Vec<SystemContextContribution>,
        tool_surface: Value,
        automatic_context: Vec<AutomaticContextEvaluation>,
        message_sources: &[MessageAuditSource],
    ) -> Result<Self, String> {
        let joined_system = system_contributions
            .iter()
            .map(|contribution| contribution.content.as_str())
            .collect::<Vec<_>>()
            .join("\n\n");
        let final_system = context.system_prompt.as_deref().unwrap_or_default();
        let redacted_final_system = redact_provider_audit_text(final_system);
        if joined_system != redacted_final_system {
            return Err(
                "system contribution manifest does not match finalized provider context".to_owned(),
            );
        }

        // Explicit destructuring keeps context inspection compile-coupled to
        // every provider-neutral Context field.
        let Context {
            system_prompt: _,
            messages,
            tools,
            working_directory,
            server_origin,
        } = context;
        let message_manifests = messages
            .iter()
            .enumerate()
            .map(|(ordinal, message)| {
                message_manifest(ordinal, message, message_sources.get(ordinal))
            })
            .collect::<Result<Vec<_>, _>>()?;
        let messages_json = serde_json::to_vec(messages).map_err(|error| error.to_string())?;
        let tools_json = serde_json::to_vec(tools).map_err(|error| error.to_string())?;
        let environment_value = serde_json::json!({
            "workingDirectory": working_directory,
            "serverOrigin": server_origin,
        });
        let environment_json =
            serde_json::to_vec(&environment_value).map_err(|error| error.to_string())?;
        let context_json = serde_json::to_vec(context).map_err(|error| error.to_string())?;

        Ok(Self {
            system_contributions,
            messages: message_manifests,
            tool_surface: redact_sensitive_json(tool_surface),
            automatic_context,
            environment: ContextEnvironmentManifest {
                working_directory: working_directory.as_deref().map(redact_provider_audit_text),
                server_origin: server_origin.as_deref().map(redact_provider_audit_text),
                sha256: sha256_label(&environment_json),
            },
            system_prompt_sha256: sha256_label(final_system.as_bytes()),
            messages_sha256: sha256_label(&messages_json),
            tools_sha256: sha256_label(&tools_json),
            context_sha256: sha256_label(&context_json),
        })
    }
}

fn message_manifest(
    ordinal: usize,
    message: &Message,
    source: Option<&MessageAuditSource>,
) -> Result<ContextMessageManifest, String> {
    let value = serde_json::to_value(message).map_err(|error| error.to_string())?;
    let bytes = serde_json::to_vec(&value).map_err(|error| error.to_string())?;
    let role = value["role"].as_str().unwrap_or("unknown").to_owned();
    let content = &value["content"];
    let content_kinds = match content {
        Value::String(_) => vec!["text".to_owned()],
        Value::Array(blocks) => blocks
            .iter()
            .filter_map(|block| block["type"].as_str().map(ToOwned::to_owned))
            .collect(),
        _ => Vec::new(),
    };
    let preview = message_preview(message)
        .filter(|preview| !preview.is_empty())
        .map(|preview| redact_provider_audit_text(&preview));
    let invocation_id = source
        .and_then(|source| source.invocation_id.clone())
        .or_else(|| match message {
            Message::ToolResult { invocation_id, .. } => Some(invocation_id.clone()),
            _ => None,
        });
    Ok(ContextMessageManifest {
        ordinal,
        role,
        content_kinds,
        byte_count: bytes.len(),
        sha256: sha256_label(&bytes),
        preview,
        projection: if message.is_compaction_summary() {
            "compaction_summary".to_owned()
        } else {
            "provider_visible".to_owned()
        },
        source_kind: source
            .map_or("generated", |source| source.source_kind.as_str())
            .to_owned(),
        source_event_ids: source
            .map(|source| source.event_ids.clone())
            .unwrap_or_default(),
        invocation_id,
    })
}

fn message_preview(message: &Message) -> Option<String> {
    const MAX_PREVIEW_CHARS: usize = 240;
    let text = match message {
        Message::User { content, .. } => match content {
            super::messages::UserMessageContent::Text(text) => text.clone(),
            super::messages::UserMessageContent::Blocks(blocks) => blocks
                .iter()
                .filter_map(super::content::UserContent::as_text)
                .collect::<Vec<_>>()
                .join("\n"),
        },
        Message::Assistant { content, .. } => content
            .iter()
            .filter_map(super::content::AssistantContent::as_text)
            .collect::<Vec<_>>()
            .join("\n"),
        Message::ToolResult { content, .. } => match content {
            super::messages::ToolResultMessageContent::Text(text) => text.clone(),
            super::messages::ToolResultMessageContent::Blocks(blocks) => blocks
                .iter()
                .filter_map(|block| match block {
                    super::content::ToolResultContent::Text { text } => Some(text.as_str()),
                    super::content::ToolResultContent::Image { .. } => None,
                })
                .collect::<Vec<_>>()
                .join("\n"),
        },
    };
    Some(text.chars().take(MAX_PREVIEW_CHARS).collect())
}

fn sha256_label(bytes: &[u8]) -> String {
    format!("sha256:{}", hex::encode(Sha256::digest(bytes)))
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

    /// Return a redacted, bounded request audit projection.
    ///
    /// Provider audit payloads must never be the first place a raw secret is
    /// durably persisted. Providers should avoid including headers/auth fields
    /// in request bodies, and this method is the boundary backstop before the
    /// event store writes `model.provider_request`.
    pub fn redacted_and_bounded(self) -> Result<Self, ProviderAuditPayloadError> {
        let original_bytes = serde_json::to_vec(&self)
            .map_err(|error| ProviderAuditPayloadError::Serialize(error.to_string()))?;
        let original_size = original_bytes.len();
        let Self { kind, body } = self;
        let mut projected_bulk_value = false;
        let body = if original_size > MAX_PROVIDER_AUDIT_PAYLOAD_BYTES {
            project_bulk_strings(body, &mut projected_bulk_value)
        } else {
            body
        };
        let kind = if projected_bulk_value {
            projected_payload_kind(kind)
        } else {
            kind
        };
        let mut payload = Self {
            kind,
            body: redact_sensitive_json(body),
        };
        let mut actual_bytes = serde_json::to_vec(&payload)
            .map_err(|error| ProviderAuditPayloadError::Serialize(error.to_string()))?
            .len();
        if actual_bytes > MAX_PROVIDER_AUDIT_PAYLOAD_BYTES {
            payload.kind = projected_payload_kind(payload.kind);
            payload.body = request_envelope_projection(&original_bytes);
            actual_bytes = serde_json::to_vec(&payload)
                .map_err(|error| ProviderAuditPayloadError::Serialize(error.to_string()))?
                .len();
        }
        if actual_bytes > MAX_PROVIDER_AUDIT_PAYLOAD_BYTES {
            return Err(ProviderAuditPayloadError::TooLarge {
                actual_bytes,
                max_bytes: MAX_PROVIDER_AUDIT_PAYLOAD_BYTES,
            });
        }
        Ok(payload)
    }
}

fn projected_payload_kind(kind: ProviderAuditPayloadKind) -> ProviderAuditPayloadKind {
    match kind {
        ProviderAuditPayloadKind::ExactProviderEnvelope
        | ProviderAuditPayloadKind::ProviderEnvelopeProjection => {
            ProviderAuditPayloadKind::ProviderEnvelopeProjection
        }
        ProviderAuditPayloadKind::ProviderIndependentSnapshot
        | ProviderAuditPayloadKind::ProviderIndependentProjection => {
            ProviderAuditPayloadKind::ProviderIndependentProjection
        }
    }
}

fn project_bulk_strings(value: Value, projected: &mut bool) -> Value {
    match value {
        Value::String(text) if text.len() > MAX_PROVIDER_AUDIT_INLINE_STRING_BYTES => {
            *projected = true;
            bulk_string_projection(&text)
        }
        Value::Array(values) => Value::Array(
            values
                .into_iter()
                .map(|value| project_bulk_strings(value, projected))
                .collect(),
        ),
        Value::Object(map) => Value::Object(
            map.into_iter()
                .map(|(key, value)| (key, project_bulk_strings(value, projected)))
                .collect(),
        ),
        other => other,
    }
}

fn bulk_string_projection(text: &str) -> Value {
    let (encoding, mime_type, payload_bytes) = data_uri_metadata(text)
        .map_or(("utf8", None, text.len()), |(mime_type, payload)| {
            ("base64", Some(mime_type), payload.len())
        });
    let digest = Sha256::digest(text.as_bytes());
    let mut projection = serde_json::json!({
        "$tronAuditProjection": "bulk_string.v1",
        "encoding": encoding,
        "encodedBytes": text.len(),
        "payloadBytes": payload_bytes,
        "sha256": format!("sha256:{}", hex::encode(digest)),
    });
    if let Some(mime_type) = mime_type {
        projection["mimeType"] = Value::String(mime_type.to_owned());
    }
    projection
}

fn request_envelope_projection(original_bytes: &[u8]) -> Value {
    let digest = Sha256::digest(original_bytes);
    serde_json::json!({
        "$tronAuditProjection": "request_envelope.v1",
        "encodedBytes": original_bytes.len(),
        "sha256": format!("sha256:{}", hex::encode(digest)),
    })
}

fn data_uri_metadata(text: &str) -> Option<(&str, &str)> {
    let data = text.strip_prefix("data:")?;
    let (mime_type, payload) = data.split_once(";base64,")?;
    (!mime_type.is_empty() && !payload.is_empty()).then_some((mime_type, payload))
}

/// Recursively redact sensitive strings inside a JSON value.
#[must_use]
pub fn redact_sensitive_json(value: Value) -> Value {
    redact_sensitive_json_for_key(None, value)
}

fn redact_sensitive_json_for_key(key: Option<&str>, value: Value) -> Value {
    match value {
        Value::String(text) => {
            if key.is_some_and(is_raw_reasoning_string_key) {
                return Value::String("[omitted:provider-reasoning-payload]".to_owned());
            }
            Value::String(redact_provider_audit_text(&text))
        }
        Value::Array(values) => {
            if key.is_some_and(is_raw_reasoning_container_key) {
                return Value::String("[omitted:provider-reasoning-payload]".to_owned());
            }
            Value::Array(
                values
                    .into_iter()
                    .map(|value| redact_sensitive_json_for_key(None, value))
                    .collect(),
            )
        }
        Value::Object(map) => {
            if key.is_some_and(is_raw_reasoning_container_key) {
                return Value::String("[omitted:provider-reasoning-payload]".to_owned());
            }
            Value::Object(
                map.into_iter()
                    .map(|(key, value)| {
                        let redacted = redact_sensitive_json_for_key(Some(&key), value);
                        (key, redacted)
                    })
                    .collect(),
            )
        }
        other => other,
    }
}

fn redact_provider_audit_text(text: &str) -> String {
    static ABSOLUTE_PATHS: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"(^|[\s"'=:,\[])(/(?:Users|home|private|tmp|var|Volumes)/[^\s"',}\]]+)"#)
            .unwrap()
    });
    static UNSAFE_RELATIVE_PATHS: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r#"(^|[\s"'=:,\[])(\.\.(?:/|\\)[^\s"',}\]]*)"#).unwrap());

    let redacted = redact_sensitive_content(text);
    let redacted = ABSOLUTE_PATHS
        .replace_all(&redacted, "${1}[redacted-path]")
        .to_string();
    UNSAFE_RELATIVE_PATHS
        .replace_all(&redacted, "${1}[redacted-path]")
        .to_string()
}

fn is_raw_reasoning_string_key(key: &str) -> bool {
    matches!(
        canonical_key(key).as_str(),
        "thinking"
            | "thinkingtext"
            | "thinkingcontent"
            | "reasoningcontent"
            | "rawreasoning"
            | "rawreasoningtext"
            | "rawreasoningpayload"
            | "chainofthought"
            | "thoughts"
    )
}

fn is_raw_reasoning_container_key(key: &str) -> bool {
    matches!(
        canonical_key(key).as_str(),
        "thinkingcontent"
            | "reasoningcontent"
            | "rawreasoning"
            | "rawreasoningtext"
            | "rawreasoningpayload"
            | "chainofthought"
            | "thoughts"
    )
}

fn canonical_key(key: &str) -> String {
    key.chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
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
    /// Provider-loop turn ordinal.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn: Option<u32>,
    /// Engine trace inherited by this model request.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub trace_id: Option<String>,
    /// Parent engine invocation when this request belongs to durable work.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_invocation_id: Option<String>,
    /// Worker that owns this agent session, when this is a nested worker run.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin_worker_id: Option<String>,
    /// Durable worker invocation that owns this nested agent request.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin_worker_invocation_id: Option<String>,
    /// `main_chat` or `agent_worker`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request_classification: Option<String>,
    /// Canonical reasoning level, when requested.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_level: Option<String>,
    /// Number of provider-visible messages in the request context.
    pub message_count: usize,
    /// Number of provider-visible tools in the request context.
    pub tool_count: usize,
    /// Provider stream options produced by the model responder boundary.
    pub stream_options: Value,
    /// Provider request envelope, bounded envelope projection, or
    /// provider-independent request-input snapshot.
    pub provider_request: ProviderAuditPayload,
    /// Provider-neutral context ledger corresponding to this exact request.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_manifest: Option<ContextManifest>,
    /// Provider-owned instruction/prefix evidence visible in the exact
    /// provider envelope but not part of the neutral Context.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub provider_additions: Vec<SystemContextContribution>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn provider_audit_payload_redacts_nested_secrets() {
        let payload = ProviderAuditPayload::exact_provider_envelope(json!({
            "headers": {
                "authorization": "Bearer abcdefghijklmnopqrstuvwxyz0123456789"
            },
            "body": [
                {"apiKey": "sk-proj-abcdefghijklmnopqrstuvwxyz"},
                "access_token=access-token-1234567890"
            ]
        }));

        let redacted = payload.redacted_and_bounded().unwrap();
        let body = redacted.body.to_string();

        assert!(!body.contains("abcdefghijklmnopqrstuvwxyz0123456789"));
        assert!(!body.contains("sk-proj-abcdefghijklmnopqrstuvwxyz"));
        assert!(!body.contains("access-token-1234567890"));
        assert!(body.contains("Bearer ****"));
        assert!(body.contains("sk-proj-****"));
        assert!(body.contains("access_token=****"));
    }

    #[test]
    fn provider_audit_payload_omits_raw_reasoning_and_redacts_paths() {
        let payload = ProviderAuditPayload::provider_independent_snapshot(json!({
            "messages": [{
                "type": "thinking",
                "thinking": "raw hidden reasoning from provider",
                "debugPath": "/tmp/tron-provider/raw-reasoning.log"
            }],
            "providerDebug": {
                "reasoning_content": {
                    "text": "provider native chain of thought"
                },
                "chainOfThought": ["first hidden step", "second hidden step"],
                "unsafe": "../escape/provider.json"
            },
            "headers": {
                "authorization": "Bearer abcdefghijklmnopqrstuvwxyz0123456789"
            }
        }));

        let redacted = payload.redacted_and_bounded().unwrap();
        let body = redacted.body.to_string();

        for forbidden in [
            "raw hidden reasoning",
            "provider native chain",
            "first hidden step",
            "/tmp/tron-provider",
            "../escape",
            "abcdefghijklmnopqrstuvwxyz0123456789",
        ] {
            assert!(
                !body.contains(forbidden),
                "provider audit leaked {forbidden}: {body}"
            );
        }
        assert!(body.contains("[omitted:provider-reasoning-payload]"));
        assert!(body.contains("[redacted-path]"));
        assert!(body.contains("Bearer ****"));
    }

    #[test]
    fn provider_audit_payload_projects_bulk_inline_media() {
        let image_data = "a".repeat(MAX_PROVIDER_AUDIT_PAYLOAD_BYTES + 1);
        let payload = ProviderAuditPayload::exact_provider_envelope(json!({
            "input": [{
                "role": "user",
                "content": [{
                    "type": "input_image",
                    "image_url": format!("data:image/jpeg;base64,{image_data}")
                }]
            }]
        }));

        let bounded = payload.redacted_and_bounded().unwrap();
        let projection = &bounded.body["input"][0]["content"][0]["image_url"];

        assert_eq!(
            bounded.kind,
            ProviderAuditPayloadKind::ProviderEnvelopeProjection
        );
        assert_eq!(projection["$tronAuditProjection"], "bulk_string.v1");
        assert_eq!(projection["encoding"], "base64");
        assert_eq!(projection["mimeType"], "image/jpeg");
        assert_eq!(
            projection["payloadBytes"],
            serde_json::json!(image_data.len())
        );
        assert!(
            projection["sha256"]
                .as_str()
                .is_some_and(|value| value.starts_with("sha256:"))
        );
        assert!(serde_json::to_vec(&bounded).unwrap().len() < MAX_PROVIDER_AUDIT_PAYLOAD_BYTES);
        assert!(!bounded.body.to_string().contains(&image_data));
    }

    #[test]
    fn provider_audit_payload_keeps_fitting_long_text_exact() {
        let payload = ProviderAuditPayload::exact_provider_envelope(json!({
            "input": "x".repeat(MAX_PROVIDER_AUDIT_INLINE_STRING_BYTES + 1)
        }));

        let bounded = payload.redacted_and_bounded().unwrap();

        assert_eq!(
            bounded.kind,
            ProviderAuditPayloadKind::ExactProviderEnvelope
        );
        assert_eq!(
            bounded.body["input"].as_str().map(str::len),
            Some(MAX_PROVIDER_AUDIT_INLINE_STRING_BYTES + 1)
        );
    }

    #[test]
    fn provider_audit_payload_summarizes_oversized_structure_after_bulk_projection() {
        let values = (0..70_000)
            .map(|index| format!("small-audit-value-{index:05}"))
            .collect::<Vec<_>>();
        let payload = ProviderAuditPayload::provider_independent_snapshot(json!({
            "values": values
        }));

        let bounded = payload.redacted_and_bounded().unwrap();

        assert_eq!(
            bounded.kind,
            ProviderAuditPayloadKind::ProviderIndependentProjection
        );
        assert_eq!(bounded.body["$tronAuditProjection"], "request_envelope.v1");
        assert!(bounded.body["encodedBytes"].as_u64().is_some_and(|size| {
            usize::try_from(size).is_ok_and(|size| size > MAX_PROVIDER_AUDIT_PAYLOAD_BYTES)
        }));
        assert!(serde_json::to_vec(&bounded).unwrap().len() < MAX_PROVIDER_AUDIT_PAYLOAD_BYTES);
    }

    #[test]
    fn context_manifest_matches_context_and_retains_message_provenance() {
        let context = Context {
            system_prompt: Some("base\n\nremember this".to_owned()),
            messages: vec![Message::user("hello")].into(),
            tools: Some(Vec::new()),
            working_directory: Some("/workspace/project".to_owned()),
            server_origin: Some("localhost:9847".to_owned()),
        };
        let contributions = vec![
            SystemContextContribution::new(
                "base_instructions",
                "Agent instructions",
                "base",
                json!({"owner":"runtime"}),
            ),
            SystemContextContribution::new(
                "continuity_context",
                "Continuity context",
                "remember this",
                json!({"workerId":"continuity-curator"}),
            ),
        ];
        let source = MessageAuditSource::events(vec!["event-user-1".to_owned()]);

        let manifest = ContextManifest::build(
            &context,
            contributions,
            json!({"fixedToolCount":0}),
            Vec::new(),
            &[source],
        )
        .expect("matching manifest");

        assert_eq!(manifest.messages[0].source_event_ids, ["event-user-1"]);
        assert_eq!(manifest.messages[0].source_kind, "durable_event");
        assert!(manifest.context_sha256.starts_with("sha256:"));
        assert_eq!(manifest.system_contributions.len(), 2);
    }

    #[test]
    fn context_manifest_rejects_unrecorded_system_mutation() {
        let context = Context {
            system_prompt: Some("base\n\nunrecorded".to_owned()),
            ..Context::default()
        };

        let error = ContextManifest::build(
            &context,
            vec![SystemContextContribution::new(
                "base_instructions",
                "Agent instructions",
                "base",
                Value::Null,
            )],
            Value::Null,
            Vec::new(),
            &[],
        )
        .expect_err("unrecorded system text must fail closed");

        assert!(error.contains("does not match"));
    }
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
        tool_count: usize,
        stream_options: Value,
        provider_request: ProviderAuditPayload,
    ) -> Self {
        let provider_name = provider_name.into();
        let model = model.into();
        let session_id = session_id.into();
        Self {
            format: MODEL_PROVIDER_REQUEST_AUDIT_FORMAT.to_owned(),
            provider_type,
            provider_name,
            model,
            context_window,
            session_id,
            turn: None,
            trace_id: None,
            parent_invocation_id: None,
            origin_worker_id: None,
            origin_worker_invocation_id: None,
            request_classification: None,
            reasoning_level,
            message_count,
            tool_count,
            stream_options,
            provider_request,
            context_manifest: None,
            provider_additions: Vec::new(),
        }
    }

    /// Attach request-specific causal and context evidence after provider
    /// adaptation has produced the final redacted envelope.
    #[allow(clippy::too_many_arguments)]
    pub fn with_context_manifest(
        mut self,
        turn: u32,
        trace_id: Option<String>,
        parent_invocation_id: Option<String>,
        origin_worker_id: Option<String>,
        origin_worker_invocation_id: Option<String>,
        context_manifest: ContextManifest,
    ) -> Self {
        self.turn = Some(turn);
        self.trace_id = trace_id;
        self.parent_invocation_id = parent_invocation_id;
        self.request_classification = Some(
            if origin_worker_id.is_some() {
                "agent_worker"
            } else {
                "main_chat"
            }
            .to_owned(),
        );
        self.origin_worker_id = origin_worker_id;
        self.origin_worker_invocation_id = origin_worker_invocation_id;
        self.context_manifest = Some(context_manifest);
        self
    }
}
