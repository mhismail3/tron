//! Settings loading with deep merge and environment variable overrides.
//!
//! Loading flow:
//! 1. Start with compiled [`TronSettings::default()`]
//! 2. If `~/.tron/settings.json` exists, deep-merge user values over defaults
//! 3. Apply environment variable overrides (highest priority)
//!
//! Deep merge rules:
//! - Objects are merged recursively (source overrides target per-key)
//! - Arrays and primitives are replaced entirely by source
//! - Null values in source are skipped (preserving target)

use std::path::{Path, PathBuf};

use serde_json::Value;
use tracing::debug;

use crate::errors::Result;
use crate::types::TronSettings;

/// Resolve the path to the settings file (`~/.tron/settings.json`).
pub fn settings_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home).join(".tron").join("settings.json")
}

/// Load settings from the default path with env var overrides.
pub fn load_settings() -> Result<TronSettings> {
    load_settings_from_path(&settings_path())
}

/// Load settings from a specific path with env var overrides.
///
/// If the file does not exist, returns defaults. If the file contains
/// invalid JSON, returns an error.
pub fn load_settings_from_path(path: &Path) -> Result<TronSettings> {
    let defaults = serde_json::to_value(TronSettings::default())?;

    let merged = if path.exists() {
        debug!(?path, "loading settings from file");
        let content = std::fs::read_to_string(path)?;
        let user: Value = serde_json::from_str(&content)?;
        deep_merge(defaults, user)
    } else {
        debug!(?path, "settings file not found, using defaults");
        defaults
    };

    let mut settings: TronSettings = serde_json::from_value(merged)?;
    apply_env_overrides(&mut settings);
    Ok(settings)
}

/// Recursive deep merge of two JSON values.
///
/// - Objects are merged recursively (source overrides target per-key)
/// - Arrays and primitives are replaced entirely by source
/// - Null values in source are skipped (preserving target)
///
/// This matches the TypeScript `deepMerge` behavior exactly.
pub fn deep_merge(target: Value, source: Value) -> Value {
    match (target, source) {
        (Value::Object(mut target_map), Value::Object(source_map)) => {
            for (key, source_val) in source_map {
                if source_val.is_null() {
                    continue;
                }
                let merged = if let Some(target_val) = target_map.remove(&key) {
                    deep_merge(target_val, source_val)
                } else {
                    source_val
                };
                let _ = target_map.insert(key, merged);
            }
            Value::Object(target_map)
        }
        (_, source) => source,
    }
}

/// Apply environment variable overrides to loaded settings.
///
/// Each env var has strict parsing rules:
/// - Integers must be valid and within the specified range
/// - Booleans accept: `true`/`1`/`yes`/`on` or `false`/`0`/`no`/`off`
/// - Invalid values are silently ignored (fall back to file/default)
pub fn apply_env_overrides(settings: &mut TronSettings) {
    // ── Server settings ─────────────────────────────────────────────
    if let Some(v) = read_env_u16("TRON_WS_PORT", 1, 65535) {
        settings.server.ws_port = v;
    }
    if let Some(v) = read_env_u16("TRON_HEALTH_PORT", 1, 65535) {
        settings.server.health_port = v;
    }
    if let Some(v) = read_env_string("TRON_HOST") {
        settings.server.host = v;
    }
    if let Some(v) = read_env_string("TRON_DEFAULT_MODEL") {
        settings.server.default_model = v;
    }
    if let Some(v) = read_env_string("TRON_DEFAULT_PROVIDER") {
        settings.server.default_provider = v;
    }
    if let Some(v) = read_env_usize("TRON_MAX_SESSIONS", 1, 10_000) {
        settings.server.max_concurrent_sessions = v;
    }
    if let Some(v) = read_env_u64("TRON_HEARTBEAT_INTERVAL", 1000, 600_000) {
        settings.server.heartbeat_interval_ms = v;
    }
    if let Some(v) = read_env_string("TRON_SESSIONS_DIR") {
        settings.server.sessions_dir = v;
    }
    if let Some(v) = read_env_string("TRON_MEMORY_DB") {
        settings.server.memory_db_path = v;
    }

    // ── Transcription settings ──────────────────────────────────────
    if let Some(v) = read_env_bool("TRON_TRANSCRIBE_ENABLED") {
        settings.server.transcription.enabled = v;
    }
    if let Some(v) = read_env_bool("TRON_TRANSCRIBE_MANAGE_SIDECAR") {
        settings.server.transcription.manage_sidecar = v;
    }
    if let Some(v) = read_env_string("TRON_TRANSCRIBE_URL") {
        settings.server.transcription.base_url = v;
    }
    if let Some(v) = read_env_u64("TRON_TRANSCRIBE_TIMEOUT_MS", 1000, 3_600_000) {
        settings.server.transcription.timeout_ms = v;
    }
    if let Some(v) = read_env_u64("TRON_TRANSCRIBE_MAX_BYTES", 1024, 1_073_741_824) {
        settings.server.transcription.max_bytes = v;
    }
    if let Some(v) = read_env_string("TRON_TRANSCRIBE_CLEANUP_MODE") {
        if let Ok(mode) = serde_json::from_value(Value::String(v)) {
            settings.server.transcription.cleanup_mode = mode;
        }
    }

    // ── API settings ────────────────────────────────────────────────
    if let Some(v) = read_env_string("ANTHROPIC_CLIENT_ID") {
        settings.api.anthropic.client_id = v;
    }
}

