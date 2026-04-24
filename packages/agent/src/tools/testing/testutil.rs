//! Shared test utilities for tool implementations.
//!
//! Provides `make_ctx()`, `extract_text()`, and `MockFs` — previously
//! copy-pasted across every tool test module.

use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use crate::core::tools::{ToolResultBody, TronToolResult};
use crate::events::EventStore;
use crate::runtime::orchestrator::event_persister::EventPersister;
use async_trait::async_trait;

use crate::tools::traits::{FileSystemOps, ToolContext};

/// Build a standard test `ToolContext`.
pub fn make_ctx() -> ToolContext {
    ToolContext {
        tool_call_id: "call-1".into(),
        session_id: "sess-1".into(),
        working_directory: "/tmp".into(),
        cancellation: tokio_util::sync::CancellationToken::new(),
        subagent_depth: 0,
        subagent_max_depth: 0,
        workspace_id: None,
        output_tx: None,
        process_manager: None,
        job_manager: None,
        output_buffer_registry: None,
        event_emitter: None,
        event_persister: None,
        turn: 0,
        all_tool_names: vec![],
    }
}

/// Build a `ToolContext` backed by a real in-memory `EventPersister`.
///
/// Returns `(ctx, event_store, session_id)` so tests can assert on
/// persisted `tool.progress` events after executing the tool.
pub async fn make_ctx_with_persister() -> (ToolContext, Arc<EventStore>, String) {
    let pool = crate::events::new_in_memory(&crate::events::ConnectionConfig::default())
        .expect("Failed to create in-memory pool");
    {
        let conn = pool.get().unwrap();
        let _ = crate::events::run_migrations(&conn).unwrap();
    }
    let store = Arc::new(EventStore::new(pool));
    let session = store
        .create_session("test-model", "/tmp", Some("test"), None, None, None)
        .expect("Failed to create session");
    let persister = Arc::new(EventPersister::new(store.clone()));
    let session_id = session.session.id.clone();
    let ctx = ToolContext {
        tool_call_id: "call-1".into(),
        session_id: session_id.clone(),
        working_directory: "/tmp".into(),
        cancellation: tokio_util::sync::CancellationToken::new(),
        subagent_depth: 0,
        subagent_max_depth: 0,
        workspace_id: None,
        output_tx: None,
        process_manager: None,
        job_manager: None,
        output_buffer_registry: None,
        event_emitter: None,
        event_persister: Some(persister),
        turn: 0,
        all_tool_names: vec![],
    };
    (ctx, store, session_id)
}

/// Drain all persisted `tool.progress` events for a session.
///
/// Polls until at least one progress event has landed, then waits a short
/// grace period to collect late arrivals before returning.
pub async fn drain_progress_events(store: &EventStore, session_id: &str) -> Vec<serde_json::Value> {
    let opts = crate::events::sqlite::repositories::event::ListEventsOptions {
        limit: Some(1000),
        offset: None,
    };
    let fetch = || {
        store
            .get_events_by_session(session_id, &opts)
            .unwrap_or_default()
            .into_iter()
            .filter(|e| e.event_type == "tool.progress")
            .map(|e| {
                serde_json::from_str::<serde_json::Value>(&e.payload)
                    .unwrap_or(serde_json::Value::Null)
            })
            .collect::<Vec<_>>()
    };
    for _ in 0..40 {
        let progress = fetch();
        if !progress.is_empty() {
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            return fetch();
        }
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
    }
    vec![]
}

/// Extract the text content from a `TronToolResult`, handling both
/// `Text` and `Blocks` variants.
pub fn extract_text(result: &TronToolResult) -> String {
    match &result.content {
        ToolResultBody::Text(t) => t.clone(),
        ToolResultBody::Blocks(blocks) => blocks
            .iter()
            .filter_map(|b| match b {
                crate::core::content::ToolResultContent::Text { text } => Some(text.as_str()),
                crate::core::content::ToolResultContent::Image { .. } => None,
            })
            .collect::<Vec<_>>()
            .join(""),
    }
}

/// In-memory filesystem mock for tool tests.
///
/// Thread-safe via `Mutex` so `FileSystemOps` (which requires `Send + Sync`)
/// is satisfied. Supports builder pattern (`with_file`) for setup and
/// `read_content` for post-execution assertions.
pub struct MockFs {
    files: Mutex<HashMap<PathBuf, Vec<u8>>>,
}

impl MockFs {
    pub fn new() -> Self {
        Self {
            files: Mutex::new(HashMap::new()),
        }
    }

    /// Builder: add a file and return `self` (for chaining).
    pub fn with_file(self, path: impl Into<PathBuf>, content: impl AsRef<[u8]>) -> Self {
        let _ = self
            .files
            .lock()
            .unwrap()
            .insert(path.into(), content.as_ref().to_vec());
        self
    }

    /// Mutably add a file (used before wrapping in `Arc`).
    pub fn add_file(&mut self, path: impl Into<PathBuf>, content: impl Into<Vec<u8>>) {
        let _ = self
            .files
            .lock()
            .unwrap()
            .insert(path.into(), content.into());
    }

    /// Read file content as UTF-8 (for post-execution assertions).
    pub fn read_content(&self, path: &Path) -> Option<String> {
        self.files
            .lock()
            .unwrap()
            .get(path)
            .map(|b| String::from_utf8_lossy(b).into_owned())
    }
}

#[async_trait]
impl FileSystemOps for MockFs {
    async fn read_file(&self, path: &Path) -> Result<Vec<u8>, io::Error> {
        self.files
            .lock()
            .unwrap()
            .get(path)
            .cloned()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "file not found"))
    }

    async fn write_file(&self, path: &Path, content: &[u8]) -> Result<(), io::Error> {
        let _ = self
            .files
            .lock()
            .unwrap()
            .insert(path.to_path_buf(), content.to_vec());
        Ok(())
    }

    async fn metadata(&self, _path: &Path) -> Result<std::fs::Metadata, io::Error> {
        Err(io::Error::other("mock"))
    }

    async fn create_dir_all(&self, _path: &Path) -> Result<(), io::Error> {
        Ok(())
    }

    fn exists(&self, path: &Path) -> bool {
        self.files.lock().unwrap().contains_key(path)
    }
}
