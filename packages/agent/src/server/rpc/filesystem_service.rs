//! Filesystem RPC service helpers.
//!
//! # INVARIANT: trusted-local trust boundary
//!
//! `list_dir`, `create_dir`, and `read_file` accept caller-supplied path
//! strings and pass them straight to `std::fs::*` with **no containment
//! check**. That is a deliberate trade-off, not an oversight:
//!
//! * The server is assumed to be reachable only from the user's own
//!   devices via Tailscale (see the project threat-model in `README.md`
//!   and [`crate::server::websocket::broadcast`]).
//! * The iOS project picker must be free to browse anywhere on the host
//!   filesystem (external drives, `/etc/hosts`, sibling repos, etc.)
//!   to choose a working dir.
//!
//! If that threat model ever shifts (shared Tailnet, compromised
//! device, multi-user host), introduce a `validate_user_path(path)`
//! gate and route the three handlers through it — do NOT silently add
//! an allow-list, since every existing caller expects unrestricted
//! access and would fail without a visible deprecation.
//!
//! The regression guard for this trust boundary is
//! `unrestricted_filesystem_paths_under_trusted_local` (below). If that
//! test ever needs to assert rejection instead of success, it is the
//! flip signal — DO NOT delete it silently.

use std::cmp::Ordering;
use std::path::Path;

use serde_json::Value;

use crate::server::rpc::errors::{self, RpcError};

/// Debug-build-only signal that a filesystem handler received a path
/// outside the user's home directory. Emits nothing in release.
///
/// Purpose: let operator QA verify that the trusted-local trust
/// boundary is being exercised intentionally (e.g. iOS picker browsing
/// `/Volumes`) rather than via a silent path-injection bug. The signal
/// is `tracing::debug!` — it does not affect behavior.
#[cfg(debug_assertions)]
fn trace_out_of_home(path: &str, op: &'static str) {
    let home = crate::core::paths::home_dir();
    let resolved = std::fs::canonicalize(path)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| path.to_string());
    if !resolved.starts_with(&home) {
        tracing::debug!(
            path = %path,
            resolved = %resolved,
            op,
            "filesystem handler invoked on path outside $HOME (trusted-local boundary)"
        );
    }
}

#[cfg(not(debug_assertions))]
#[inline(always)]
fn trace_out_of_home(_path: &str, _op: &'static str) {}

pub(crate) fn list_dir(path: &str, show_hidden: bool) -> Result<Value, RpcError> {
    trace_out_of_home(path, "list_dir");
    let entries = std::fs::read_dir(path).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            RpcError::NotFound {
                code: errors::FILE_NOT_FOUND.into(),
                message: format!("Directory not found: {path}"),
            }
        } else {
            RpcError::Custom {
                code: errors::FILESYSTEM_ERROR.into(),
                message: error.to_string(),
                details: None,
            }
        }
    })?;

    let mut items: Vec<Value> = entries
        .filter_map(std::result::Result::ok)
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().to_string();
            if !show_hidden && name.starts_with('.') {
                return None;
            }

            let file_type = entry.file_type().ok()?;
            let is_dir = file_type.is_dir();
            let is_symlink = file_type.is_symlink();
            let entry_path = format!("{path}/{name}");

            let mut item = serde_json::json!({
                "name": name,
                "path": entry_path,
                "isDirectory": is_dir,
                "isSymlink": is_symlink,
            });

            if !is_dir && let Ok(metadata) = entry.metadata() {
                item["size"] = serde_json::json!(metadata.len());
                if let Ok(modified) = metadata.modified() {
                    let datetime: chrono::DateTime<chrono::Utc> = modified.into();
                    item["modifiedAt"] = serde_json::json!(datetime.to_rfc3339());
                }
            }

            Some(item)
        })
        .collect();

    items.sort_by(|left, right| {
        let left_dir = left["isDirectory"].as_bool().unwrap_or(false);
        let right_dir = right["isDirectory"].as_bool().unwrap_or(false);
        match (left_dir, right_dir) {
            (true, false) => Ordering::Less,
            (false, true) => Ordering::Greater,
            _ => {
                let left_name = left["name"].as_str().unwrap_or("");
                let right_name = right["name"].as_str().unwrap_or("");
                left_name.to_lowercase().cmp(&right_name.to_lowercase())
            }
        }
    });

    let parent = Path::new(&path)
        .parent()
        .map(|parent| parent.to_string_lossy().to_string());

    Ok(serde_json::json!({
        "path": path,
        "parent": parent,
        "entries": items,
    }))
}

