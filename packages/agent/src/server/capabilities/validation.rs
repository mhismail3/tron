//! Input validation helpers for capability payloads and transport envelopes.

use super::errors::CapabilityError;

/// Maximum prompt length (1 MB).
pub const MAX_PROMPT_LENGTH: usize = 1_048_576;

/// Maximum general string parameter length (8 KB).
#[cfg(test)]
pub const MAX_PARAM_LENGTH: usize = 8_192;

/// Maximum JSON nesting depth for incoming transport payloads.
///
/// **Why this exists (defense-in-depth rationale):**
/// `serde_json` already enforces a 128-deep recursion limit during parse,
/// so a client cannot land a 10000-level-deep structure in our
/// [`serde_json::Value`] at all — parse would fail first with an opaque
/// parser error. We re-apply the cap at the RPC boundary so that:
///
/// 1. **Stable error surface.** Depth-rejected requests produce a
///    structured [`CapabilityError::InvalidParams`] with a clear message, not a
///    raw serde parse error that happens to mention "recursion limit".
///    Clients can render this as a user-actionable error.
/// 2. **Protect post-parse traversal.** Several handlers walk the JSON
///    tree recursively (argument coercion, default filling). Running the
///    cap here means those walks can trust the bound: stack frame ceiling
///    is `MAX_JSON_DEPTH * constant` regardless of handler recursion
///    pattern.
/// 3. **Invariant ratchet.** If a future `serde_json` version changes the
///    default recursion limit, or we enable a custom deserializer with a
///    higher ceiling, the explicit cap still holds.
///
/// 128 matches `serde_json`'s current default so the two caps fire at the
/// same threshold — see [`json_depth_matches_serde_default`] for the
/// regression guard.
///
/// [`json_depth_matches_serde_default`]: tests::json_depth_matches_serde_default
pub const MAX_JSON_DEPTH: usize = 128;

/// Maximum decoded size per attachment (50 MB — covers the largest provider limit).
pub const MAX_ATTACHMENT_BYTES: usize = 50 * 1024 * 1024;

/// Validate that a string parameter does not exceed `max_len` bytes.
pub fn validate_string_param(
    value: &str,
    name: &str,
    max_len: usize,
) -> Result<(), CapabilityError> {
    if value.len() > max_len {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "Parameter '{name}' exceeds maximum length ({} > {max_len})",
                value.len()
            ),
        });
    }
    Ok(())
}

/// Validate that parsed JSON does not exceed the maximum nesting depth.
///
/// See [`MAX_JSON_DEPTH`] for why this exists on top of `serde_json`'s
/// built-in recursion limit. The short version: we translate the parser's
/// opaque recursion failure into a structured
/// [`CapabilityError::InvalidParams`] so the client can render an actionable
/// message, and we guarantee a bounded stack for any handler that walks
/// the parsed tree.
pub fn validate_json_depth(
    value: &serde_json::Value,
    max_depth: usize,
) -> Result<(), CapabilityError> {
    fn measure_depth(v: &serde_json::Value, current: usize, max: usize) -> Result<(), ()> {
        if current > max {
            return Err(());
        }
        match v {
            serde_json::Value::Object(map) => {
                for val in map.values() {
                    measure_depth(val, current + 1, max)?;
                }
            }
            serde_json::Value::Array(arr) => {
                for val in arr {
                    measure_depth(val, current + 1, max)?;
                }
            }
            _ => {}
        }
        Ok(())
    }

    measure_depth(value, 0, max_depth).map_err(|()| CapabilityError::InvalidParams {
        message: format!("JSON nesting depth exceeds maximum of {max_depth}"),
    })
}

