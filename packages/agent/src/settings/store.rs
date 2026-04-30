//! Strict settings persistence.
//!
//! `SettingsStore` owns sparse user settings writes for
//! `~/.tron/system/settings.json`. Reads never silently repair malformed files:
//! missing means defaults, but invalid JSON, non-object roots, and failed
//! writes are surfaced to callers so user settings are not accidentally erased.

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

use parking_lot::Mutex;
use serde_json::{Map, Value};

use crate::settings::errors::{Result, SettingsError};
use crate::settings::loader::{deep_merge, load_settings_from_path};
use crate::settings::types::TronSettings;

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
        self.read_sparse_json_locked()
    }

    /// Reset sparse settings to `{}` and reload the global cache.
    pub fn reset(&self) -> Result<Value> {
        let _guard = write_lock().lock();
        self.write_json_locked(&Value::Object(Map::new()))?;
        crate::settings::reload_settings_from_path(&self.path)?;
        self.load_value()
    }

    /// Merge a sparse update into the existing sparse file, validate, write,
    /// and reload the global settings cache.
    pub fn update(&self, updates: Value) -> Result<()> {
        let _guard = write_lock().lock();
        let current = self.read_sparse_json_locked()?;
        let merged = deep_merge(current, updates);
        validate_sparse_settings(&merged)?;

        self.write_json_locked(&merged)?;
        crate::settings::reload_settings_from_path(&self.path)?;
        Ok(())
    }

    /// Replace the sparse settings file with a fully validated object.
    pub fn replace_sparse_value(&self, value: Value) -> Result<()> {
        let _guard = write_lock().lock();
        validate_sparse_settings(&value)?;
        self.write_json_locked(&value)?;
        crate::settings::reload_settings_from_path(&self.path)?;
        Ok(())
    }

    fn read_sparse_json_locked(&self) -> Result<Value> {
        if !self.path.exists() {
            return Ok(Value::Object(Map::new()));
        }

        let content = std::fs::read_to_string(&self.path)?;
        let value: Value = serde_json::from_str(&content)?;
        ensure_object(&value)?;
        Ok(value)
    }

    fn write_json_locked(&self, value: &Value) -> Result<()> {
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
        let content = serde_json::to_string_pretty(value)?;
        temp.write_all(content.as_bytes())?;
        temp.write_all(b"\n")?;
        temp.as_file_mut().sync_all()?;
        temp.persist(&self.path)
            .map_err(|error| SettingsError::Io(error.error))?;
        sync_parent_dir(parent)?;
        Ok(())
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

fn validate_sparse_settings(value: &Value) -> Result<()> {
    ensure_object(value)?;
    let defaults = serde_json::to_value(TronSettings::default())?;
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
        crate::settings::test_settings_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    #[test]
    fn missing_file_loads_defaults() {
        let _lock = lock_settings();
        crate::settings::reset_settings();
        let dir = tempfile::tempdir().unwrap();
        let store = SettingsStore::new(dir.path().join("settings.json"));
        let value = store.load_value().unwrap();
        assert_eq!(value["server"]["heartbeatIntervalMs"], 30_000);
        crate::settings::reset_settings();
    }

    #[test]
    fn update_rejects_malformed_existing_json_and_preserves_file() {
        let _lock = lock_settings();
        crate::settings::reset_settings();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::fs::write(&path, "{broken").unwrap();
        let store = SettingsStore::new(&path);

        let err = store
            .update(json!({"server": {"heartbeatIntervalMs": 12345}}))
            .unwrap_err();

        assert!(err.to_string().contains("parse settings JSON"));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "{broken");
        crate::settings::reset_settings();
    }

    #[test]
    fn update_rejects_non_object_roots() {
        let _lock = lock_settings();
        crate::settings::reset_settings();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::fs::write(&path, "[]").unwrap();
        let store = SettingsStore::new(path);

        let err = store.update(json!({"server": {}})).unwrap_err();

        assert!(err.to_string().contains("root must be an object"));
        crate::settings::reset_settings();
    }

    #[test]
    fn update_rejects_zero_heartbeat_interval_and_preserves_file() {
        let _lock = lock_settings();
        crate::settings::reset_settings();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        let original = json!({"server": {"defaultModel": "claude-sonnet-4-6"}});
        std::fs::write(&path, original.to_string()).unwrap();
        let store = SettingsStore::new(&path);

        let err = store
            .update(json!({"server": {"heartbeatIntervalMs": 0}}))
            .unwrap_err();

        assert!(err.to_string().contains("heartbeatIntervalMs"));
        let saved: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(saved, original);
        crate::settings::reset_settings();
    }

    #[test]
    fn update_writes_atomically_and_reloads_cache() {
        let _lock = lock_settings();
        crate::settings::reset_settings();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        let store = SettingsStore::new(&path);

        store
            .update(json!({"server": {"heartbeatIntervalMs": 12345}}))
            .unwrap();

        let saved: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(saved["server"]["heartbeatIntervalMs"], 12_345);
        assert_eq!(
            crate::settings::get_settings().server.heartbeat_interval_ms,
            12_345
        );
        crate::settings::reset_settings();
    }

    #[test]
    fn concurrent_updates_serialize_without_lost_writes() {
        let _lock = lock_settings();
        crate::settings::reset_settings();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
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
                    .update(json!({"context": {"rules": {"discoverStandaloneFiles": false}}}))
                    .unwrap();
            })
        };
        a.join().unwrap();
        b.join().unwrap();

        let saved: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(saved["server"]["heartbeatIntervalMs"], 41_000);
        assert_eq!(saved["context"]["rules"]["discoverStandaloneFiles"], false);
        crate::settings::reset_settings();
    }

    #[test]
    fn reset_writes_empty_object() {
        let _lock = lock_settings();
        crate::settings::reset_settings();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        let store = SettingsStore::new(&path);
        store
            .update(json!({"server": {"heartbeatIntervalMs": 12345}}))
            .unwrap();

        let value = store.reset().unwrap();
        let saved: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();

        assert_eq!(saved, json!({}));
        assert_eq!(value["server"]["heartbeatIntervalMs"], 30_000);
        crate::settings::reset_settings();
    }
}
