//! Flat sparse-settings loading, merge, validation, and environment overrides.

use std::path::Path;

use serde_json::Value;
use tracing::debug;

use crate::domains::settings::errors::{Result, SettingsError};
use crate::domains::settings::types::TronSettings;

/// Load one complete effective settings value from compiled defaults, a sparse
/// flat TOML overlay, and the explicitly supported environment overrides.
pub(in crate::domains::settings::config) fn load_settings_from_path(
    path: &Path,
) -> Result<TronSettings> {
    let defaults = serde_json::to_value(TronSettings::default())
        .map_err(|error| SettingsError::json("encode default settings", error))?;
    let overlay = read_sparse_settings_overlay(path)?;
    let merged = deep_merge(defaults, overlay);
    let mut settings: TronSettings = serde_json::from_value(merged).map_err(|error| {
        SettingsError::InvalidValue(format!("failed to load settings: {error}"))
    })?;
    settings.validate_strict()?;
    apply_env_overrides(&mut settings);
    settings.validate();
    settings.validate_strict()?;
    Ok(settings)
}

/// Read a sparse flat TOML settings document as JSON. Missing means `{}`.
pub(in crate::domains::settings::config) fn read_sparse_settings_overlay(
    path: &Path,
) -> Result<Value> {
    if !path.exists() {
        return Ok(Value::Object(Default::default()));
    }
    debug!(?path, "loading sparse engine settings");
    let content = std::fs::read_to_string(path)?;
    let value: toml::Value = toml::from_str(&content).map_err(|error| {
        SettingsError::InvalidValue(format!("failed to parse settings TOML: {error}"))
    })?;
    toml_value_to_json(value)
}

fn toml_value_to_json(value: toml::Value) -> Result<Value> {
    serde_json::to_value(value).map_err(|error| {
        SettingsError::InvalidValue(format!("failed to convert TOML settings: {error}"))
    })
}

/// Recursively merge sparse settings over defaults.
///
/// Objects merge per key, arrays and primitives replace, and null source values
/// preserve the target value.
pub(in crate::domains::settings::config) fn deep_merge(target: Value, source: Value) -> Value {
    match (target, source) {
        (Value::Object(mut target_map), Value::Object(source_map)) => {
            for (key, source_value) in source_map {
                if source_value.is_null() {
                    continue;
                }
                let merged = target_map
                    .remove(&key)
                    .map_or(source_value.clone(), |target_value| {
                        deep_merge(target_value, source_value)
                    });
                let _ = target_map.insert(key, merged);
            }
            Value::Object(target_map)
        }
        (_, source) => source,
    }
}

/// Apply the small explicit environment-override surface.
fn apply_env_overrides(settings: &mut TronSettings) {
    if let Some(value) = read_env_string("TRON_DEFAULT_MODEL") {
        settings.server.default_model = value;
    }
    if let Some(value) = read_env_u64("TRON_HEARTBEAT_INTERVAL", 1_000, 600_000) {
        settings.server.heartbeat_interval_ms = value;
    }
    if let Some(value) = read_env_string("ANTHROPIC_CLIENT_ID") {
        settings.api.anthropic.client_id = value;
    }
}

fn read_env_string(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|value| !value.is_empty())
}

fn read_env_u64(name: &str, min: u64, max: u64) -> Option<u64> {
    let raw = std::env::var(name).ok()?;
    let parsed = raw
        .parse::<u64>()
        .ok()
        .filter(|value| (min..=max).contains(value));
    if parsed.is_none() {
        tracing::warn!(key = name, value = %raw, "invalid u64 environment override; ignoring");
    }
    parsed
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn missing_file_uses_compiled_defaults() {
        let root = tempfile::tempdir().unwrap();
        let settings = load_settings_from_path(&root.path().join("settings.toml")).unwrap();
        assert_eq!(settings.server.default_model, "claude-sonnet-4-6");
        assert_eq!(settings.server.heartbeat_interval_ms, 30_000);
    }

    #[test]
    fn flat_sparse_toml_overrides_compiled_defaults() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("settings.toml");
        std::fs::write(
            &path,
            "autonomousWorkers = true\n[server]\nheartbeatIntervalMs = 45000\n",
        )
        .unwrap();

        let settings = load_settings_from_path(&path).unwrap();
        assert!(settings.autonomous_workers);
        assert_eq!(settings.server.heartbeat_interval_ms, 45_000);
        assert_eq!(settings.server.default_model, "claude-sonnet-4-6");
    }

    #[test]
    fn unknown_keys_remain_strict() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("settings.toml");
        std::fs::write(&path, "[server]\nretiredField = true\n").unwrap();

        let error = load_settings_from_path(&path).unwrap_err();
        assert!(error.to_string().contains("unknown field"));
    }

    #[test]
    fn malformed_toml_fails_without_repair() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("settings.toml");
        std::fs::write(&path, "[server\n").unwrap();
        let error = load_settings_from_path(&path).unwrap_err();
        assert!(error.to_string().contains("parse settings TOML"));
    }

    #[test]
    fn deep_merge_recurses_and_replaces_arrays() {
        let merged = deep_merge(
            json!({"server":{"port":1,"host":"local"},"items":[1,2]}),
            json!({"server":{"port":2},"items":[3]}),
        );
        assert_eq!(merged["server"]["port"], 2);
        assert_eq!(merged["server"]["host"], "local");
        assert_eq!(merged["items"], json!([3]));
    }
}
