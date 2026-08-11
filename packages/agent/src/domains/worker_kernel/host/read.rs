//! Bounded trusted-local file reads and directory listing.

use std::collections::BTreeMap;
use std::fs::File;
use std::io::Read;

use serde_json::{Value, json};

use crate::engine::Invocation;

use super::super::runtime::WorkerRuntime;
use super::support::{
    MAX_FILE_BYTES, bounded_usize, decode_bounded_utf8, required_string, resolve_path, run_blocking,
};

const DEFAULT_FILE_READ_BYTES: usize = 262_144;
const DEFAULT_DIRECTORY_RESULTS: usize = 500;
const MAX_DIRECTORY_RESULTS: usize = 5_000;
const DEFAULT_DIRECTORY_WALK_ENTRIES: usize = 10_000;
const MAX_DIRECTORY_WALK_ENTRIES: usize = 50_000;

pub(crate) async fn filesystem_read(
    invocation: &Invocation,
    _runtime: &WorkerRuntime,
) -> Result<Value, String> {
    let path = resolve_path(invocation, &required_string(&invocation.payload, "path")?)?;
    let max_bytes = bounded_usize(
        &invocation.payload,
        "maxBytes",
        DEFAULT_FILE_READ_BYTES,
        MAX_FILE_BYTES,
    );
    run_blocking("worker_kernel::filesystem_read", move || {
        let file =
            File::open(&path).map_err(|error| format!("read {}: {error}", path.display()))?;
        let declared_bytes = file.metadata().ok().map(|metadata| metadata.len());
        let mut bytes = Vec::with_capacity(max_bytes.saturating_add(1));
        file.take(max_bytes.saturating_add(1) as u64)
            .read_to_end(&mut bytes)
            .map_err(|error| format!("read {}: {error}", path.display()))?;
        let truncated =
            bytes.len() > max_bytes || declared_bytes.is_some_and(|size| size > max_bytes as u64);
        bytes.truncate(max_bytes);
        let content = decode_bounded_utf8(bytes, truncated, &path)?;
        Ok(json!({
            "path": path,
            "content": content,
            "bytes": declared_bytes,
            "retainedBytes": content.len(),
            "truncated": truncated,
        }))
    })
    .await
}
pub(crate) async fn filesystem_list(
    invocation: &Invocation,
    _runtime: &WorkerRuntime,
) -> Result<Value, String> {
    let requested = invocation
        .payload
        .get("path")
        .and_then(Value::as_str)
        .unwrap_or(".");
    let path = resolve_path(invocation, requested)?;
    let max_results = bounded_usize(
        &invocation.payload,
        "maxResults",
        DEFAULT_DIRECTORY_RESULTS,
        MAX_DIRECTORY_RESULTS,
    );
    let max_walk_entries = bounded_usize(
        &invocation.payload,
        "maxWalkEntries",
        DEFAULT_DIRECTORY_WALK_ENTRIES,
        MAX_DIRECTORY_WALK_ENTRIES,
    );
    run_blocking("worker_kernel::filesystem_list", move || {
        let directory = std::fs::read_dir(&path)
            .map_err(|error| format!("list {}: {error}", path.display()))?;
        let mut entries = BTreeMap::<String, Value>::new();
        let mut visited_entries = 0usize;
        let mut walk_limit_reached = false;
        let mut result_limit_reached = false;
        for entry in directory {
            if visited_entries >= max_walk_entries {
                walk_limit_reached = true;
                break;
            }
            visited_entries += 1;
            let Ok(entry) = entry else { continue };
            let name = entry.file_name().to_string_lossy().into_owned();
            let file_type = entry.file_type().ok();
            let metadata = entry.metadata().ok();
            let _ = entries.insert(
                name.clone(),
                json!({
                    "name": name,
                    "path": entry.path(),
                    "isDirectory": file_type.as_ref().is_some_and(std::fs::FileType::is_dir),
                    "isFile": file_type.as_ref().is_some_and(std::fs::FileType::is_file),
                    "isSymbolicLink": file_type.as_ref().is_some_and(std::fs::FileType::is_symlink),
                    "size": metadata.as_ref().map(std::fs::Metadata::len),
                }),
            );
            if entries.len() > max_results {
                result_limit_reached = true;
                let _ = entries.pop_last();
            }
        }
        Ok(json!({
            "path": path,
            "entries": entries.into_values().collect::<Vec<_>>(),
            "visitedEntries": visited_entries,
            "resultLimitReached": result_limit_reached,
            "walkLimitReached": walk_limit_reached,
            "truncated": result_limit_reached || walk_limit_reached,
        }))
    })
    .await
}
