//! Profile-backed settings loading with deep merge and environment overrides.
//!
//! Loading flow:
//! 1. Resolve the active profile without the global user overlay.
//! 2. Read sparse `[settings]` overrides from `~/.tron/profiles/user/profile.toml`.
//! 3. Deep-merge sparse values over the profile settings.
//! 4. Apply supported environment variable overrides from an explicit allowlist.

use std::path::{Path, PathBuf};

use serde_json::Value;
use tracing::debug;

use crate::domains::settings::errors::{Result, SettingsError};
use crate::domains::settings::types::TronSettings;

/// Settings environment variables accepted as runtime overrides.
///
/// INVARIANT: this is the complete settings-env allowlist. Path, release,
/// device-selection, test-host, and benchmark secrets are inventoried as
/// separate runtime/script env surfaces and must not be added here unless they
/// intentionally become settings sources.
pub const SETTINGS_ENV_ALLOWLIST: &[&str] = &[
    "TRON_DEFAULT_MODEL",
    "TRON_DEFAULT_PROVIDER",
    "TRON_HEARTBEAT_INTERVAL",
    "ANTHROPIC_CLIENT_ID",
];

/// Resolve the `~/.tron` directory.
pub fn tron_home_dir() -> PathBuf {
    crate::shared::foundation::paths::tron_home()
}

/// Resolve the sparse profile override path (`~/.tron/profiles/user/profile.toml`).
pub fn settings_path() -> PathBuf {
    crate::shared::foundation::paths::user_profile_path()
}

/// Resolve the managed default profile file.
pub fn settings_defaults_path() -> PathBuf {
    crate::shared::foundation::paths::default_profile_dir()
        .join(crate::shared::foundation::paths::files::PROFILE_TOML)
}

/// Resolve the built-in auth file (`~/.tron/profiles/auth.json`).
pub fn auth_path() -> PathBuf {
    crate::shared::foundation::paths::auth_path()
}

/// Profile settings are seeded as part of the managed profile defaults.
pub fn seed_settings_defaults() -> Result<Option<PathBuf>> {
    Ok(None)
}

/// Profile settings are seeded as part of the managed profile defaults.
pub fn seed_settings_defaults_at(home: &Path) -> Result<Option<PathBuf>> {
    let _ = home;
    Ok(None)
}

/// Profile settings are seeded as part of profile defaults.
pub fn seed_settings_defaults_for_path(settings_path: &Path) -> Result<Option<PathBuf>> {
    let _ = settings_path;
    Ok(None)
}

/// Load settings from the default path with env var overrides.
pub fn load_settings() -> Result<TronSettings> {
    load_settings_from_path(&settings_path())
}

/// Load settings from a sparse user profile path with env var overrides.
pub fn load_settings_from_path(path: &Path) -> Result<TronSettings> {
    let defaults = load_settings_defaults_for(path)?;
    let overlay = read_sparse_settings_overlay(path)?;
    let merged = deep_merge(
        serde_json::to_value(defaults)
            .map_err(|error| SettingsError::json("encode default settings", error))?,
        overlay,
    );
    let mut settings: TronSettings = serde_json::from_value(merged).map_err(|error| {
        SettingsError::InvalidValue(format!("failed to load settings: {error}"))
    })?;
    settings.validate_strict()?;
    apply_env_overrides(&mut settings)?;
    settings.validate();
    settings.validate_strict()?;
    Ok(settings)
}

/// Load active profile settings before sparse user overrides.
pub fn load_settings_defaults_for(settings_path: &Path) -> Result<TronSettings> {
    let home = tron_home_for_user_profile_path(settings_path)
        .unwrap_or_else(crate::shared::foundation::paths::tron_home);
    let active =
        crate::shared::foundation::profile::active_profile_name_at(&home).ok_or_else(|| {
            SettingsError::InvalidValue(format!(
                "missing active profile pointer under {}",
                home.join(crate::shared::foundation::paths::dirs::PROFILES)
                    .join(crate::shared::foundation::paths::files::ACTIVE_TOML)
                    .display()
            ))
        })?;
    let resolved = crate::shared::foundation::profile::resolve_profile_base_at(&home, &active)
        .map_err(|error| SettingsError::InvalidValue(error.to_string()))?;
    let mut defaults = resolved.spec.settings().clone();
    defaults.validate_strict()?;
    defaults.validate();
    defaults.validate_strict()?;
    Ok(defaults)
}

