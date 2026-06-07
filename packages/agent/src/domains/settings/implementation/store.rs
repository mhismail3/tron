//! Strict settings persistence.
//!
//! `SettingsStore` owns sparse user settings writes for
//! `~/.tron/profiles/user/profile.toml`. Reads never silently repair malformed
//! files: missing means defaults, but invalid TOML, non-object settings roots,
//! and failed writes are surfaced to callers so user settings are not erased.

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

use parking_lot::Mutex;
use serde_json::{Map, Value};

use crate::domains::settings::errors::{Result, SettingsError};
use crate::domains::settings::loader::{
    deep_merge, load_settings_from_path, read_sparse_settings_overlay,
};
use crate::domains::settings::types::TronSettings;

static SETTINGS_WRITE_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
static SETTINGS_OPERATION_LOCK: OnceLock<Arc<tokio::sync::Mutex<()>>> = OnceLock::new();

fn write_lock() -> &'static Mutex<()> {
    SETTINGS_WRITE_LOCK.get_or_init(|| Mutex::new(()))
}

/// Settings file store with serialized atomic writes.
#[derive(Clone, Debug)]
pub struct SettingsStore {
    path: PathBuf,
}

impl SettingsStore {
    /// Create a store for a specific settings file.
    pub fn new(path: impl AsRef<Path>) -> Self {
        Self {
            path: path.as_ref().to_path_buf(),
        }
    }

    /// Path this store writes.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Serialize higher-level async settings operations that must keep runtime
    /// state and file state consistent across multiple store calls.
    pub async fn operation_lock() -> tokio::sync::OwnedMutexGuard<()> {
        SETTINGS_OPERATION_LOCK
            .get_or_init(|| Arc::new(tokio::sync::Mutex::new(())))
            .clone()
            .lock_owned()
            .await
    }

    /// Load effective settings as a JSON value.
    pub fn load_value(&self) -> Result<Value> {
        let settings = load_settings_from_path(&self.path)?;
        serde_json::to_value(settings).map_err(SettingsError::from)
    }

    /// Read the sparse settings file as JSON. Missing files return `{}`.
    pub fn read_sparse_value(&self) -> Result<Value> {
        let _guard = write_lock().lock();
        self.read_sparse_profile_settings_locked()
    }

    /// Reset sparse settings to `{}` and reload the global cache.
    pub fn reset(&self) -> Result<Value> {
        let _guard = write_lock().lock();
        self.write_profile_toml_locked(&Value::Object(Map::new()))?;
        crate::domains::settings::reload_settings_from_path(&self.path)?;
        self.load_value()
    }

    /// Merge a sparse update into the existing sparse file, validate, write,
    /// and reload the global settings cache.
    pub fn update(&self, updates: Value) -> Result<()> {
        let _guard = write_lock().lock();
        let current = self.read_sparse_profile_settings_locked()?;
        let merged = deep_merge(current, updates);
        validate_sparse_settings(&merged, &self.path)?;

        self.write_profile_toml_locked(&merged)?;
        crate::domains::settings::reload_settings_from_path(&self.path)?;
        Ok(())
    }

    /// Replace the sparse settings file with a fully validated object.
    pub fn replace_sparse_value(&self, value: Value) -> Result<()> {
        let _guard = write_lock().lock();
        validate_sparse_settings(&value, &self.path)?;
        self.write_profile_toml_locked(&value)?;
        crate::domains::settings::reload_settings_from_path(&self.path)?;
        Ok(())
    }

    /// Restore a previously read sparse settings value after a higher-level
    /// runtime reload failed.
    ///
    /// This intentionally bypasses validation because the active profile files
    /// may be the thing that failed validation. The caller must reset the
    /// in-memory settings snapshot from the last-known-good profile runtime.
    pub fn restore_sparse_value_for_rollback(&self, value: Value) -> Result<()> {
        let _guard = write_lock().lock();
        ensure_object(&value)?;
        self.write_profile_toml_locked(&value)?;
        Ok(())
    }

    fn read_sparse_profile_settings_locked(&self) -> Result<Value> {
        let value = read_sparse_settings_overlay(&self.path)?;
        ensure_object(&value)?;
        Ok(value)
    }

    fn write_profile_toml_locked(&self, value: &Value) -> Result<()> {
        ensure_object(value)?;
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let parent = self.path.parent().ok_or_else(|| {
            SettingsError::InvalidValue("settings path must have a parent directory".to_string())
        })?;

        let mut temp = tempfile::Builder::new()
            .prefix(".settings.")
            .suffix(".tmp")
            .tempfile_in(parent)?;
        let content = sparse_settings_profile_toml(value)?;
        temp.write_all(content.as_bytes())?;
        temp.write_all(b"\n")?;
        temp.as_file_mut().sync_all()?;
        temp.persist(&self.path)
            .map_err(|error| SettingsError::Io(error.error))?;
        sync_parent_dir(parent)?;
        Ok(())
    }
}