// ── Pure parsing functions (testable without env vars) ──────────────────────

/// Parse a string as a boolean.
///
/// Accepts (case-insensitive): `true`/`1`/`yes`/`on` or `false`/`0`/`no`/`off`.
pub fn parse_bool(val: &str) -> Option<bool> {
    match val.to_lowercase().as_str() {
        "true" | "1" | "yes" | "on" => Some(true),
        "false" | "0" | "no" | "off" => Some(false),
        _ => None,
    }
}

/// Parse a string as a `u16` within a range.
pub fn parse_u16_range(val: &str, min: u16, max: u16) -> Option<u16> {
    let n: u16 = val.parse().ok()?;
    (n >= min && n <= max).then_some(n)
}

/// Parse a string as a `u64` within a range.
pub fn parse_u64_range(val: &str, min: u64, max: u64) -> Option<u64> {
    let n: u64 = val.parse().ok()?;
    (n >= min && n <= max).then_some(n)
}

/// Parse a string as a `usize` within a range.
pub fn parse_usize_range(val: &str, min: usize, max: usize) -> Option<usize> {
    let n: usize = val.parse().ok()?;
    (n >= min && n <= max).then_some(n)
}

// ── Env var readers (thin wrappers) ─────────────────────────────────────────

fn read_env_string(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

fn read_env_bool(name: &str) -> Option<bool> {
    let val = std::env::var(name).ok()?;
    let result = parse_bool(&val);
    if result.is_none() {
        tracing::warn!(key = name, value = %val, "invalid boolean env var, ignoring");
    }
    result
}

fn read_env_u16(name: &str, min: u16, max: u16) -> Option<u16> {
    let val = std::env::var(name).ok()?;
    let result = parse_u16_range(&val, min, max);
    if result.is_none() {
        tracing::warn!(key = name, value = %val, "invalid u16 env var, ignoring");
    }
    result
}

fn read_env_u64(name: &str, min: u64, max: u64) -> Option<u64> {
    let val = std::env::var(name).ok()?;
    let result = parse_u64_range(&val, min, max);
    if result.is_none() {
        tracing::warn!(key = name, value = %val, "invalid u64 env var, ignoring");
    }
    result
}

fn read_env_usize(name: &str, min: usize, max: usize) -> Option<usize> {
    let val = std::env::var(name).ok()?;
    let result = parse_usize_range(&val, min, max);
    if result.is_none() {
        tracing::warn!(key = name, value = %val, "invalid usize env var, ignoring");
    }
    result
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::errors::SettingsError;

    // ── deep_merge ──────────────────────────────────────────────────

    #[test]
    fn merge_simple_override() {
        let target = serde_json::json!({"a": 1, "b": 2});
        let source = serde_json::json!({"a": 10});
        let merged = deep_merge(target, source);
        assert_eq!(merged["a"], 10);
        assert_eq!(merged["b"], 2);
    }

    #[test]
    fn merge_nested_override() {
        let target = serde_json::json!({
            "server": {"port": 8080, "host": "localhost"}
        });
        let source = serde_json::json!({
            "server": {"port": 9090}
        });
        let merged = deep_merge(target, source);
        assert_eq!(merged["server"]["port"], 9090);
        assert_eq!(merged["server"]["host"], "localhost");
    }

    #[test]
    fn merge_deeply_nested() {
        let target = serde_json::json!({
            "a": {"b": {"c": {"d": 1, "e": 2}}}
        });
        let source = serde_json::json!({
            "a": {"b": {"c": {"d": 99}}}
        });
        let merged = deep_merge(target, source);
        assert_eq!(merged["a"]["b"]["c"]["d"], 99);
        assert_eq!(merged["a"]["b"]["c"]["e"], 2);
    }

    #[test]
    fn merge_array_replace() {
        let target = serde_json::json!({"items": [1, 2, 3]});
        let source = serde_json::json!({"items": [4, 5]});
        let merged = deep_merge(target, source);
        assert_eq!(merged["items"], serde_json::json!([4, 5]));
    }

    #[test]
    fn merge_null_preserves_target() {
        let target = serde_json::json!({"a": 1, "b": 2});
        let source = serde_json::json!({"a": null});
        let merged = deep_merge(target, source);
        assert_eq!(merged["a"], 1);
        assert_eq!(merged["b"], 2);
    }

    #[test]
    fn merge_new_keys_added() {
        let target = serde_json::json!({"a": 1});
        let source = serde_json::json!({"b": 2});
        let merged = deep_merge(target, source);
        assert_eq!(merged["a"], 1);
        assert_eq!(merged["b"], 2);
    }

    #[test]
    fn merge_primitive_replace() {
        let target = serde_json::json!("hello");
        let source = serde_json::json!("world");
        let merged = deep_merge(target, source);
        assert_eq!(merged, "world");
    }

    #[test]
    fn merge_object_replaces_primitive() {
        let target = serde_json::json!({"a": "string"});
        let source = serde_json::json!({"a": {"nested": true}});
        let merged = deep_merge(target, source);
        assert_eq!(merged["a"]["nested"], true);
    }

    #[test]
    fn merge_primitive_replaces_object() {
        let target = serde_json::json!({"a": {"nested": true}});
        let source = serde_json::json!({"a": 42});
        let merged = deep_merge(target, source);
        assert_eq!(merged["a"], 42);
    }

    #[test]
    fn merge_empty_source() {
        let target = serde_json::json!({"a": 1, "b": {"c": 2}});
        let source = serde_json::json!({});
        let merged = deep_merge(target.clone(), source);
        assert_eq!(merged, target);
    }

    #[test]
    fn merge_empty_target() {
        let target = serde_json::json!({});
        let source = serde_json::json!({"a": 1});
        let merged = deep_merge(target, source);
        assert_eq!(merged["a"], 1);
    }

    // ── load_settings_from_path ─────────────────────────────────────

    #[test]
    fn load_missing_file_returns_defaults() {
        let path = Path::new("/nonexistent/settings.json");
        let settings = load_settings_from_path(path).unwrap();
        let defaults = TronSettings::default();
        assert_eq!(settings.version, defaults.version);
        assert_eq!(settings.server.ws_port, defaults.server.ws_port);
    }

    #[test]
    fn load_empty_json_returns_defaults() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::fs::write(&path, "{}").unwrap();

        let settings = load_settings_from_path(&path).unwrap();
        let defaults = TronSettings::default();
        assert_eq!(settings.version, defaults.version);
        assert_eq!(settings.server.ws_port, defaults.server.ws_port);
    }

    #[test]
    fn load_partial_json_overrides() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::fs::write(
            &path,
            r#"{"server": {"wsPort": 9090}, "retry": {"maxRetries": 5}}"#,
        )
        .unwrap();

        let settings = load_settings_from_path(&path).unwrap();
        assert_eq!(settings.server.ws_port, 9090);
        assert_eq!(settings.retry.max_retries, 5);
        assert_eq!(settings.server.health_port, 8081);
        assert_eq!(settings.retry.base_delay_ms, 1000);
    }

    #[test]
    fn load_deeply_nested_override() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::fs::write(
            &path,
            r#"{"context": {"memory": {"embedding": {"dimensions": 1024}}}}"#,
        )
        .unwrap();

        let settings = load_settings_from_path(&path).unwrap();
        assert_eq!(settings.context.memory.embedding.dimensions, 1024);
        assert!(settings.context.memory.embedding.enabled);
    }

    #[test]
    fn load_invalid_json_returns_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::fs::write(&path, "not valid json").unwrap();

        let result = load_settings_from_path(&path);
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), SettingsError::Json(_)));
    }

    #[test]
    fn load_with_guardrails() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::fs::write(
            &path,
            r#"{"guardrails": {"audit": {"enabled": true, "maxEntries": 500}}}"#,
        )
        .unwrap();

        let settings = load_settings_from_path(&path).unwrap();
        assert!(settings.guardrails.is_some());
        let g = settings.guardrails.unwrap();
        assert_eq!(g.audit.unwrap().max_entries, 500);
    }

    #[test]
    fn load_array_replace_not_merge() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::fs::write(
            &path,
            r#"{"tools": {"bash": {"dangerousPatterns": ["^rm -rf /"]}}}"#,
        )
        .unwrap();

        let settings = load_settings_from_path(&path).unwrap();
        assert_eq!(settings.tools.bash.dangerous_patterns.len(), 1);
        assert_eq!(settings.tools.bash.dangerous_patterns[0], "^rm -rf /");
    }

    // ── parse_bool ──────────────────────────────────────────────────

    #[test]
    fn parse_bool_true_variants() {
        for val in &["true", "1", "yes", "on", "TRUE", "Yes", "ON"] {
            assert_eq!(parse_bool(val), Some(true), "failed for {val}");
        }
    }

    #[test]
    fn parse_bool_false_variants() {
        for val in &["false", "0", "no", "off", "FALSE", "No", "OFF"] {
            assert_eq!(parse_bool(val), Some(false), "failed for {val}");
        }
    }

    #[test]
    fn parse_bool_invalid() {
        assert_eq!(parse_bool("maybe"), None);
        assert_eq!(parse_bool(""), None);
        assert_eq!(parse_bool("2"), None);
    }

    // ── parse_u16_range ─────────────────────────────────────────────

    #[test]
    fn parse_u16_valid() {
        assert_eq!(parse_u16_range("9090", 1, 65535), Some(9090));
        assert_eq!(parse_u16_range("1", 1, 65535), Some(1));
        assert_eq!(parse_u16_range("65535", 1, 65535), Some(65535));
    }

    #[test]
    fn parse_u16_out_of_range() {
        assert_eq!(parse_u16_range("0", 1, 65535), None);
    }

    #[test]
    fn parse_u16_invalid() {
        assert_eq!(parse_u16_range("not_a_number", 1, 65535), None);
        assert_eq!(parse_u16_range("", 1, 65535), None);
        assert_eq!(parse_u16_range("99999", 1, 65535), None);
    }

    // ── parse_u64_range ─────────────────────────────────────────────

    #[test]
    fn parse_u64_valid() {
        assert_eq!(parse_u64_range("30000", 1000, 600_000), Some(30_000));
        assert_eq!(parse_u64_range("1000", 1000, 600_000), Some(1000));
    }

    #[test]
    fn parse_u64_below_min() {
        assert_eq!(parse_u64_range("500", 1000, 600_000), None);
    }

    #[test]
    fn parse_u64_above_max() {
        assert_eq!(parse_u64_range("700000", 1000, 600_000), None);
    }

    #[test]
    fn parse_u64_invalid() {
        assert_eq!(parse_u64_range("abc", 1000, 600_000), None);
    }

    // ── parse_usize_range ───────────────────────────────────────────

    #[test]
    fn parse_usize_valid() {
        assert_eq!(parse_usize_range("50", 1, 10_000), Some(50));
    }

    #[test]
    fn parse_usize_out_of_range() {
        assert_eq!(parse_usize_range("0", 1, 10_000), None);
        assert_eq!(parse_usize_range("20000", 1, 10_000), None);
    }
}
