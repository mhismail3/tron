use std::collections::HashMap;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::process::Child;
use tokio::sync::Mutex;
use tokio::time::{Duration, timeout};
use tracing::{debug, warn};

use crate::shared::server::errors::CapabilityError;

const CONTAINER_STATUS_TIMEOUT: Duration = Duration::from_secs(3);
const CONTAINER_COMMAND_TIMEOUT: Duration = Duration::from_secs(10);

/// In-memory process ownership for sandbox-created workers.
#[derive(Default)]
pub(crate) struct SandboxWorkerProcessStore {
    processes: Mutex<HashMap<String, SandboxWorkerProcess>>,
}

struct SandboxWorkerProcess {
    record: SandboxWorkerRecord,
    child: Option<Child>,
}

/// Metadata for one sandbox-created local worker process.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SandboxWorkerRecord {
    pub(crate) worker_id: String,
    pub(crate) process_id: Option<u32>,
    pub(crate) command: String,
    pub(crate) args: Vec<String>,
    pub(crate) working_directory: Option<String>,
    pub(crate) visibility: String,
    pub(crate) session_id: Option<String>,
    pub(crate) workspace_id: Option<String>,
    pub(crate) expected_function_ids: Vec<String>,
    pub(crate) registered_function_ids: Vec<String>,
    pub(crate) catalog_revision: u64,
    pub(crate) worker_endpoint: String,
    pub(crate) status: String,
    pub(crate) started_at: DateTime<Utc>,
    pub(crate) stopped_at: Option<DateTime<Utc>>,
    pub(crate) last_error: Option<String>,
}

impl SandboxWorkerProcessStore {
    pub(crate) async fn insert(&self, record: SandboxWorkerRecord, child: Child) {
        let _ = self.processes.lock().await.insert(
            record.worker_id.clone(),
            SandboxWorkerProcess {
                record,
                child: Some(child),
            },
        );
    }

    pub(crate) async fn list(&self) -> Vec<SandboxWorkerRecord> {
        self.processes
            .lock()
            .await
            .values()
            .map(|process| process.record.clone())
            .collect()
    }

    pub(crate) async fn get(&self, worker_id: &str) -> Option<SandboxWorkerRecord> {
        self.processes
            .lock()
            .await
            .get(worker_id)
            .map(|process| process.record.clone())
    }

    pub(crate) async fn kill(&self, worker_id: &str) -> Option<SandboxWorkerRecord> {
        self.stop(worker_id, Some("killed")).await
    }

    pub(crate) async fn stop(
        &self,
        worker_id: &str,
        reason: Option<&str>,
    ) -> Option<SandboxWorkerRecord> {
        let mut process = self.processes.lock().await.remove(worker_id)?;
        if let Some(mut child) = process.child.take() {
            if let Err(error) = child.kill().await {
                process.record.last_error = Some(format!("failed to kill process: {error}"));
            }
            if let Err(error) = child.wait().await {
                process.record.last_error = Some(format!("failed to wait for process: {error}"));
            }
        }
        process.record.status = "stopped".to_owned();
        process.record.stopped_at = Some(Utc::now());
        if let Some(reason) = reason {
            process.record.last_error = process
                .record
                .last_error
                .or_else(|| Some(reason.to_owned()));
        }
        let record = process.record.clone();
        let _ = self.processes.lock().await.insert(
            worker_id.to_owned(),
            SandboxWorkerProcess {
                record: record.clone(),
                child: None,
            },
        );
        Some(record)
    }
}

pub(crate) fn containers_json_path() -> PathBuf {
    crate::shared::paths::containers_path()
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

    #[tokio::test]
    async fn sandbox_worker_process_store_tracks_and_stops_metadata() {
        let store = SandboxWorkerProcessStore::default();
        let child = tokio::process::Command::new("sleep")
            .arg("30")
            .spawn()
            .expect("sleep process should spawn");
        let record = SandboxWorkerRecord {
            worker_id: "sandbox-worker-a".to_owned(),
            process_id: child.id(),
            command: "sleep".to_owned(),
            args: vec!["30".to_owned()],
            working_directory: None,
            visibility: "session".to_owned(),
            session_id: Some("session-a".to_owned()),
            workspace_id: None,
            expected_function_ids: vec!["demo::echo".to_owned()],
            registered_function_ids: vec!["demo::echo".to_owned()],
            catalog_revision: 7,
            worker_endpoint: "ws://127.0.0.1:49134/engine/workers".to_owned(),
            status: "running".to_owned(),
            started_at: Utc::now(),
            stopped_at: None,
            last_error: None,
        };

        store.insert(record.clone(), child).await;
        assert_eq!(store.list().await, vec![record.clone()]);
        assert_eq!(store.get("sandbox-worker-a").await, Some(record));

        let stopped = store
            .stop("sandbox-worker-a", Some("test stop"))
            .await
            .expect("worker process record should exist");
        assert_eq!(stopped.status, "stopped");
        assert_eq!(stopped.last_error.as_deref(), Some("test stop"));
        assert!(stopped.stopped_at.is_some());
        assert_eq!(
            store.get("sandbox-worker-a").await.unwrap().status,
            "stopped"
        );
    }
}