fn sparse_settings_profile_toml(value: &Value) -> Result<String> {
    let mut table = toml::value::Table::new();
    table.insert(
        "version".to_string(),
        toml::Value::String(crate::shared::profile::CURRENT_PROFILE_VERSION.to_string()),
    );
    table.insert(
        "name".to_string(),
        toml::Value::String(crate::shared::profile::USER_PROFILE.to_string()),
    );
    table.insert("managed".to_string(), toml::Value::Boolean(false));
    table.insert(
        "profileClass".to_string(),
        toml::Value::String("custom".to_string()),
    );
    table.insert("inherits".to_string(), toml::Value::Array(Vec::new()));
    table.insert(
        "authProfile".to_string(),
        toml::Value::String(crate::shared::profile::DEFAULT_AUTH_PROFILE.to_string()),
    );
    if value.as_object().is_some_and(|object| !object.is_empty()) {
        table.insert("settings".to_string(), json_to_toml_value(value)?);
    }
    toml::to_string_pretty(&toml::Value::Table(table)).map_err(|error| {
        SettingsError::InvalidValue(format!("failed to encode settings TOML: {error}"))
    })
}

fn json_to_toml_value(value: &Value) -> Result<toml::Value> {
    match value {
        Value::Null => Err(SettingsError::InvalidValue(
            "settings TOML cannot encode null values".to_string(),
        )),
        Value::Bool(value) => Ok(toml::Value::Boolean(*value)),
        Value::Number(value) => {
            if let Some(value) = value.as_i64() {
                Ok(toml::Value::Integer(value))
            } else if let Some(value) = value.as_u64() {
                let value = i64::try_from(value).map_err(|_| {
                    SettingsError::InvalidValue(format!(
                        "settings integer {value} exceeds TOML integer range"
                    ))
                })?;
                Ok(toml::Value::Integer(value))
            } else if let Some(value) = value.as_f64() {
                Ok(toml::Value::Float(value))
            } else {
                Err(SettingsError::InvalidValue(
                    "settings number cannot be represented in TOML".to_string(),
                ))
            }
        }
        Value::String(value) => Ok(toml::Value::String(value.clone())),
        Value::Array(values) => values
            .iter()
            .filter(|value| !value.is_null())
            .map(json_to_toml_value)
            .collect::<Result<Vec<_>>>()
            .map(toml::Value::Array),
        Value::Object(values) => {
            let mut table = toml::value::Table::new();
            for (key, value) in values {
                if value.is_null() {
                    continue;
                }
                table.insert(key.clone(), json_to_toml_value(value)?);
            }
            Ok(toml::Value::Table(table))
        }
    }
}

fn ensure_object(value: &Value) -> Result<()> {
    if value.is_object() {
        Ok(())
    } else {
        Err(SettingsError::InvalidValue(
            "settings JSON root must be an object".to_string(),
        ))
    }
}

fn validate_sparse_settings(value: &Value, path: &Path) -> Result<()> {
    ensure_object(value)?;
    let defaults =
        serde_json::to_value(crate::domains::settings::loader::load_settings_defaults_for(path)?)?;
    let effective = deep_merge(defaults, value.clone());
    let validated: TronSettings = serde_json::from_value(effective)?;
    validated.validate_strict()?;
    Ok(())
}

#[cfg(unix)]
fn sync_parent_dir(parent: &Path) -> Result<()> {
    let dir = std::fs::File::open(parent)?;
    dir.sync_all()?;
    Ok(())
}

