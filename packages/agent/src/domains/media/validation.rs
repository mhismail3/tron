use serde_json::{Value, json};

use crate::engine::{EngineResourceScope, Invocation};
use crate::shared::server::errors::CapabilityError;

pub(super) const LIST_LIMIT_DEFAULT: usize = 50;
pub(super) const LIST_LIMIT_MAX: usize = 100;
pub(super) const MEDIA_ID_MAX_BYTES: usize = 160;
pub(super) const STORAGE_REF_MAX_BYTES: usize = 512;
pub(super) const CONTENT_HASH_MAX_BYTES: usize = 160;
pub(super) const TITLE_MAX_BYTES: usize = 160;
pub(super) const SUMMARY_MAX_BYTES: usize = 2_000;
pub(super) const TRANSCRIPT_MAX_BYTES: usize = 8_000;
pub(super) const REASON_MAX_BYTES: usize = 1_000;
pub(super) const IDEMPOTENCY_KEY_MAX_BYTES: usize = 256;
pub(super) const DEFAULT_RETENTION_DAYS: u64 = 90;
pub(super) const MAX_RETENTION_DAYS: u64 = 366;
pub(super) const MAX_AUDIO_BYTES: u64 = 150 * 1024 * 1024;
pub(super) const MAX_IMAGE_BYTES: u64 = 25 * 1024 * 1024;
pub(super) const MAX_DOCUMENT_BYTES: u64 = 50 * 1024 * 1024;

const ALLOWED_AUDIO_MIME_TYPES: &[&str] = &[
    "audio/wav",
    "audio/x-wav",
    "audio/mpeg",
    "audio/mp4",
    "audio/aac",
    "audio/x-m4a",
    "audio/webm",
];
const ALLOWED_IMAGE_MIME_TYPES: &[&str] = &["image/jpeg", "image/png", "image/heic", "image/webp"];
const ALLOWED_DOCUMENT_MIME_TYPES: &[&str] = &["application/pdf"];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum MediaKind {
    VoiceNote,
    Audio,
    Image,
    Document,
}

impl MediaKind {
    pub(super) fn as_str(self) -> &'static str {
        match self {
            Self::VoiceNote => "voice_note",
            Self::Audio => "audio",
            Self::Image => "image",
            Self::Document => "document",
        }
    }
}

pub(super) fn required_string(payload: &Value, field: &str) -> Result<String, CapabilityError> {
    optional_string(payload, field)?.ok_or_else(|| invalid(format!("{field} is required")))
}

pub(super) fn optional_string(
    payload: &Value,
    field: &str,
) -> Result<Option<String>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if !value.trim().is_empty() => Ok(Some(value.clone())),
        Some(Value::String(_)) => Err(invalid(format!("{field} must not be empty"))),
        Some(_) => Err(invalid(format!("{field} must be a string"))),
    }
}

pub(super) fn optional_bool(payload: &Value, field: &str) -> Result<Option<bool>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(value)) => Ok(Some(*value)),
        Some(_) => Err(invalid(format!("{field} must be a boolean"))),
    }
}

pub(super) fn optional_u64(payload: &Value, field: &str) -> Result<Option<u64>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(value)) => value
            .as_u64()
            .map(Some)
            .ok_or_else(|| invalid(format!("{field} must be a positive integer"))),
        Some(_) => Err(invalid(format!("{field} must be a positive integer"))),
    }
}

pub(super) fn optional_array(
    payload: &Value,
    field: &str,
) -> Result<Option<Vec<Value>>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Array(items)) => Ok(Some(items.clone())),
        Some(_) => Err(invalid(format!("{field} must be an array"))),
    }
}

pub(super) fn bounded_text(
    field: &str,
    value: &str,
    max_bytes: usize,
) -> Result<String, CapabilityError> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err(invalid(format!("{field} must not be empty")));
    }
    if trimmed.len() > max_bytes {
        return Err(invalid(format!("{field} exceeds {max_bytes} bytes")));
    }
    reject_secret_like(field, trimmed)?;
    Ok(trimmed.to_owned())
}

pub(super) fn bounded_token(
    field: &str,
    value: &str,
    max_bytes: usize,
) -> Result<String, CapabilityError> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed == "*"
        || trimmed.eq_ignore_ascii_case("all")
        || trimmed.eq_ignore_ascii_case("any")
        || trimmed.len() > max_bytes
        || !trimmed
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b':' | b'-' | b'_' | b'.'))
    {
        return Err(invalid(format!(
            "{field} must be a bounded non-wildcard token"
        )));
    }
    reject_secret_like(field, trimmed)?;
    Ok(trimmed.to_owned())
}

pub(super) fn parse_media_kind(value: Option<String>) -> Result<MediaKind, CapabilityError> {
    match value.as_deref().unwrap_or("voice_note") {
        "voice_note" => Ok(MediaKind::VoiceNote),
        "audio" => Ok(MediaKind::Audio),
        "image" => Ok(MediaKind::Image),
        "document" => Ok(MediaKind::Document),
        other => Err(invalid(format!("unsupported mediaKind {other}"))),
    }
}