pub(crate) fn get_home(home: &str) -> Value {
    let mut suggested = Vec::new();
    for name in &[
        "Desktop",
        "Documents",
        "Projects",
        "Workspace",
        "Developer",
        "Code",
    ] {
        let path = format!("{home}/{name}");
        if Path::new(&path).is_dir() {
            suggested.push(serde_json::json!({
                "name": name,
                "path": path,
                "exists": true,
            }));
        }
    }

    serde_json::json!({
        "homePath": home,
        "suggestedPaths": suggested,
    })
}

pub(crate) fn create_dir(path: &str) -> Result<Value, RpcError> {
    trace_out_of_home(path, "create_dir");
    std::fs::create_dir_all(path).map_err(|error| RpcError::Custom {
        code: errors::FILESYSTEM_ERROR.into(),
        message: error.to_string(),
        details: None,
    })?;

    Ok(serde_json::json!({ "created": true, "path": path }))
}

pub(crate) fn read_file(path: &str) -> Result<Value, RpcError> {
    trace_out_of_home(path, "read_file");
    let content = std::fs::read_to_string(path).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            RpcError::NotFound {
                code: errors::FILE_NOT_FOUND.into(),
                message: format!("File not found: {path}"),
            }
        } else {
            RpcError::Custom {
                code: errors::FILE_ERROR.into(),
                message: error.to_string(),
                details: None,
            }
        }
    })?;

    Ok(serde_json::json!({ "content": content, "path": path }))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// INTENT REGRESSION GUARD — C1 (trusted-local filesystem trust boundary).
    ///
    /// The three filesystem handlers deliberately accept paths that escape
    /// the user's home directory. This test writes a file to a temp dir,
    /// then reads it back via a `../` traversal from a sibling subdir to
    /// prove that containment is NOT enforced.
    ///
    /// If the threat model changes and containment is added, **flip this
    /// test to assert rejection — do not delete it**. A silently-deleted
    /// green test would look identical to a hardening win while masking a
    /// capability loss (iOS picker would stop working).
    #[test]
    fn unrestricted_filesystem_paths_under_trusted_local() {
        let tmp = tempfile::tempdir().unwrap();
        let target = tmp.path().join("secret.txt");
        std::fs::write(&target, "trusted-local").unwrap();

        let inner = tmp.path().join("inner");
        std::fs::create_dir(&inner).unwrap();

        // Traversal path: <tmp>/inner/../secret.txt — path containment
        // would reject this. Trusted-local allows it.
        let traversal = format!("{}/../secret.txt", inner.to_string_lossy());
        let result = read_file(&traversal)
            .expect("trusted-local filesystem MUST allow traversal reads");
        assert_eq!(result["content"].as_str().unwrap(), "trusted-local");

        // list_dir also accepts traversal (picker-browse use case).
        let parent_traversal = format!("{}/..", inner.to_string_lossy());
        let listing = list_dir(&parent_traversal, false)
            .expect("trusted-local list_dir MUST allow traversal");
        let entries = listing["entries"].as_array().unwrap();
        assert!(entries.iter().any(|e| e["name"] == "secret.txt"));
    }

    /// `trace_out_of_home` is logging-only and must never panic or
    /// mutate handler behavior, even on empty / malformed paths.
    #[cfg(debug_assertions)]
    #[test]
    fn trace_out_of_home_is_side_effect_free() {
        trace_out_of_home("", "probe");
        trace_out_of_home("///../..", "probe");
        trace_out_of_home("/nonexistent/path", "probe");
    }
}
