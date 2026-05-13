use serde_json::Value;

use crate::domains::session::event_store::types::{EventType, SessionEvent};

pub(crate) fn extract_role(event: &SessionEvent) -> Option<String> {
    match event.event_type {
        EventType::MessageUser => Some("user".to_string()),
        EventType::MessageAssistant => Some("assistant".to_string()),
        EventType::MessageSystem => Some("system".to_string()),
        EventType::CapabilityInvocationCompleted => Some("capability".to_string()),
        _ => None,
    }
}

pub(crate) fn extract_model_primitive_name(event: &SessionEvent) -> Option<String> {
    extract_str(&event.payload, "modelPrimitiveName")
}

pub(crate) fn extract_str(val: &Value, key: &str) -> Option<String> {
    val.get(key)?.as_str().map(String::from)
}

pub(crate) fn extract_i64(val: &Value, key: &str) -> Option<i64> {
    val.get(key)?.as_i64()
}

/// Extract a boolean or integer value as `SQLite` integer (0/1).
/// Handles both `hasThinking`: `true` and `hasThinking`: `1`.
pub(crate) fn extract_bool_as_int(val: &Value, key: &str) -> Option<i64> {
    let v = val.get(key)?;
    if let Some(b) = v.as_bool() {
        Some(i64::from(b))
    } else {
        v.as_i64()
    }
}

pub(crate) fn extract_tokens(
    payload: &Value,
) -> (Option<i64>, Option<i64>, Option<i64>, Option<i64>) {
    // Try payload.tokenUsage first (assistant messages)
    if let Some(tu) = payload.get("tokenUsage") {
        return (
            tu.get("inputTokens").and_then(Value::as_i64),
            tu.get("outputTokens").and_then(Value::as_i64),
            tu.get("cacheReadTokens").and_then(Value::as_i64),
            tu.get("cacheCreationTokens").and_then(Value::as_i64),
        );
    }
    // Try top-level (some event types put tokens directly)
    (
        extract_i64(payload, "inputTokens"),
        extract_i64(payload, "outputTokens"),
        extract_i64(payload, "cacheReadTokens"),
        extract_i64(payload, "cacheCreationTokens"),
    )
}
