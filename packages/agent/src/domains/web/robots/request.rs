//! Request parsing for one-origin robots policy checks.

use serde_json::Value;

use crate::shared::server::errors::CapabilityError;

use super::invalid;

const MAX_URL_BYTES: usize = 2_048;
const MAX_USER_AGENT_BYTES: usize = 128;
const DEFAULT_USER_AGENT: &str = "tron";
const DEFAULT_TIMEOUT_MS: u64 = 10_000;
const MAX_TIMEOUT_MS: u64 = 30_000;
const DEFAULT_ROBOTS_BYTES: usize = 65_536;
const MAX_ROBOTS_BYTES: usize = 262_144;
const DEFAULT_OUTPUT_BYTES: usize = 8_192;
const MAX_OUTPUT_BYTES: usize = 20_000;
const DEFAULT_REDIRECTS: usize = 3;
const MAX_REDIRECTS: usize = 5;

pub(super) struct RobotsRequest {
    pub(super) url: String,
    pub(super) user_agent: String,
    pub(super) timeout_ms: u64,
    pub(super) max_robots_bytes: usize,
    pub(super) max_output_bytes: usize,
    pub(super) max_redirects: usize,
    pub(super) idempotency_key: String,
}

impl RobotsRequest {
    pub(super) fn parse(payload: &Value) -> Result<Self, CapabilityError> {
        let url = required_string(payload, "url")?;
        if url.len() > MAX_URL_BYTES {
            return Err(invalid(format!(
                "url exceeds {MAX_URL_BYTES} bytes and cannot be checked"
            )));
        }
        let user_agent =
            optional_string(payload, "userAgent")?.unwrap_or_else(|| DEFAULT_USER_AGENT.to_owned());
        validate_user_agent(&user_agent)?;
        Ok(Self {
            url,
            user_agent,
            timeout_ms: optional_u64(payload, "timeoutMs")?
                .unwrap_or(DEFAULT_TIMEOUT_MS)
                .clamp(1, MAX_TIMEOUT_MS),
            max_robots_bytes: optional_u64(payload, "maxRobotsBytes")?
                .map(|value| value as usize)
                .unwrap_or(DEFAULT_ROBOTS_BYTES)
                .clamp(1, MAX_ROBOTS_BYTES),
            max_output_bytes: optional_u64(payload, "maxOutputBytes")?
                .map(|value| value as usize)
                .unwrap_or(DEFAULT_OUTPUT_BYTES)
                .clamp(1, MAX_OUTPUT_BYTES),
            max_redirects: optional_u64(payload, "maxRedirects")?
                .map(|value| value as usize)
                .unwrap_or(DEFAULT_REDIRECTS)
                .clamp(0, MAX_REDIRECTS),
            idempotency_key: optional_string(payload, "idempotencyKey")?
                .unwrap_or_else(|| "<context>".to_owned()),
        })
    }
}

fn validate_user_agent(value: &str) -> Result<(), CapabilityError> {
    if value.trim().is_empty() || value.len() > MAX_USER_AGENT_BYTES {
        return Err(invalid(format!(
            "userAgent must be 1..={MAX_USER_AGENT_BYTES} bytes"
        )));
    }
    if !value.bytes().all(|byte| {
        byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'/' | b' ')
    }) {
        return Err(invalid("userAgent contains unsupported characters"));
    }
    Ok(())
}

fn required_string(payload: &Value, field: &str) -> Result<String, CapabilityError> {
    match payload.get(field) {
        Some(Value::String(value)) if !value.trim().is_empty() => Ok(value.trim().to_owned()),
        Some(Value::String(_)) => Err(invalid(format!("{field} must not be empty"))),
        Some(_) => Err(invalid(format!("{field} must be a string"))),
        None => Err(invalid(format!("{field} is required"))),
    }
}

fn optional_string(payload: &Value, field: &str) -> Result<Option<String>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if !value.trim().is_empty() => Ok(Some(value.trim().to_owned())),
        Some(Value::String(_)) => Err(invalid(format!("{field} must not be empty"))),
        Some(_) => Err(invalid(format!("{field} must be a string"))),
    }
}

fn optional_u64(payload: &Value, field: &str) -> Result<Option<u64>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(value)) => value
            .as_u64()
            .map(Some)
            .ok_or_else(|| invalid(format!("{field} must be a positive integer"))),
        Some(_) => Err(invalid(format!("{field} must be a positive integer"))),
    }
}
