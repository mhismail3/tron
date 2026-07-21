//! Strict settings persistence.
//!
//! `SettingsStore` owns sparse user settings writes for
//! `~/.tron/settings.toml`. Reads never silently repair malformed files:
//! missing means defaults, while invalid TOML, non-object roots, and failed
//! writes are surfaced so user settings are never erased implicitly.

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

use parking_lot::Mutex;
use serde_json::{Map, Value};

use crate::domains::settings::config::storage::loader::{
    deep_merge, load_settings_from_path, read_sparse_settings_overlay,
};
use crate::domains::settings::errors::{Result, SettingsError};
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
        serde_json::to_value(settings)
            .map_err(|error| SettingsError::json("encode effective settings", error))
    }

    /// Read the sparse settings file as JSON. Missing files return `{}`.
    pub fn read_sparse_value(&self) -> Result<Value> {
        let _guard = write_lock().lock();
        self.read_sparse_settings_locked()
    }

    /// Remove sparse settings and return the resulting compiled defaults.
    pub fn reset(&self) -> Result<Value> {
        let _guard = write_lock().lock();
        self.write_settings_toml_locked(&Value::Object(Map::new()))?;
        self.load_value()
    }

    /// Merge a sparse update into the existing sparse file, validate, and write.
    pub fn update(&self, updates: Value) -> Result<()> {
        let _guard = write_lock().lock();
        let current = self.read_sparse_settings_locked()?;
        let merged = deep_merge(current, updates);
        validate_sparse_settings(&merged, &self.path)?;

        self.write_settings_toml_locked(&merged)?;
        Ok(())
    }

    /// Replace the sparse settings file with a fully validated object.
    pub fn replace_sparse_value(&self, value: Value) -> Result<()> {
        let _guard = write_lock().lock();
        validate_sparse_settings(&value, &self.path)?;
        self.write_settings_toml_locked(&value)?;
        Ok(())
    }

    /// Restore a previously read sparse settings value after a higher-level
    /// runtime reload failed.
    ///
    /// This intentionally bypasses validation because `SettingsRuntime`
    /// already rejected the invalid candidate without swapping; the caller is
    /// restoring the exact previously validated sparse value.
    pub fn restore_sparse_value_for_rollback(&self, value: Value) -> Result<()> {
        let _guard = write_lock().lock();
        ensure_object(&value)?;
        self.write_settings_toml_locked(&value)?;
        Ok(())
    }

    fn read_sparse_settings_locked(&self) -> Result<Value> {
        let value = read_sparse_settings_overlay(&self.path)?;
        ensure_object(&value)?;
        Ok(value)
    }

    fn write_settings_toml_locked(&self, value: &Value) -> Result<()> {
        ensure_object(value)?;
        if value
            .as_object()
            .is_some_and(|settings| settings.is_empty())
        {
            match std::fs::remove_file(&self.path) {
                Ok(()) => {
                    if let Some(parent) = self.path.parent() {
                        sync_parent_dir(parent)?;
                    }
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(SettingsError::Io(error)),
            }
            return Ok(());
        }
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
        let content = sparse_settings_toml(value)?;
        temp.write_all(content.as_bytes())?;
        temp.write_all(b"\n")?;
        temp.as_file_mut().sync_all()?;
        temp.persist(&self.path)
            .map_err(|error| SettingsError::Io(error.error))?;
        sync_parent_dir(parent)?;
        Ok(())
    }
}

fn sparse_settings_toml(value: &Value) -> Result<String> {
    toml::to_string_pretty(&json_to_toml_value(value)?).map_err(|error| {
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

fn validate_sparse_settings(value: &Value, _path: &Path) -> Result<()> {
    ensure_object(value)?;
    let defaults = serde_json::to_value(TronSettings::default())
        .map_err(|error| SettingsError::json("encode default settings", error))?;
    let effective = deep_merge(defaults, value.clone());
    let validated: TronSettings = serde_json::from_value(effective)
        .map_err(|error| SettingsError::json("decode effective settings", error))?;
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

    fn temp_settings_path(dir: &tempfile::TempDir) -> PathBuf {
        let home = dir.path().join(".tron");
        crate::shared::foundation::home::ensure_tron_home_at(&home).unwrap();
        crate::shared::foundation::paths::settings_path_for_home(&home)
    }

    fn sparse_settings(settings_toml: &str) -> String {
        settings_toml.to_owned()
    }

    #[test]
    fn missing_file_loads_defaults() {
        let dir = tempfile::tempdir().unwrap();
        let store = SettingsStore::new(temp_settings_path(&dir));
        let value = store.load_value().unwrap();
        assert_eq!(value["server"]["heartbeatIntervalMs"], 30_000);
    }

    #[test]
    fn update_rejects_malformed_existing_toml_and_preserves_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = temp_settings_path(&dir);
        std::fs::write(&path, "{broken").unwrap();
        let store = SettingsStore::new(&path);

        let err = store
            .update(json!({"server": {"heartbeatIntervalMs": 12345}}))
            .unwrap_err();

        assert!(err.to_string().contains("parse settings TOML"));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "{broken");
    }

    #[test]
    fn update_rejects_non_object_roots() {
        let dir = tempfile::tempdir().unwrap();
        let path = temp_settings_path(&dir);
        let store = SettingsStore::new(path);

        let err = store.replace_sparse_value(json!([])).unwrap_err();

        assert!(err.to_string().contains("root must be an object"));
    }

    #[test]
    fn update_rejects_zero_heartbeat_interval_and_preserves_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = temp_settings_path(&dir);
        let original = sparse_settings(
            r#"[server]
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
    }

    #[test]
    fn update_writes_atomically_and_loads_effective_value() {
        let dir = tempfile::tempdir().unwrap();
        let path = temp_settings_path(&dir);
        let store = SettingsStore::new(&path);

        store
            .update(json!({"server": {"heartbeatIntervalMs": 12345}}))
            .unwrap();

        let saved = store.read_sparse_value().unwrap();
        let effective = store.load_value().unwrap();
        assert_eq!(saved["server"]["heartbeatIntervalMs"], 12_345);
        assert_eq!(effective["server"]["heartbeatIntervalMs"], 12_345);
    }

    #[test]
    fn concurrent_updates_serialize_without_lost_writes() {
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
    }

    #[test]
    fn reset_removes_the_behaviorless_empty_overlay() {
        let dir = tempfile::tempdir().unwrap();
        let path = temp_settings_path(&dir);
        let store = SettingsStore::new(&path);
        store
            .update(json!({"server": {"heartbeatIntervalMs": 12345}}))
            .unwrap();

        let value = store.reset().unwrap();
        let saved = store.read_sparse_value().unwrap();

        assert_eq!(saved, json!({}));
        assert!(!path.exists());
        assert_eq!(value["server"]["heartbeatIntervalMs"], 30_000);
    }
}
