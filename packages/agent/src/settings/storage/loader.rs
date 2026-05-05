//! Settings loading with deep merge and environment variable overrides.
//!
//! Loading flow:
//! 1. Start with `~/.tron/profiles/default/settings/defaults.json`
//! 2. If `~/.tron/profiles/user/settings.json` exists, deep-merge user values over defaults
//! 3. Apply environment variable overrides (highest priority)
//!
//! Deep merge rules:
//! - Objects are merged recursively (source overrides target per-key)
//! - Arrays and primitives are replaced entirely by source
//! - Null values in source are skipped (preserving target)

use std::io::Write as _;
use std::path::{Path, PathBuf};

use serde_json::Value;
use tracing::{debug, warn};

use crate::settings::errors::Result;
use crate::settings::types::TronSettings;

/// Resolve the `~/.tron` directory.
pub fn tron_home_dir() -> PathBuf {
    crate::core::paths::tron_home()
}

/// Resolve the sparse settings override path (`~/.tron/profiles/user/settings.json`).
pub fn settings_path() -> PathBuf {
    crate::core::paths::settings_path()
}

/// Resolve the managed default settings file inside `profiles/default`.
pub fn settings_defaults_path() -> PathBuf {
    crate::core::paths::settings_defaults_path()
}

/// Resolve the built-in auth file (`~/.tron/profiles/auth.json`).
pub fn auth_path() -> PathBuf {
    crate::core::paths::auth_path()
}

/// Repair-seed the default profile settings file if it is missing.
pub fn seed_settings_defaults() -> Result<Option<PathBuf>> {
    seed_settings_defaults_at(&crate::core::paths::tron_home())
}

