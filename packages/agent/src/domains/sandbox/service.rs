use std::collections::HashMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tokio::process::Child;
use tokio::sync::Mutex;
use url::Url;

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

pub(crate) fn worker_endpoint_from_origin(origin: &str) -> String {
    let origin = origin.trim().trim_end_matches('/');
    let websocket_origin = if let Some(rest) = origin.strip_prefix("https://") {
        format!("wss://{rest}")
    } else if let Some(rest) = origin.strip_prefix("http://") {
        format!("ws://{rest}")
    } else if origin.starts_with("ws://") || origin.starts_with("wss://") {
        origin.to_owned()
    } else {
        format!("ws://{origin}")
    };
    match Url::parse(&websocket_origin) {
        Ok(mut url) => {
            url.set_path("/engine/workers");
            url.set_query(None);
            url.set_fragment(None);
            url.to_string()
        }
        Err(_) => format!("{websocket_origin}/engine/workers"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn worker_endpoint_from_origin_uses_engine_workers_path() {
        assert_eq!(
            worker_endpoint_from_origin("http://127.0.0.1:49134"),
            "ws://127.0.0.1:49134/engine/workers"
        );
        assert_eq!(
            worker_endpoint_from_origin("localhost:9847"),
            "ws://localhost:9847/engine/workers"
        );
        assert_eq!(
            worker_endpoint_from_origin("https://tron.local/"),
            "wss://tron.local/engine/workers"
        );
        assert_eq!(
            worker_endpoint_from_origin("ws://127.0.0.1:9847/engine"),
            "ws://127.0.0.1:9847/engine/workers"
        );
        assert_eq!(
            worker_endpoint_from_origin("wss://tron.local/engine/workers"),
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