/// Validate that a base64-encoded attachment does not exceed [`MAX_ATTACHMENT_BYTES`] decoded.
pub fn validate_attachment_size(base64_data: &str) -> Result<(), CapabilityError> {
    // base64 encodes 3 bytes into 4 chars; approximate decoded size.
    let decoded_size = base64_data.len() * 3 / 4;
    if decoded_size > MAX_ATTACHMENT_BYTES {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "Attachment exceeds maximum size of {}MB (got ~{}MB)",
                MAX_ATTACHMENT_BYTES / (1024 * 1024),
                decoded_size / (1024 * 1024),
            ),
        });
    }
    Ok(())
}

/// Sanitize an error message for client consumption.
///
/// Preserves user-facing messages (invalid params, not found) but strips
/// internal details (file paths, stack traces) from internal errors.
pub fn sanitize_error_message(err: &CapabilityError) -> String {
    match err {
        CapabilityError::InvalidParams { message }
        | CapabilityError::NotFound { message, .. }
        | CapabilityError::NotAvailable { message }
        | CapabilityError::Custom { message, .. } => message.clone(),
        CapabilityError::Internal { .. } => "Internal error".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_normal_param_succeeds() {
        assert!(validate_string_param("hello", "name", MAX_PARAM_LENGTH).is_ok());
    }

    #[test]
    fn validate_at_limit_succeeds() {
        let s = "x".repeat(MAX_PARAM_LENGTH);
        assert!(validate_string_param(&s, "param", MAX_PARAM_LENGTH).is_ok());
    }

    #[test]
    fn validate_oversized_param_fails() {
        let s = "x".repeat(MAX_PARAM_LENGTH + 1);
        let result = validate_string_param(&s, "myParam", MAX_PARAM_LENGTH);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
        assert!(err.to_string().contains("myParam"));
    }

    #[test]
    fn validate_normal_prompt_succeeds() {
        let prompt = "Write me a poem about Rust.";
        assert!(validate_string_param(prompt, "prompt", MAX_PROMPT_LENGTH).is_ok());
    }

    #[test]
    fn reject_oversized_prompt() {
        let prompt = "x".repeat(MAX_PROMPT_LENGTH + 1);
        let result = validate_string_param(&prompt, "prompt", MAX_PROMPT_LENGTH);
        assert!(result.is_err());
    }

    #[test]
    fn sanitize_internal_error_strips_details() {
        let err = CapabilityError::Internal {
            message: "failed at /Users/user/.tron/internal/database/events.db: disk full".into(),
        };
        let sanitized = sanitize_error_message(&err);
        assert_eq!(sanitized, "Internal error");
        assert!(!sanitized.contains("/Users"));
    }

    #[test]
    fn sanitize_invalid_params_preserves_message() {
        let err = CapabilityError::InvalidParams {
            message: "Missing required parameter 'sessionId'".into(),
        };
        let sanitized = sanitize_error_message(&err);
        assert!(sanitized.contains("sessionId"));
    }

    #[test]
    fn sanitize_not_found_preserves_message() {
        let err = CapabilityError::NotFound {
            code: "SESSION_NOT_FOUND".into(),
            message: "Session 'abc' not found".into(),
        };
        let sanitized = sanitize_error_message(&err);
        assert!(sanitized.contains("abc"));
    }

    // ── JSON depth validation tests ─────────────────────────────

    fn nested_object(depth: usize) -> serde_json::Value {
        let mut v = serde_json::json!({"leaf": true});
        for _ in 0..depth {
            v = serde_json::json!({"nested": v});
        }
        v
    }

    fn nested_array(depth: usize) -> serde_json::Value {
        let mut v = serde_json::json!(42);
        for _ in 0..depth {
            v = serde_json::json!([v]);
        }
        v
    }

    #[test]
    fn depth_1_passes() {
        let v = serde_json::json!({"key": "value"});
        assert!(validate_json_depth(&v, MAX_JSON_DEPTH).is_ok());
    }

    #[test]
    fn depth_10_passes() {
        assert!(validate_json_depth(&nested_object(10), MAX_JSON_DEPTH).is_ok());
    }

    #[test]
    fn depth_64_passes() {
        assert!(validate_json_depth(&nested_object(64), MAX_JSON_DEPTH).is_ok());
    }

    #[test]
    fn depth_128_rejected() {
        let deep = nested_object(130);
        assert!(validate_json_depth(&deep, MAX_JSON_DEPTH).is_err());
    }

    #[test]
    fn depth_200_rejected() {
        let deep = nested_object(200);
        let result = validate_json_depth(&deep, MAX_JSON_DEPTH);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("128"));
    }

    #[test]
    fn deep_arrays_caught() {
        let deep = nested_array(150);
        assert!(validate_json_depth(&deep, MAX_JSON_DEPTH).is_err());
    }

    #[test]
    fn flat_many_keys_passes() {
        let mut map = serde_json::Map::new();
        for i in 0..1000 {
            map.insert(format!("key_{i}"), serde_json::json!(i));
        }
        let v = serde_json::Value::Object(map);
        assert!(validate_json_depth(&v, MAX_JSON_DEPTH).is_ok());
    }

    #[test]
    fn null_passes() {
        assert!(validate_json_depth(&serde_json::Value::Null, MAX_JSON_DEPTH).is_ok());
    }

    #[test]
    fn primitives_pass() {
        assert!(validate_json_depth(&serde_json::json!(42), MAX_JSON_DEPTH).is_ok());
        assert!(validate_json_depth(&serde_json::json!("hello"), MAX_JSON_DEPTH).is_ok());
        assert!(validate_json_depth(&serde_json::json!(true), MAX_JSON_DEPTH).is_ok());
    }

    /// Regression guard for L2: the explicit RPC depth cap must fire at
    /// the same threshold as `serde_json`'s parser recursion limit so
    /// clients always see the same error surface regardless of which
    /// layer rejects first. If `serde_json` ever changes its default,
    /// either update [`MAX_JSON_DEPTH`] to match or accept the new
    /// asymmetry with an updated comment.
    #[test]
    fn json_depth_matches_serde_default() {
        // Build a JSON string with depth MAX_JSON_DEPTH + 1. serde_json
        // should refuse to parse it (its default recursion limit trips
        // before our cap can). If parsing ever starts succeeding here, a
        // newer serde_json raised its limit and this test catches the
        // silent relaxation.
        let depth = MAX_JSON_DEPTH + 1;
        let mut s = String::with_capacity(depth * 6 + 4);
        for _ in 0..depth {
            s.push_str(r#"{"a":"#);
        }
        s.push_str("null");
        for _ in 0..depth {
            s.push('}');
        }
        let parsed: Result<serde_json::Value, _> = serde_json::from_str(&s);
        assert!(
            parsed.is_err(),
            "serde_json parsed depth > MAX_JSON_DEPTH ({depth}) — its default recursion limit \
             raised beyond {MAX_JSON_DEPTH}. Reconcile by bumping MAX_JSON_DEPTH or document \
             the new asymmetry."
        );
    }

    // ── Attachment size validation tests ────────────────────────────

    #[test]
    fn attachment_under_limit_passes() {
        // ~1 MB of base64 ≈ 750 KB decoded
        let data = "A".repeat(1_000_000);
        assert!(validate_attachment_size(&data).is_ok());
    }

    #[test]
    fn attachment_empty_passes() {
        assert!(validate_attachment_size("").is_ok());
    }

    #[test]
    fn attachment_over_limit_fails() {
        // 70 MB of base64 ≈ 52.5 MB decoded → over 50 MB limit
        let data = "A".repeat(70 * 1024 * 1024);
        let result = validate_attachment_size(&data);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
        assert!(err.to_string().contains("50MB"));
    }

    #[test]
    fn attachment_at_limit_passes() {
        // Exactly 50 MB decoded ≈ 66.67 MB base64
        // Use slightly under to account for rounding
        let data = "A".repeat(66 * 1024 * 1024);
        assert!(validate_attachment_size(&data).is_ok());
    }
}
