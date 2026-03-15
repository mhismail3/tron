use std::path::Path;

use serde_json::Value;

use crate::server::rpc::errors::RpcError;

pub(crate) fn load_settings_value(path: &Path) -> Result<Value, RpcError> {
    let settings = crate::settings::load_settings_from_path(path).unwrap_or_default();
    serde_json::to_value(settings).map_err(|error| RpcError::Internal {
        message: error.to_string(),
    })
}

pub(crate) fn update_settings(path: &Path, updates: Value) -> Result<(), RpcError> {
    let current = read_settings_json(path)?;
    let merged = crate::settings::deep_merge(current, updates);
    write_settings_json(path, &merged)?;
    crate::settings::reload_settings_from_path(path);
    Ok(())
}

fn read_settings_json(path: &Path) -> Result<Value, RpcError> {
    if !path.exists() {
        return Ok(Value::Object(serde_json::Map::default()));
    }

    let content = std::fs::read_to_string(path).map_err(|error| RpcError::Internal {
        message: format!("Failed to read settings: {error}"),
    })?;

    Ok(serde_json::from_str::<Value>(&content)
        .unwrap_or_else(|_| Value::Object(serde_json::Map::default())))
}

fn write_settings_json(path: &Path, value: &Value) -> Result<(), RpcError> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| RpcError::Internal {
            message: format!("Failed to create settings directory: {error}"),
        })?;
    }

    let content = serde_json::to_string_pretty(value).map_err(|error| RpcError::Internal {
        message: error.to_string(),
    })?;
    std::fs::write(path, content).map_err(|error| RpcError::Internal {
        message: format!("Failed to write settings: {error}"),
    })?;
    Ok(())
}

#[cfg(test)]
pub(crate) fn settings_reload_lock() -> &'static tokio::sync::Mutex<()> {
    use std::sync::OnceLock;

    static LOCK: OnceLock<tokio::sync::Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| tokio::sync::Mutex::new(()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn load_settings_value_missing_file_returns_defaults() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");

        let settings = load_settings_value(&path).unwrap();

        assert!(settings["server"].is_object());
        assert!(settings["context"].is_object());
    }

    #[tokio::test]
    async fn update_settings_treats_invalid_existing_json_as_empty_object() {
        let _guard = settings_reload_lock().lock().await;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::fs::write(&path, "{broken").unwrap();

        update_settings(&path, json!({"theme": "dark"})).unwrap();

        let saved: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(saved["theme"], "dark");
    }
}
