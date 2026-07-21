//! Bounded literal search across trusted-local UTF-8 files.

use std::path::Path;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::engine::Invocation;

use super::super::contract::{
    DEFAULT_TEXT_SEARCH_TIMEOUT_SECONDS, DEFAULT_TEXT_SEARCH_WALK_ENTRIES,
    MAX_TEXT_SEARCH_TIMEOUT_SECONDS, MAX_TEXT_SEARCH_WALK_ENTRIES,
};
use super::super::runtime::WorkerRuntime;
use super::support::{
    bounded_usize, require_autonomous, required_string, resolve_path, run_blocking,
};

const DEFAULT_TEXT_SEARCH_RESULTS: usize = 200;
const MAX_TEXT_SEARCH_RESULTS: usize = 1_000;
const MAX_TEXT_SEARCH_FILE_BYTES: u64 = 1_048_576;
const DEFAULT_IGNORED_SEARCH_DIRECTORIES: &[&str] = &[
    ".git",
    ".cache",
    ".build",
    ".venv",
    "Library",
    "DerivedData",
    "Pods",
    "build",
    "dist",
    "node_modules",
    "target",
    "vendor",
    "venv",
];

pub(in crate::domains::worker_kernel) async fn filesystem_search_text(
    invocation: &Invocation,
    runtime: &WorkerRuntime,
) -> Result<Value, String> {
    require_autonomous(runtime)?;
    let requested = invocation
        .payload
        .get("path")
        .and_then(Value::as_str)
        .unwrap_or(".");
    let path = resolve_path(invocation, requested)?;
    let query = required_string(&invocation.payload, "query")?;
    let max_results = bounded_usize(
        &invocation.payload,
        "maxResults",
        DEFAULT_TEXT_SEARCH_RESULTS,
        MAX_TEXT_SEARCH_RESULTS,
    );
    let max_walk_entries = bounded_usize(
        &invocation.payload,
        "maxWalkEntries",
        DEFAULT_TEXT_SEARCH_WALK_ENTRIES,
        MAX_TEXT_SEARCH_WALK_ENTRIES,
    );
    let timeout = Duration::from_secs(
        invocation
            .payload
            .get("timeoutSeconds")
            .and_then(Value::as_u64)
            .unwrap_or(DEFAULT_TEXT_SEARCH_TIMEOUT_SECONDS)
            .clamp(1, MAX_TEXT_SEARCH_TIMEOUT_SECONDS),
    );
    let include_hidden = invocation
        .payload
        .get("includeHidden")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let include_ignored_directories = invocation
        .payload
        .get("includeIgnoredDirectories")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    run_blocking("worker_kernel::filesystem_search_text", move || {
        bounded_text_search(
            &path,
            &query,
            max_results,
            max_walk_entries,
            timeout,
            include_hidden,
            include_ignored_directories,
        )
    })
    .await
}
#[allow(clippy::too_many_arguments)]
fn bounded_text_search(
    path: &Path,
    query: &str,
    max_results: usize,
    max_walk_entries: usize,
    timeout: Duration,
    include_hidden: bool,
    include_ignored_directories: bool,
) -> Result<Value, String> {
    let started = Instant::now();
    let mut matches = Vec::new();
    let mut visited_entries = 0usize;
    let mut skipped_directories = 0usize;
    let mut result_limit_reached = false;
    let mut walk_limit_reached = false;
    let mut time_limit_reached = false;
    let root = path.to_path_buf();
    let mut walker = walkdir::WalkDir::new(path)
        .follow_links(false)
        .into_iter()
        .filter_entry(|entry| {
            if entry.path() == root {
                return true;
            }
            let name = entry.file_name().to_string_lossy();
            let hidden = name.starts_with('.');
            let ignored = entry.file_type().is_dir()
                && DEFAULT_IGNORED_SEARCH_DIRECTORIES.contains(&name.as_ref());
            let include = (include_hidden || !hidden) && (include_ignored_directories || !ignored);
            if !include && entry.file_type().is_dir() {
                skipped_directories += 1;
            }
            include
        });
    'walk: loop {
        if started.elapsed() >= timeout {
            time_limit_reached = true;
            break;
        }
        let Some(entry) = walker.next() else { break };
        let Ok(entry) = entry else { continue };
        if visited_entries >= max_walk_entries {
            walk_limit_reached = true;
            break;
        }
        visited_entries += 1;
        if !entry.file_type().is_file() {
            continue;
        }
        let Ok(metadata) = entry.metadata() else {
            continue;
        };
        if metadata.len() > MAX_TEXT_SEARCH_FILE_BYTES {
            continue;
        }
        let Ok(content) = std::fs::read_to_string(entry.path()) else {
            continue;
        };
        for (index, line) in content.lines().enumerate() {
            if started.elapsed() >= timeout {
                time_limit_reached = true;
                break 'walk;
            }
            if line.contains(query) {
                matches.push(json!({"path":entry.path(),"line":index + 1,"text":line}));
                if matches.len() >= max_results {
                    result_limit_reached = true;
                    break 'walk;
                }
            }
        }
    }
    drop(walker);
    Ok(json!({
        "query": query,
        "path": path,
        "matches": matches,
        "visitedEntries": visited_entries,
        "skippedDirectories": skipped_directories,
        "resultLimitReached": result_limit_reached,
        "walkLimitReached": walk_limit_reached,
        "timeLimitReached": time_limit_reached,
        "truncated": result_limit_reached || walk_limit_reached || time_limit_reached,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounded_text_search_skips_hidden_and_heavy_directories_by_default() {
        let root = tempfile::tempdir().unwrap();
        std::fs::write(root.path().join("visible.txt"), "needle\n").unwrap();
        std::fs::create_dir_all(root.path().join(".hidden")).unwrap();
        std::fs::write(root.path().join(".hidden/secret.txt"), "needle\n").unwrap();
        std::fs::create_dir_all(root.path().join("target")).unwrap();
        std::fs::write(root.path().join("target/generated.txt"), "needle\n").unwrap();

        let result = bounded_text_search(
            root.path(),
            "needle",
            20,
            100,
            Duration::from_secs(1),
            false,
            false,
        )
        .unwrap();
        assert_eq!(result["matches"].as_array().unwrap().len(), 1);
        assert_eq!(result["skippedDirectories"], 2);
        assert_eq!(result["truncated"], false);
    }

    #[test]
    fn bounded_text_search_reports_walk_and_time_ceilings() {
        let root = tempfile::tempdir().unwrap();
        std::fs::write(root.path().join("one.txt"), "needle\n").unwrap();
        std::fs::write(root.path().join("two.txt"), "needle\n").unwrap();
        let walked = bounded_text_search(
            root.path(),
            "needle",
            20,
            1,
            Duration::from_secs(1),
            true,
            true,
        )
        .unwrap();
        assert_eq!(walked["walkLimitReached"], true);
        assert_eq!(walked["truncated"], true);
        let timed = bounded_text_search(root.path(), "needle", 20, 100, Duration::ZERO, true, true)
            .unwrap();
        assert_eq!(timed["timeLimitReached"], true);
        assert_eq!(timed["visitedEntries"], 0);
    }
}