/// Read only sparse `[settings]` from a user profile TOML file.
pub fn read_sparse_settings_overlay(path: &Path) -> Result<Value> {
    if !path.exists() {
        return Ok(Value::Object(Default::default()));
    }
    debug!(?path, "loading sparse profile settings overlay");
    let content = std::fs::read_to_string(path)?;
    let value: toml::Value = toml::from_str(&content).map_err(|error| {
        SettingsError::InvalidValue(format!("failed to parse settings TOML: {error}"))
    })?;
    let settings = value
        .get("settings")
        .cloned()
        .unwrap_or_else(|| toml::Value::Table(Default::default()));
    toml_value_to_json(settings)
}

fn tron_home_for_user_profile_path(path: &Path) -> Option<PathBuf> {
    let file = path.file_name()?.to_str()?;
    if file != crate::shared::foundation::paths::files::PROFILE_TOML {
        return None;
    }
    let user_dir = path.parent()?;
    if user_dir.file_name()?.to_str()? != crate::shared::foundation::profile::USER_PROFILE {
        return None;
    }
    let profiles_dir = user_dir.parent()?;
    if profiles_dir.file_name()?.to_str()? != crate::shared::foundation::paths::dirs::PROFILES {
        return None;
    }
    profiles_dir.parent().map(Path::to_path_buf)
}

