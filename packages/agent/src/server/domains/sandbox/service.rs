use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde_json::Value;
use tokio::process::Child;
use tokio::sync::Mutex;
use tokio::time::{Duration, timeout};
use tracing::{debug, warn};

use crate::server::shared::errors::CapabilityError;

const CONTAINER_STATUS_TIMEOUT: Duration = Duration::from_secs(3);
const CONTAINER_COMMAND_TIMEOUT: Duration = Duration::from_secs(10);

/// In-memory process ownership for sandbox-created workers.
#[derive(Default)]
pub(crate) struct SandboxWorkerProcessStore {
    children: Mutex<HashMap<String, Child>>,
}

impl SandboxWorkerProcessStore {
    pub(crate) async fn insert(&self, worker_id: String, child: Child) {
        let _ = self.children.lock().await.insert(worker_id, child);
    }

    pub(crate) async fn kill(&self, worker_id: &str) {
        if let Some(mut child) = self.children.lock().await.remove(worker_id) {
            let _ = child.kill().await;
            let _ = child.wait().await;
        }
    }
}

pub(crate) fn containers_json_path() -> PathBuf {
    crate::core::paths::containers_path()
}

pub(crate) fn load_containers(path: &Path) -> Result<Vec<Value>, CapabilityError> {
    if !path.exists() {
        debug!("containers.json not found, returning empty list");
        return Ok(vec![]);
    }

    let content = std::fs::read_to_string(path).map_err(|error| CapabilityError::Internal {
        message: format!("Failed to read containers.json: {error}"),
    })?;
    Ok(parse_containers(&content))
}

pub(crate) fn parse_containers(content: &str) -> Vec<Value> {
    let Ok(value) = serde_json::from_str::<Value>(content) else {
        return vec![];
    };
    match value {
        Value::Array(entries) => entries,
        Value::Object(ref map) => map
            .get("containers")
            .and_then(|containers| containers.as_array())
            .cloned()
            .unwrap_or_default(),
        _ => vec![],
    }
}

pub(crate) fn remove_container_metadata_at(path: &Path, name: &str) -> Result<(), CapabilityError> {
    let content = match std::fs::read_to_string(path) {
        Ok(content) => content,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(CapabilityError::Internal {
                message: format!("Failed to read containers.json: {error}"),
            });
        }
    };

    let Ok(parsed) = serde_json::from_str::<Value>(&content) else {
        return Ok(());
    };

    let is_object_format = parsed.is_object();
    let entries = match &parsed {
        Value::Array(entries) => entries.clone(),
        Value::Object(map) => map
            .get("containers")
            .and_then(|containers| containers.as_array())
            .cloned()
            .unwrap_or_default(),
        _ => return Ok(()),
    };

    let filtered: Vec<Value> = entries
        .into_iter()
        .filter(|entry| entry.get("name").and_then(|value| value.as_str()) != Some(name))
        .collect();

    let output = if is_object_format {
        serde_json::json!({ "containers": filtered })
    } else {
        Value::Array(filtered)
    };

    let serialized =
        serde_json::to_string_pretty(&output).map_err(|error| CapabilityError::Internal {
            message: format!("Failed to serialize containers.json: {error}"),
        })?;

    std::fs::write(path, serialized).map_err(|error| CapabilityError::Internal {
        message: format!("Failed to write containers.json: {error}"),
    })
}

pub(crate) async fn query_container_statuses() -> HashMap<String, String> {
    let result = timeout(
        CONTAINER_STATUS_TIMEOUT,
        tokio::process::Command::new("container")
            .args(["list", "--all", "--format", "json"])
            .output(),
    )
    .await;

    let output = match result {
        Ok(Ok(output)) if output.status.success() => output.stdout,
        Ok(Ok(output)) => {
            let stderr = String::from_utf8_lossy(&output.stderr);
            warn!("container list failed: {stderr}");
            return HashMap::new();
        }
        Ok(Err(error)) => {
            debug!("container CLI unavailable: {error}");
            return HashMap::new();
        }
        Err(_) => {
            warn!("container list timed out");
            return HashMap::new();
        }
    };

    let Ok(parsed) = serde_json::from_slice::<Vec<Value>>(&output) else {
        return HashMap::new();
    };

    parsed
        .into_iter()
        .filter_map(|entry| {
            let name = entry.get("name")?.as_str()?.to_string();
            let status = entry.get("status")?.as_str()?.to_string();
            Some((name, status))
        })
        .collect()
}

pub(crate) async fn run_container_command(
    action: &str,
    name: &str,
) -> Result<Value, CapabilityError> {
    let output = timeout(
        CONTAINER_COMMAND_TIMEOUT,
        tokio::process::Command::new("container")
            .args([action, name])
            .output(),
    )
    .await;

    match output {
        Ok(Ok(result)) if result.status.success() => Ok(serde_json::json!({ "success": true })),
        Ok(Ok(result)) => {
            let stderr = String::from_utf8_lossy(&result.stderr);
            Err(CapabilityError::Internal {
                message: format!("container {action} failed: {stderr}"),
            })
        }
        Ok(Err(error)) if error.kind() == std::io::ErrorKind::NotFound => {
            Err(CapabilityError::NotAvailable {
                message:
                    "Container CLI not found. Install container runtime to use sandbox features."
                        .into(),
            })
        }
        Ok(Err(error)) => Err(CapabilityError::Internal {
            message: format!("Failed to execute container command: {error}"),
        }),
        Err(_) => Err(CapabilityError::Internal {
            message: format!("container {action} timed out"),
        }),
    }
}

pub(crate) async fn remove_container_runtime_best_effort(name: &str) {
    let _ = timeout(
        CONTAINER_COMMAND_TIMEOUT,
        tokio::process::Command::new("container")
            .args(["rm", name])
            .output(),
    )
    .await;
}

pub(crate) fn worker_endpoint_from_origin(origin: &str) -> String {
    let origin = origin.trim_end_matches('/');
    let websocket_origin = if let Some(rest) = origin.strip_prefix("https://") {
        format!("wss://{rest}")
    } else if let Some(rest) = origin.strip_prefix("http://") {
        format!("ws://{rest}")
    } else {
        origin.to_owned()
    };
    format!("{websocket_origin}/engine/workers")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_containers_missing_file_returns_empty() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("containers.json");

        let containers = load_containers(&path).unwrap();

        assert!(containers.is_empty());
    }

    #[test]
    fn load_containers_invalid_json_returns_empty() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("containers.json");
        std::fs::write(&path, "{broken").unwrap();

        let containers = load_containers(&path).unwrap();

        assert!(containers.is_empty());
    }

    #[test]
    fn worker_endpoint_from_origin_uses_engine_workers_path() {
        assert_eq!(
            worker_endpoint_from_origin("http://127.0.0.1:49134"),
            "ws://127.0.0.1:49134/engine/workers"
        );
        assert_eq!(
            worker_endpoint_from_origin("https://tron.local/"),
            "wss://tron.local/engine/workers"
        );
    }
}
