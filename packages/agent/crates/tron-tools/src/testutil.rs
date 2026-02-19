//! Shared test utilities for tool implementations.
//!
//! Provides `make_ctx()`, `extract_text()`, and `MockFs` — previously
//! copy-pasted across every tool test module.

use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use async_trait::async_trait;
use tron_core::tools::{ToolResultBody, TronToolResult};

use crate::traits::{FileSystemOps, ToolContext};

/// Build a standard test `ToolContext`.
pub fn make_ctx() -> ToolContext {
    ToolContext {
        tool_call_id: "call-1".into(),
        session_id: "sess-1".into(),
        working_directory: "/tmp".into(),
        cancellation: tokio_util::sync::CancellationToken::new(),
        subagent_depth: 0,
        subagent_max_depth: 0,
    }
}

/// Extract the text content from a `TronToolResult`, handling both
/// `Text` and `Blocks` variants.
pub fn extract_text(result: &TronToolResult) -> String {
    match &result.content {
        ToolResultBody::Text(t) => t.clone(),
        ToolResultBody::Blocks(blocks) => blocks
            .iter()
            .filter_map(|b| match b {
                tron_core::content::ToolResultContent::Text { text } => Some(text.as_str()),
                _ => None,
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
        Err(io::Error::new(io::ErrorKind::Other, "mock"))
    }

    async fn create_dir_all(&self, _path: &Path) -> Result<(), io::Error> {
        Ok(())
    }

    fn exists(&self, path: &Path) -> bool {
        self.files.lock().unwrap().contains_key(path)
    }
}