/// Repair-seed `<home>/profiles/default/settings/defaults.json` if it is missing.
///
/// Normal startup gets this file from the Constitution first-seed bundle.
/// This helper remains available for explicit repair and tests.
pub fn seed_settings_defaults_at(home: &Path) -> Result<Option<PathBuf>> {
    let path = home
        .join(crate::core::paths::dirs::PROFILES)
        .join(crate::core::profile::DEFAULT_PROFILE)
        .join(crate::core::paths::dirs::SETTINGS)
        .join(crate::core::paths::files::DEFAULTS_JSON);
    if path.exists() {
        return Ok(None);
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut defaults = bundled_settings_defaults_bytes()?;
    if !defaults.ends_with(b"\n") {
        defaults.push(b'\n');
    }
    let parent = path.parent().ok_or_else(|| {
        crate::settings::errors::SettingsError::InvalidValue(
            "settings defaults path must have a parent directory".to_string(),
        )
    })?;
    let mut temp = tempfile::Builder::new()
        .prefix(".defaults.")
        .suffix(".tmp")
        .tempfile_in(parent)?;
    temp.write_all(&defaults)?;
    temp.as_file_mut().sync_all()?;
    temp.persist(&path)
        .map_err(|error| crate::settings::errors::SettingsError::Io(error.error))?;
    Ok(Some(path))
}

fn bundled_settings_defaults_bytes() -> Result<Vec<u8>> {
    if let Some(path) =
        crate::core::constitution::bundled_default_file("profiles/default/settings/defaults.json")
    {
        return Ok(std::fs::read(path)?);
    }
    warn!("bundled settings/defaults.json is missing; seeding emergency compiled defaults");
    Ok(serde_json::to_string_pretty(&TronSettings::default())?.into_bytes())
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
    let defaults = load_settings_defaults_for(path)?;
    let mut settings = if path.exists() {
        debug!(?path, "loading settings from file");
        let content = std::fs::read_to_string(path)?;
        let user: Value = serde_json::from_str(&content)?;
        let merged = deep_merge(serde_json::to_value(defaults)?, user);
        serde_json::from_value(merged)?
    } else {
        debug!(
            ?path,
            "settings file not found, using Constitution defaults"
        );
        defaults
    };

    settings.validate_strict()?;
    apply_env_overrides(&mut settings);
    settings.validate();
    settings.validate_strict()?;
    Ok(settings)
}

/// Load the managed defaults that correspond to a sparse settings path.
pub fn load_settings_defaults_for(settings_path: &Path) -> Result<TronSettings> {
    let path = defaults_path_for_settings_path(settings_path);
    if !path.exists() {
        warn!(
            ?path,
            "settings defaults are missing; using emergency compiled defaults"
        );
        return Ok(TronSettings::default());
    }

    debug!(?path, "loading settings defaults");
    let content = std::fs::read_to_string(&path)?;
    let mut defaults: TronSettings = serde_json::from_str(&content)?;
    defaults.validate_strict()?;
    defaults.validate();
    defaults.validate_strict()?;
    Ok(defaults)
}

fn defaults_path_for_settings_path(settings_path: &Path) -> PathBuf {
    if settings_path.file_name().and_then(|name| name.to_str())
        != Some(crate::core::paths::files::SETTINGS_JSON)
    {
        return settings_defaults_path();
    }

    if let Some(user_dir) = settings_path.parent()
        && user_dir.file_name().and_then(|name| name.to_str())
            == Some(crate::core::profile::USER_PROFILE)
        && let Some(profiles_dir) = user_dir.parent()
        && profiles_dir.file_name().and_then(|name| name.to_str())
            == Some(crate::core::paths::dirs::PROFILES)
    {
        return profiles_dir
            .join(crate::core::profile::DEFAULT_PROFILE)
            .join(crate::core::paths::dirs::SETTINGS)
            .join(crate::core::paths::files::DEFAULTS_JSON);
    }

    // Test/custom settings paths use a sibling defaults.json when present.
    // If absent, load_settings_defaults_for falls back to emergency compiled
    // defaults rather than reading the user's real Tron Home.
    settings_path.with_file_name(crate::core::paths::files::DEFAULTS_JSON)
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
    if let Some(v) = read_env_string("TRON_DEFAULT_MODEL") {
        settings.server.default_model = v;
    }
    if let Some(v) = read_env_string("TRON_DEFAULT_PROVIDER") {
        settings.server.default_provider = v;
    }
    if let Some(v) = read_env_u64("TRON_HEARTBEAT_INTERVAL", 1000, 600_000) {
        settings.server.heartbeat_interval_ms = v;
    }
    if let Some(v) = read_env_string("TRON_MEMORY_DB") {
        settings.server.memory_db_path = v;
    }

    // ── Transcription settings ──────────────────────────────────────
    if let Some(v) = read_env_bool("TRON_TRANSCRIBE_ENABLED") {
        settings.server.transcription.enabled = v;
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
    if val.eq_ignore_ascii_case("true")
        || val == "1"
        || val.eq_ignore_ascii_case("yes")
        || val.eq_ignore_ascii_case("on")
    {
        Some(true)
    } else if val.eq_ignore_ascii_case("false")
        || val == "0"
        || val.eq_ignore_ascii_case("no")
        || val.eq_ignore_ascii_case("off")
    {
        Some(false)
    } else {
        None
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

fn read_env_u64(name: &str, min: u64, max: u64) -> Option<u64> {
    let val = std::env::var(name).ok()?;
    let result = parse_u64_range(&val, min, max);
    if result.is_none() {
        tracing::warn!(key = name, value = %val, "invalid u64 env var, ignoring");
    }
    result
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::errors::SettingsError;

    #[test]
    fn tron_home_dir_ends_with_dot_tron() {
        let dir = tron_home_dir();
        assert!(dir.to_string_lossy().ends_with(".tron"));
    }

    #[test]
    fn auth_path_under_tron_dir() {
        let path = auth_path();
        assert!(path.to_string_lossy().contains(".tron"));
        assert!(path.to_string_lossy().ends_with("auth.json"));
    }

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
        assert_eq!(settings.name, defaults.name);
        assert_eq!(settings.server.default_model, defaults.server.default_model);
        assert_eq!(settings.retry.max_retries, defaults.retry.max_retries);
        assert!((settings.retry.jitter_factor - defaults.retry.jitter_factor).abs() < f64::EPSILON);
        assert_eq!(settings.agent.max_turns, defaults.agent.max_turns);
        assert_eq!(settings.agent.subagent_model, defaults.agent.subagent_model);
        assert_eq!(
            settings.tools.bash.default_timeout_ms,
            defaults.tools.bash.default_timeout_ms
        );
        assert_eq!(
            settings.context.compactor.max_tokens,
            defaults.context.compactor.max_tokens
        );
        assert!(settings.guardrails.is_none());
    }

    #[test]
    fn seed_settings_defaults_writes_full_default_file_once() {
        let dir = tempfile::tempdir().unwrap();
        let seeded = seed_settings_defaults_at(dir.path()).unwrap();
        let path = dir
            .path()
            .join(crate::core::paths::dirs::PROFILES)
            .join(crate::core::profile::DEFAULT_PROFILE)
            .join(crate::core::paths::dirs::SETTINGS)
            .join("defaults.json");

        assert_eq!(seeded.as_deref(), Some(path.as_path()));
        assert!(path.exists());
        let parsed: TronSettings =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(
            parsed.server.default_model,
            TronSettings::default().server.default_model
        );

        let second = seed_settings_defaults_at(dir.path()).unwrap();
        assert!(second.is_none(), "seeding must preserve existing defaults");
    }

    #[test]
    fn bundled_settings_defaults_match_emergency_defaults() {
        let bundled: TronSettings =
            serde_json::from_slice(&bundled_settings_defaults_bytes().unwrap()).unwrap();
        let bundled_value = serde_json::to_value(bundled).unwrap();
        let emergency_value = serde_json::to_value(TronSettings::default()).unwrap();

        assert_eq!(
            bundled_value, emergency_value,
            "bundled settings/defaults.json must preserve current behavior"
        );
    }

    #[test]
    fn load_uses_managed_defaults_before_sparse_user_file() {
        let dir = tempfile::tempdir().unwrap();
        let defaults_path = dir.path().join("defaults.json");
        let settings_path = dir.path().join("settings.json");
        std::fs::write(
            &defaults_path,
            r#"{"server": {"defaultModel": "managed-default", "heartbeatIntervalMs": 45000}}"#,
        )
        .unwrap();
        std::fs::write(
            &settings_path,
            r#"{"server": {"defaultProvider": "openai"}}"#,
        )
        .unwrap();

        let settings = load_settings_from_path(&settings_path).unwrap();

        assert_eq!(settings.server.default_model, "managed-default");
        assert_eq!(settings.server.default_provider, "openai");
        assert_eq!(settings.server.heartbeat_interval_ms, 45_000);
    }

    #[test]
    fn malformed_managed_defaults_fail_fast() {
        let dir = tempfile::tempdir().unwrap();
        let defaults_path = dir.path().join("defaults.json");
        let settings_path = dir.path().join("settings.json");
        std::fs::write(&defaults_path, "{broken").unwrap();

        let err = load_settings_from_path(&settings_path).unwrap_err();

        assert!(matches!(err, SettingsError::Json(_)));
    }

    #[test]
    fn load_empty_json_returns_defaults() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::fs::write(&path, "{}").unwrap();

        let settings = load_settings_from_path(&path).unwrap();
        let defaults = TronSettings::default();
        assert_eq!(settings.version, defaults.version);
        assert_eq!(settings.server.default_model, defaults.server.default_model);
    }

    #[test]
    fn load_partial_json_overrides() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::fs::write(
            &path,
            r#"{"server": {"defaultModel": "custom-model"}, "retry": {"maxRetries": 5}}"#,
        )
        .unwrap();

        let settings = load_settings_from_path(&path).unwrap();
        assert_eq!(settings.server.default_model, "custom-model");
        assert_eq!(settings.retry.max_retries, 5);
        assert_eq!(settings.retry.base_delay_ms, 1000);
    }

    #[test]
    fn load_deeply_nested_override() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::fs::write(&path, r#"{"context": {"compactor": {"maxTokens": 50000}}}"#).unwrap();

        let settings = load_settings_from_path(&path).unwrap();
        assert_eq!(settings.context.compactor.max_tokens, 50_000);
        assert!(settings.context.rules.discover_standalone_files);
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
    fn load_zero_heartbeat_interval_returns_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::fs::write(&path, r#"{"server": {"heartbeatIntervalMs": 0}}"#).unwrap();

        let err = load_settings_from_path(&path).unwrap_err();

        assert!(matches!(err, SettingsError::InvalidValue(_)));
        assert!(err.to_string().contains("heartbeatIntervalMs"));
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

    #[test]
    fn load_validates_clamping() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::fs::write(&path, r#"{"retry": {"jitterFactor": 5.0}}"#).unwrap();

        let settings = load_settings_from_path(&path).unwrap();
        assert!((settings.retry.jitter_factor - 1.0).abs() < f64::EPSILON);
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
}
