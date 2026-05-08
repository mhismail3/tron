//! Parameter extraction helpers shared by transport and capability code.
//!
//! Each helper turns a `Option<&Value>` (the raw `params` payload from a
//! client request) into a typed value, returning `CapabilityError::InvalidParams`
//! for missing or wrong-typed required fields. Optional helpers return
//! `Option<T>` plus an explicit defaulted variant for `u64`.

use crate::server::capabilities::errors::CapabilityError;

/// Extract a required parameter from the params object.
pub(crate) fn require_param<'a>(
    params: Option<&'a serde_json::Value>,
    key: &str,
) -> Result<&'a serde_json::Value, CapabilityError> {
    params
        .and_then(|p| p.get(key))
        .ok_or_else(|| CapabilityError::InvalidParams {
            message: format!("Missing required parameter: {key}"),
        })
}

/// Extract a required string parameter.
pub(crate) fn require_string_param(
    params: Option<&serde_json::Value>,
    key: &str,
) -> Result<String, CapabilityError> {
    require_param(params, key)?
        .as_str()
        .map(ToOwned::to_owned)
        .ok_or_else(|| CapabilityError::InvalidParams {
            message: format!("Parameter '{key}' must be a string"),
        })
}

/// Extract an optional string parameter.
pub(crate) fn opt_string(params: Option<&serde_json::Value>, key: &str) -> Option<String> {
    params
        .and_then(|p| p.get(key))
        .and_then(|v| v.as_str())
        .map(ToOwned::to_owned)
}

/// Extract an optional u64 parameter, returning `default` if absent or wrong type.
pub(crate) fn opt_u64(params: Option<&serde_json::Value>, key: &str, default: u64) -> u64 {
    params
        .and_then(|p| p.get(key))
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(default)
}

/// Extract an optional bool parameter.
pub(crate) fn opt_bool(params: Option<&serde_json::Value>, key: &str) -> Option<bool> {
    params
        .and_then(|p| p.get(key))
        .and_then(serde_json::Value::as_bool)
}

/// Extract a required bool parameter. Missing or wrong-typed returns
/// `CapabilityError::InvalidParams` — use this when the client is contractually
/// required to send the flag and there is no sane server-side default
/// (see I7: `stageAll` on `worktree.commit`).
pub(crate) fn require_bool(
    params: Option<&serde_json::Value>,
    key: &str,
) -> Result<bool, CapabilityError> {
    require_param(params, key)?
        .as_bool()
        .ok_or_else(|| CapabilityError::InvalidParams {
            message: format!("Parameter '{key}' must be a boolean"),
        })
}

/// Extract an optional array parameter.
pub(crate) fn opt_array<'a>(
    params: Option<&'a serde_json::Value>,
    key: &str,
) -> Option<&'a Vec<serde_json::Value>> {
    params.and_then(|p| p.get(key)).and_then(|v| v.as_array())
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── require_param ──

    #[test]
    fn require_param_present() {
        let params = Some(serde_json::json!({"name": "alice"}));
        let val = require_param(params.as_ref(), "name").unwrap();
        assert_eq!(val, "alice");
    }

    #[test]
    fn require_param_missing() {
        let params = Some(serde_json::json!({"other": 1}));
        let err = require_param(params.as_ref(), "name").unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[test]
    fn require_param_none_params() {
        let err = require_param(None, "name").unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    // ── require_string_param ──

    #[test]
    fn require_string_param_ok() {
        let params = Some(serde_json::json!({"id": "abc"}));
        let val = require_string_param(params.as_ref(), "id").unwrap();
        assert_eq!(val, "abc");
    }

    #[test]
    fn require_string_param_wrong_type() {
        let params = Some(serde_json::json!({"id": 42}));
        let err = require_string_param(params.as_ref(), "id").unwrap_err();
        assert!(err.to_string().contains("must be a string"));
    }

    // ── opt_string ──

    #[test]
    fn opt_string_present() {
        let p = Some(serde_json::json!({"name": "alice"}));
        assert_eq!(opt_string(p.as_ref(), "name"), Some("alice".to_owned()));
    }

    #[test]
    fn opt_string_missing_key() {
        let p = Some(serde_json::json!({"other": 1}));
        assert_eq!(opt_string(p.as_ref(), "name"), None);
    }

    #[test]
    fn opt_string_null_params() {
        assert_eq!(opt_string(None, "name"), None);
    }

    #[test]
    fn opt_string_wrong_type() {
        let p = Some(serde_json::json!({"name": 42}));
        assert_eq!(opt_string(p.as_ref(), "name"), None);
    }

    #[test]
    fn opt_string_null_value() {
        let p = Some(serde_json::json!({"name": null}));
        assert_eq!(opt_string(p.as_ref(), "name"), None);
    }

    // ── opt_u64 ──

    #[test]
    fn opt_u64_present() {
        let p = Some(serde_json::json!({"limit": 50}));
        assert_eq!(opt_u64(p.as_ref(), "limit", 20), 50);
    }

    #[test]
    fn opt_u64_missing_uses_default() {
        let p = Some(serde_json::json!({"other": 1}));
        assert_eq!(opt_u64(p.as_ref(), "limit", 20), 20);
    }

    #[test]
    fn opt_u64_null_params_uses_default() {
        assert_eq!(opt_u64(None, "limit", 20), 20);
    }

    #[test]
    fn opt_u64_wrong_type_uses_default() {
        let p = Some(serde_json::json!({"limit": "fifty"}));
        assert_eq!(opt_u64(p.as_ref(), "limit", 20), 20);
    }

    #[test]
    fn opt_u64_negative_uses_default() {
        let p = Some(serde_json::json!({"limit": -5}));
        assert_eq!(opt_u64(p.as_ref(), "limit", 20), 20);
    }

    // ── opt_bool ──

    #[test]
    fn opt_bool_true() {
        let p = Some(serde_json::json!({"enabled": true}));
        assert_eq!(opt_bool(p.as_ref(), "enabled"), Some(true));
    }

    #[test]
    fn opt_bool_false() {
        let p = Some(serde_json::json!({"enabled": false}));
        assert_eq!(opt_bool(p.as_ref(), "enabled"), Some(false));
    }

    #[test]
    fn opt_bool_missing() {
        let p = Some(serde_json::json!({"other": 1}));
        assert_eq!(opt_bool(p.as_ref(), "enabled"), None);
    }

    #[test]
    fn opt_bool_null_params() {
        assert_eq!(opt_bool(None, "enabled"), None);
    }

    #[test]
    fn opt_bool_wrong_type() {
        let p = Some(serde_json::json!({"enabled": "yes"}));
        assert_eq!(opt_bool(p.as_ref(), "enabled"), None);
    }

    // ── opt_array ──

    #[test]
    fn opt_array_present() {
        let p = Some(serde_json::json!({"tags": ["a", "b"]}));
        assert!(opt_array(p.as_ref(), "tags").is_some());
        assert_eq!(opt_array(p.as_ref(), "tags").unwrap().len(), 2);
    }

    #[test]
    fn opt_array_null_params() {
        assert!(opt_array(None, "tags").is_none());
    }

    #[test]
    fn opt_array_missing() {
        let p = Some(serde_json::json!({"other": 1}));
        assert!(opt_array(p.as_ref(), "tags").is_none());
    }

    #[test]
    fn opt_array_wrong_type() {
        let p = Some(serde_json::json!({"tags": "not-an-array"}));
        assert!(opt_array(p.as_ref(), "tags").is_none());
    }
}