#[cfg(not(unix))]
fn sync_parent_dir(_parent: &Path) -> Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn lock_settings() -> std::sync::MutexGuard<'static, ()> {
        crate::domains::settings::test_settings_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn temp_settings_path(dir: &tempfile::TempDir) -> PathBuf {
        let home = dir.path().join(".tron");
        crate::shared::constitution::ensure_tron_home_at(&home).unwrap();
        home.join(crate::shared::paths::dirs::PROFILES)
            .join(crate::shared::profile::USER_PROFILE)
            .join(crate::shared::paths::files::PROFILE_TOML)
    }

    fn sparse_profile(settings_toml: &str) -> String {
        format!(
            r#"version = "2"
name = "user"
managed = false
profileClass = "custom"
inherits = []
authProfile = "default"

{settings_toml}
"#
        )
    }

    #[test]
    fn missing_file_loads_defaults() {
        let _lock = lock_settings();
        crate::domains::settings::reset_settings();
        let dir = tempfile::tempdir().unwrap();
        let store = SettingsStore::new(temp_settings_path(&dir));
        let value = store.load_value().unwrap();
        assert_eq!(value["server"]["heartbeatIntervalMs"], 30_000);
        crate::domains::settings::reset_settings();
    }

    #[test]
    fn update_rejects_malformed_existing_toml_and_preserves_file() {
        let _lock = lock_settings();
        crate::domains::settings::reset_settings();
        let dir = tempfile::tempdir().unwrap();
        let path = temp_settings_path(&dir);
        std::fs::write(&path, "{broken").unwrap();
        let store = SettingsStore::new(&path);

        let err = store
            .update(json!({"server": {"heartbeatIntervalMs": 12345}}))
            .unwrap_err();

        assert!(err.to_string().contains("parse settings TOML"));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "{broken");
        crate::domains::settings::reset_settings();
    }

    #[test]
    fn update_rejects_non_object_roots() {
        let _lock = lock_settings();
        crate::domains::settings::reset_settings();
        let dir = tempfile::tempdir().unwrap();
        let path = temp_settings_path(&dir);
        std::fs::write(&path, "settings = []\n").unwrap();
        let store = SettingsStore::new(path);

        let err = store.update(json!({"server": {}})).unwrap_err();

        assert!(err.to_string().contains("root must be an object"));
        crate::domains::settings::reset_settings();
    }

    #[test]
    fn update_rejects_zero_heartbeat_interval_and_preserves_file() {
        let _lock = lock_settings();
        crate::domains::settings::reset_settings();
        let dir = tempfile::tempdir().unwrap();
        let path = temp_settings_path(&dir);
        let original = sparse_profile(
            r#"[settings.server]
defaultModel = "claude-sonnet-4-6"
"#,
        );
        std::fs::write(&path, &original).unwrap();
        let store = SettingsStore::new(&path);

        let err = store
            .update(json!({"server": {"heartbeatIntervalMs": 0}}))
            .unwrap_err();

        assert!(err.to_string().contains("heartbeatIntervalMs"));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
        crate::domains::settings::reset_settings();
    }

    #[test]
    fn update_writes_atomically_and_reloads_cache() {
        let _lock = lock_settings();
        crate::domains::settings::reset_settings();
        let dir = tempfile::tempdir().unwrap();
        let path = temp_settings_path(&dir);
        let store = SettingsStore::new(&path);

        store
            .update(json!({"server": {"heartbeatIntervalMs": 12345}}))
            .unwrap();

        let saved = store.read_sparse_value().unwrap();
        assert_eq!(saved["server"]["heartbeatIntervalMs"], 12_345);
        assert_eq!(
            crate::domains::settings::get_settings()
                .server
                .heartbeat_interval_ms,
            12_345
        );
        crate::domains::settings::reset_settings();
    }

    #[test]
    fn concurrent_updates_serialize_without_lost_writes() {
        let _lock = lock_settings();
        crate::domains::settings::reset_settings();
        let dir = tempfile::tempdir().unwrap();
        let path = temp_settings_path(&dir);
        let store = SettingsStore::new(&path);

        let a = {
            let store = store.clone();
            std::thread::spawn(move || {
                store
                    .update(json!({"server": {"heartbeatIntervalMs": 41_000}}))
                    .unwrap();
            })
        };
        let b = {
            let store = store.clone();
            std::thread::spawn(move || {
                store
                    .update(json!({"context": {"compactor": {"preserveRecentCount": 8}}}))
                    .unwrap();
            })
        };
        a.join().unwrap();
        b.join().unwrap();

        let saved = store.read_sparse_value().unwrap();
        assert_eq!(saved["server"]["heartbeatIntervalMs"], 41_000);
        assert_eq!(saved["context"]["compactor"]["preserveRecentCount"], 8);
        crate::domains::settings::reset_settings();
    }

    #[test]
    fn reset_writes_empty_object() {
        let _lock = lock_settings();
        crate::domains::settings::reset_settings();
        let dir = tempfile::tempdir().unwrap();
        let path = temp_settings_path(&dir);
        let store = SettingsStore::new(&path);
        store
            .update(json!({"server": {"heartbeatIntervalMs": 12345}}))
            .unwrap();

        let value = store.reset().unwrap();
        let saved = store.read_sparse_value().unwrap();

        assert_eq!(saved, json!({}));
        assert_eq!(value["server"]["heartbeatIntervalMs"], 30_000);
        crate::domains::settings::reset_settings();
    }
}