pub(super) fn validate_mime_and_size(
    media_kind: MediaKind,
    mime_type: &str,
    size_bytes: u64,
) -> Result<(), CapabilityError> {
    if size_bytes == 0 {
        return Err(invalid("sizeBytes must be greater than zero"));
    }
    let allowed = match media_kind {
        MediaKind::VoiceNote | MediaKind::Audio => ALLOWED_AUDIO_MIME_TYPES,
        MediaKind::Image => ALLOWED_IMAGE_MIME_TYPES,
        MediaKind::Document => ALLOWED_DOCUMENT_MIME_TYPES,
    };
    if !allowed.contains(&mime_type) {
        return Err(invalid(format!(
            "mimeType {mime_type} is not allowed for {}",
            media_kind.as_str()
        )));
    }
    let limit = match media_kind {
        MediaKind::VoiceNote | MediaKind::Audio => MAX_AUDIO_BYTES,
        MediaKind::Image => MAX_IMAGE_BYTES,
        MediaKind::Document => MAX_DOCUMENT_BYTES,
    };
    if size_bytes > limit {
        return Err(invalid(format!(
            "sizeBytes {size_bytes} exceeds limit {limit} for {}",
            media_kind.as_str()
        )));
    }
    Ok(())
}

pub(super) fn reject_raw_media_fields(payload: &Value) -> Result<(), CapabilityError> {
    for field in [
        "audioBase64",
        "mediaBase64",
        "data",
        "bytes",
        "rawAudio",
        "rawBytes",
    ] {
        if payload.get(field).is_some() {
            return Err(invalid(format!(
                "{field} is not accepted; media resources store blob refs only"
            )));
        }
    }
    Ok(())
}

pub(super) fn idempotency_key(
    invocation: &Invocation,
    payload: &Value,
) -> Result<String, CapabilityError> {
    if let Some(key) = invocation.causal_context.idempotency_key.as_deref() {
        return bounded_token("idempotencyKey", key, IDEMPOTENCY_KEY_MAX_BYTES);
    }
    optional_string(payload, "idempotencyKey")?
        .map(|key| bounded_token("idempotencyKey", &key, IDEMPOTENCY_KEY_MAX_BYTES))
        .transpose()?
        .ok_or_else(|| invalid("media writes require an idempotencyKey"))
}

pub(super) fn resource_scope(
    invocation: &Invocation,
) -> Result<EngineResourceScope, CapabilityError> {
    invocation
        .causal_context
        .session_id
        .as_ref()
        .map(|session| EngineResourceScope::Session(session.clone()))
        .or_else(|| {
            invocation
                .causal_context
                .workspace_id
                .as_ref()
                .map(|workspace| EngineResourceScope::Workspace(workspace.clone()))
        })
        .ok_or_else(|| invalid("media operations require trusted session or workspace scope"))
}

pub(super) fn retention_policy(payload: &Value) -> Result<Value, CapabilityError> {
    let max_age_days = optional_u64(payload, "maxAgeDays")?
        .unwrap_or(DEFAULT_RETENTION_DAYS)
        .clamp(1, MAX_RETENTION_DAYS);
    Ok(json!({
        "privacyClass": "user_media_blob_ref",
        "policy": "bounded_metadata_blob_ref_only",
        "maxAgeDays": max_age_days,
        "archiveKeepsLifecycleEvidence": true
    }))
}

pub(super) fn validate_refs(label: &str, refs: &[Value]) -> Result<(), CapabilityError> {
    if refs.len() > 25 {
        return Err(invalid(format!("{label} may contain at most 25 items")));
    }
    for value in refs {
        let serialized = serde_json::to_string(value)
            .map_err(|error| invalid(format!("serialize {label}: {error}")))?;
        reject_secret_like(label, &serialized)?;
        let lowered = serialized.to_ascii_lowercase();
        if lowered.contains("audio_base64")
            || lowered.contains("audiobase64")
            || lowered.contains("rawaudio")
            || lowered.contains("rawbytes")
        {
            return Err(invalid(format!(
                "{label} must not contain raw media material"
            )));
        }
    }
    Ok(())
}

pub(super) fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}

fn reject_secret_like(field: &str, value: &str) -> Result<(), CapabilityError> {
    let lowered = value.to_ascii_lowercase();
    if lowered.contains("bearer ")
        || lowered.contains("api_key=")
        || lowered.contains("apikey=")
        || lowered.contains("password=")
        || lowered.contains("secret=")
        || lowered.contains("authorization:")
        || lowered.contains("api_key:")
        || lowered.contains("apikey:")
        || lowered.contains("password:")
        || lowered.contains("secret:")
        || lowered.contains("\"token\"")
    {
        return Err(invalid(format!(
            "{field} must not contain credential-like material"
        )));
    }
    Ok(())
}