fn toml_value_to_json(value: toml::Value) -> Result<Value> {
    serde_json::to_value(value).map_err(|error| {
        SettingsError::InvalidValue(format!("failed to convert TOML settings: {error}"))
    })
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
/// Each env var has strict parsing rules. A malformed setting env var returns
/// an error before mutating the caller's settings snapshot, so an invalid
/// high-priority source cannot silently fall back to profile/default values.
pub fn apply_env_overrides(settings: &mut TronSettings) -> Result<()> {
    apply_env_overrides_from(settings, |name| std::env::var(name).ok())
}

pub(crate) fn apply_env_overrides_from(
    settings: &mut TronSettings,
    mut read_env: impl FnMut(&str) -> Option<String>,
) -> Result<()> {
    let mut next = settings.clone();

    // ── Server settings ─────────────────────────────────────────────
    if let Some(v) = read_env_string_from(&mut read_env, "TRON_DEFAULT_MODEL") {
        next.server.default_model = v;
    }
    if let Some(v) = read_env_string_from(&mut read_env, "TRON_DEFAULT_PROVIDER") {
        next.server.default_provider = v;
    }
    if let Some(v) = read_env_u64_from(
        &mut read_env,
        "TRON_HEARTBEAT_INTERVAL",
        crate::domains::settings::types::ServerSettings::MIN_HEARTBEAT_INTERVAL_MS,
        crate::domains::settings::types::ServerSettings::MAX_HEARTBEAT_INTERVAL_MS,
    )? {
        next.server.heartbeat_interval_ms = v;
    }
    // ── API settings ────────────────────────────────────────────────
    if let Some(v) = read_env_string_from(&mut read_env, "ANTHROPIC_CLIENT_ID") {
        next.api.anthropic.client_id = v;
    }
    *settings = next;
    Ok(())
}

// ── Pure parsing functions (testable without env vars) ──────────────────────

/// Parse a string as a `u64` within a range.
pub fn parse_u64_range(val: &str, min: u64, max: u64) -> Option<u64> {
    let n: u64 = val.parse().ok()?;
    (n >= min && n <= max).then_some(n)
}

// ── Env var readers (thin wrappers) ─────────────────────────────────────────

fn read_env_string_from(
    read_env: &mut impl FnMut(&str) -> Option<String>,
    name: &str,
) -> Option<String> {
    read_env(name).filter(|v| !v.is_empty())
}

fn read_env_u64_from(
    read_env: &mut impl FnMut(&str) -> Option<String>,
    name: &str,
    min: u64,
    max: u64,
) -> Result<Option<u64>> {
    let Some(val) = read_env(name) else {
        return Ok(None);
    };
    match parse_u64_range(&val, min, max) {
        Some(parsed) => Ok(Some(parsed)),
        None => Err(SettingsError::InvalidValue(format!(
            "environment override {name} must be an integer between {min} and {max}; got {val:?}"
        ))),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::settings::errors::SettingsError;

    fn temp_settings_path(dir: &tempfile::TempDir) -> PathBuf {
        let home = dir.path().join(".tron");
        crate::shared::foundation::constitution::ensure_tron_home_at(&home).unwrap();
        home.join(crate::shared::foundation::paths::dirs::PROFILES)
            .join(crate::shared::foundation::profile::USER_PROFILE)
            .join(crate::shared::foundation::paths::files::PROFILE_TOML)
    }

    fn write_sparse_settings(path: &Path, settings_toml: &str) {
        let content = format!(
            r#"version = "2"
name = "user"
managed = false
profileClass = "custom"
inherits = []
authProfile = "default"

{settings_toml}
"#
        );
        std::fs::write(path, content).unwrap();
    }

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
    fn load_missing_sparse_file_returns_managed_defaults() {
        let dir = tempfile::tempdir().unwrap();
        let path = temp_settings_path(&dir);
        std::fs::remove_file(&path).unwrap();

        let settings = load_settings_from_path(&path).unwrap();
        let defaults = crate::shared::foundation::profile::bundled_default_execution_spec()
            .settings()
            .clone();
        assert_eq!(settings.version, defaults.version);
        assert_eq!(settings.name, defaults.name);
        assert_eq!(settings.server.default_model, defaults.server.default_model);
        assert_eq!(settings.retry.max_retries, defaults.retry.max_retries);
        assert!((settings.retry.jitter_factor - defaults.retry.jitter_factor).abs() < f64::EPSILON);
        assert_eq!(settings.agent.max_turns, defaults.agent.max_turns);
        assert_eq!(
            settings.context.compactor.max_tokens,
            defaults.context.compactor.max_tokens
        );
    }

    #[test]
    fn seed_settings_defaults_is_noop_because_profiles_seed_settings() {
        let dir = tempfile::tempdir().unwrap();
        let seeded = seed_settings_defaults_at(dir.path()).unwrap();
        assert!(seeded.is_none());

        let second = seed_settings_defaults_at(dir.path()).unwrap();
        assert!(second.is_none());
    }

    #[test]
    fn bundled_profile_settings_match_rust_settings_schema() {
        let profile = crate::shared::foundation::profile::bundled_default_execution_spec();
        let bundled_value = serde_json::to_value(profile.settings()).unwrap();
        let round_tripped: TronSettings = serde_json::from_value(bundled_value.clone()).unwrap();

        assert_eq!(
            serde_json::to_value(round_tripped).unwrap(),
            bundled_value,
            "default profile [settings] must preserve the public settings JSON shape"
        );
    }

    #[test]
    fn load_uses_active_profile_settings_before_sparse_user_overlay() {
        let dir = tempfile::tempdir().unwrap();
        let settings_path = temp_settings_path(&dir);
        let home = settings_path
            .ancestors()
            .nth(3)
            .expect("profile path should be under .tron")
            .to_path_buf();
        std::fs::write(
            home.join(crate::shared::foundation::paths::dirs::PROFILES)
                .join(crate::shared::foundation::paths::files::ACTIVE_TOML),
            "active = \"managed\"\n",
        )
        .unwrap();
        let managed_profile = home
            .join(crate::shared::foundation::paths::dirs::PROFILES)
            .join("managed")
            .join(crate::shared::foundation::paths::files::PROFILE_TOML);
        std::fs::create_dir_all(managed_profile.parent().unwrap()).unwrap();
        std::fs::write(
            &managed_profile,
            r#"version = "3"
name = "managed"
managed = false
profileClass = "custom"
inherits = ["default"]
authProfile = "default"

[settings.server]
defaultModel = "managed-default"
heartbeatIntervalMs = 45000
"#,
        )
        .unwrap();
        write_sparse_settings(
            &settings_path,
            r#"[settings.server]
defaultProvider = "openai"
"#,
        );

        let settings = load_settings_from_path(&settings_path).unwrap();

        assert_eq!(settings.server.default_model, "managed-default");
        assert_eq!(settings.server.default_provider, "openai");
        assert_eq!(settings.server.heartbeat_interval_ms, 45_000);
    }

    #[test]
    fn malformed_active_profile_fails_fast() {
        let dir = tempfile::tempdir().unwrap();
        let settings_path = temp_settings_path(&dir);
        let home = settings_path
            .ancestors()
            .nth(3)
            .expect("profile path should be under .tron")
            .to_path_buf();
        std::fs::write(
            home.join(crate::shared::foundation::paths::dirs::PROFILES)
                .join(crate::shared::foundation::paths::files::ACTIVE_TOML),
            "active = \"broken\"\n",
        )
        .unwrap();
        let broken_profile = home
            .join(crate::shared::foundation::paths::dirs::PROFILES)
            .join("broken")
            .join(crate::shared::foundation::paths::files::PROFILE_TOML);
        std::fs::create_dir_all(broken_profile.parent().unwrap()).unwrap();
        std::fs::write(&broken_profile, "{broken").unwrap();

        let err = load_settings_from_path(&settings_path).unwrap_err();

        assert!(matches!(err, SettingsError::InvalidValue(_)));
        assert!(err.to_string().contains("invalid TOML"));
    }

    #[test]
    fn load_empty_profile_settings_returns_defaults() {
        let dir = tempfile::tempdir().unwrap();
        let path = temp_settings_path(&dir);
        write_sparse_settings(&path, "");

        let settings = load_settings_from_path(&path).unwrap();
        let defaults = crate::shared::foundation::profile::bundled_default_execution_spec()
            .settings()
            .clone();
        assert_eq!(settings.version, defaults.version);
        assert_eq!(settings.server.default_model, defaults.server.default_model);
    }

    #[test]
    fn load_partial_toml_overrides() {
        let dir = tempfile::tempdir().unwrap();
        let path = temp_settings_path(&dir);
        write_sparse_settings(
            &path,
            r#"[settings.server]
defaultModel = "custom-model"

[settings.retry]
maxRetries = 5
"#,
        );

        let settings = load_settings_from_path(&path).unwrap();
        assert_eq!(settings.server.default_model, "custom-model");
        assert_eq!(settings.retry.max_retries, 5);
        assert_eq!(settings.retry.base_delay_ms, 1000);
    }

    #[test]
    fn load_deeply_nested_override() {
        let dir = tempfile::tempdir().unwrap();
        let path = temp_settings_path(&dir);
        write_sparse_settings(
            &path,
            r#"[settings.context.compactor]
maxTokens = 50000
"#,
        );

        let settings = load_settings_from_path(&path).unwrap();
        assert_eq!(settings.context.compactor.max_tokens, 50_000);
    }

    #[test]
    fn load_invalid_toml_returns_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = temp_settings_path(&dir);
        std::fs::write(&path, "{broken").unwrap();

        let result = load_settings_from_path(&path);
        assert!(result.is_err());
        assert!(matches!(
            result.unwrap_err(),
            SettingsError::InvalidValue(_)
        ));
    }

    #[test]
    fn load_rejects_unknown_nested_settings_fields() {
        let dir = tempfile::tempdir().unwrap();
        let path = temp_settings_path(&dir);
        write_sparse_settings(
            &path,
            r#"[settings.context.compactor]
retiredKnob = true
"#,
        );

        let err = load_settings_from_path(&path).unwrap_err();

        assert!(matches!(err, SettingsError::InvalidValue(_)));
        assert!(
            err.to_string().contains("retiredKnob"),
            "error should name the unknown nested field: {err}"
        );
    }

    #[test]
    fn load_rejects_wrong_type_settings() {
        let dir = tempfile::tempdir().unwrap();
        let path = temp_settings_path(&dir);
        write_sparse_settings(
            &path,
            r#"[settings.server]
heartbeatIntervalMs = "fast"
"#,
        );

        let err = load_settings_from_path(&path).unwrap_err();

        assert!(matches!(err, SettingsError::InvalidValue(_)));
        assert!(
            err.to_string().contains("expected u64"),
            "error should reject the wrong-typed field without coercion: {err}"
        );
    }

    #[test]
    fn load_zero_heartbeat_interval_returns_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = temp_settings_path(&dir);
        write_sparse_settings(
            &path,
            r#"[settings.server]
heartbeatIntervalMs = 0
"#,
        );

        let err = load_settings_from_path(&path).unwrap_err();

        assert!(matches!(err, SettingsError::InvalidValue(_)));
        assert!(err.to_string().contains("heartbeatIntervalMs"));
    }

    #[test]
    fn load_rejects_removed_policy_settings() {
        let dir = tempfile::tempdir().unwrap();
        let path = temp_settings_path(&dir);
        let section = ["guard", "rails"].concat();
        write_sparse_settings(
            &path,
            &format!(
                r#"[settings.{section}.audit]
enabled = true
maxEntries = 500
"#
            ),
        );

        let err = load_settings_from_path(&path).unwrap_err();

        assert!(matches!(err, SettingsError::InvalidValue(_)));
        assert!(err.to_string().contains(&section));
    }

    #[test]
    fn capability_policy_settings_are_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let path = temp_settings_path(&dir);
        let section = ["settings", "capabilities", "process"].join(".");
        let key = ["dangerous", "Patterns"].concat();
        write_sparse_settings(&path, &format!("[{section}]\n{key} = [\"^rm -rf /\"]\n"));

        let err = load_settings_from_path(&path).unwrap_err();
        assert!(err.to_string().contains("capabilities"));
    }

    #[test]
    fn load_validates_clamping() {
        let dir = tempfile::tempdir().unwrap();
        let path = temp_settings_path(&dir);
        write_sparse_settings(
            &path,
            r#"[settings.retry]
jitterFactor = 5.0
"#,
        );

        let settings = load_settings_from_path(&path).unwrap();
        assert!((settings.retry.jitter_factor - 1.0).abs() < f64::EPSILON);
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

    #[test]
    fn settings_env_allowlist_documents_supported_overrides() {
        assert_eq!(
            SETTINGS_ENV_ALLOWLIST,
            [
                "TRON_DEFAULT_MODEL",
                "TRON_DEFAULT_PROVIDER",
                "TRON_HEARTBEAT_INTERVAL",
                "ANTHROPIC_CLIENT_ID",
            ]
        );
    }

    #[test]
    fn apply_env_overrides_from_sets_allowlisted_values() {
        let mut settings = TronSettings::default();

        apply_env_overrides_from(&mut settings, |name| match name {
            "TRON_DEFAULT_MODEL" => Some("env-model".to_string()),
            "TRON_DEFAULT_PROVIDER" => Some("env-provider".to_string()),
            "TRON_HEARTBEAT_INTERVAL" => Some("45000".to_string()),
            "ANTHROPIC_CLIENT_ID" => Some("env-client".to_string()),
            _ => None,
        })
        .unwrap();

        assert_eq!(settings.server.default_model, "env-model");
        assert_eq!(settings.server.default_provider, "env-provider");
        assert_eq!(settings.server.heartbeat_interval_ms, 45_000);
        assert_eq!(settings.api.anthropic.client_id, "env-client");
    }

    #[test]
    fn invalid_env_override_returns_error_without_partial_mutation() {
        let mut settings = TronSettings::default();
        let original = settings.clone();

        let err = apply_env_overrides_from(&mut settings, |name| match name {
            "TRON_DEFAULT_MODEL" => Some("env-model".to_string()),
            "TRON_HEARTBEAT_INTERVAL" => Some("fast".to_string()),
            _ => None,
        })
        .unwrap_err();

        assert!(err.to_string().contains("TRON_HEARTBEAT_INTERVAL"));
        assert_eq!(settings.server.default_model, original.server.default_model);
        assert_eq!(
            settings.server.heartbeat_interval_ms,
            original.server.heartbeat_interval_ms
        );
    }
}
