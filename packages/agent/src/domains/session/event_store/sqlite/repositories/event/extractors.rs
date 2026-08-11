use serde_json::Value;

use crate::domains::session::event_store::types::{EventType, SessionEvent};

pub(crate) fn extract_role(event: &SessionEvent) -> Option<String> {
    match event.event_type {
        EventType::MessageUser => Some("user".to_string()),
        EventType::MessageAgent => Some("agent".to_string()),
        EventType::MessageAssistant => Some("assistant".to_string()),
        EventType::ToolInvocationCompleted => Some("tool".to_string()),
        _ => None,
    }
}

pub(crate) fn extract_tool_name(event: &SessionEvent) -> Option<String> {
    extract_str(&event.payload, "toolName")
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
    // Prefer the immutable provider-aware token record. Session counters store
    // mutually exclusive base-input and cache buckets so aggregate cache
    // percentages remain meaningful across provider switches.
    if let Some(source) = payload
        .get("tokenRecord")
        .and_then(|record| record.get("source"))
    {
        let raw_input = source.get("rawInputTokens").and_then(Value::as_i64);
        let output = source.get("rawOutputTokens").and_then(Value::as_i64);
        let provider_cache_read = source.get("rawCacheReadTokens").and_then(Value::as_i64);
        let provider_cached_input = source.get("rawCachedInputTokens").and_then(Value::as_i64);
        let cache_read = match (provider_cache_read, provider_cached_input) {
            (Some(read), Some(cached)) => Some(read.max(cached)),
            (read, cached) => read.or(cached),
        };
        let cache_create = source.get("rawCacheCreationTokens").and_then(Value::as_i64);
        let provider = source.get("provider").and_then(Value::as_str);
        let base_input = raw_input.map(|input| {
            if matches!(provider, Some("anthropic" | "minimax")) {
                input
            } else {
                input.saturating_sub(cache_read.unwrap_or(0))
            }
        });
        return (base_input, output, cache_read, cache_create);
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn token_record_normalizes_direct_provider_cache_into_exclusive_buckets() {
        let payload = json!({
            "tokenUsage": {
                "inputTokens": 1_000,
                "outputTokens": 50,
                "cacheReadTokens": 600
            },
            "tokenRecord": {
                "source": {
                    "provider": "openai",
                    "rawInputTokens": 1_000,
                    "rawOutputTokens": 50,
                    "rawCacheReadTokens": 600,
                    "rawCachedInputTokens": 0,
                    "rawCacheCreationTokens": 0
                }
            }
        });
        assert_eq!(
            extract_tokens(&payload),
            (Some(400), Some(50), Some(600), Some(0))
        );
    }

    #[test]
    fn token_record_keeps_anthropic_input_and_cache_buckets_exclusive() {
        let payload = json!({
            "tokenRecord": {
                "source": {
                    "provider": "anthropic",
                    "rawInputTokens": 400,
                    "rawOutputTokens": 50,
                    "rawCacheReadTokens": 600,
                    "rawCachedInputTokens": 600,
                    "rawCacheCreationTokens": 100
                }
            }
        });
        assert_eq!(
            extract_tokens(&payload),
            (Some(400), Some(50), Some(600), Some(100))
        );
    }
}
