//! Filesystem capability service helpers.
//!
//! # INVARIANT: trusted-local trust boundary
//!
//! These low-level service helpers accept caller-supplied path strings and pass
//! them straight to `std::fs::*` with **no containment check**. The public
//! capability path performs session-working-directory containment for
//! model/session calls before any handler reaches these helpers; the helpers
//! stay raw so tests and internal callers can exercise exact host filesystem
//! behavior. That is a deliberate trade-off, not an oversight:
//!
//! * The server is assumed to be reachable only from the user's own
//!   devices via Tailscale (see the project threat-model in `README.md`
//!   and engine stream publishers).
//! * The iOS project picker must be free to browse anywhere on the host
//!   filesystem (external drives, `/etc/hosts`, sibling repos, etc.)
//!   to choose a working dir.
//!
//! If that threat model ever shifts (shared Tailnet, compromised
//! device, multi-user host), harden the service boundary itself in addition to
//! the engine grant checks — do NOT silently add an allow-list, since raw helper
//! callers expect unrestricted access and would fail without a visible
//! deprecation.
//!
//! The regression guard for this trust boundary is
//! `unrestricted_filesystem_paths_under_trusted_local` (below). If that
//! test ever needs to assert rejection instead of success, it is the
//! flip signal — DO NOT delete it silently.

use std::cmp::Ordering;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::shared::server::errors::{self, CapabilityError};

/// Debug-build-only signal that a filesystem capability received a path
/// outside the user's home directory. Emits nothing in release.
///
/// Purpose: let operator QA verify that the trusted-local trust
/// boundary is being exercised intentionally (e.g. iOS picker browsing
/// `/Volumes`) rather than via a silent path-injection bug. The signal
/// is `tracing::debug!` — it does not affect behavior.
#[cfg(debug_assertions)]
fn trace_out_of_home(path: &str, op: &'static str) {
    let home = crate::shared::paths::home_dir();
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

pub(crate) fn list_dir(path: &str, show_hidden: bool) -> Result<Value, CapabilityError> {
    trace_out_of_home(path, "list_dir");
    let entries = std::fs::read_dir(path).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            CapabilityError::NotFound {
                code: errors::FILE_NOT_FOUND.into(),
                message: format!("Directory not found: {path}"),
            }
        } else {
            CapabilityError::Custom {
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

pub(crate) fn create_dir(path: &str) -> Result<Value, CapabilityError> {
    trace_out_of_home(path, "create_dir");
    std::fs::create_dir_all(path).map_err(|error| CapabilityError::Custom {
        code: errors::FILESYSTEM_ERROR.into(),
        message: error.to_string(),
        details: None,
    })?;

    Ok(serde_json::json!({ "created": true, "path": path }))
}

pub(crate) fn read_file_bounded(
    path: &str,
    start_line: Option<u64>,
    end_line: Option<u64>,
) -> Result<Value, CapabilityError> {
    trace_out_of_home(path, "read_file");
    let content = std::fs::read_to_string(path).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            CapabilityError::NotFound {
                code: errors::FILE_NOT_FOUND.into(),
                message: format!("File not found: {path}"),
            }
        } else {
            CapabilityError::Custom {
                code: errors::FILE_ERROR.into(),
                message: error.to_string(),
                details: None,
            }
        }
    })?;

    let mut value = serde_json::json!({ "content": content, "path": path });
    if start_line.is_some() || end_line.is_some() {
        let content = value["content"].as_str().unwrap_or_default();
        let bounded = bounded_line_content(content, start_line, end_line)?;
        value["content"] = serde_json::json!(bounded);
        if let Some(start_line) = start_line {
            value["startLine"] = serde_json::json!(start_line);
        }
        if let Some(end_line) = end_line {
            value["endLine"] = serde_json::json!(end_line);
        }
    }
    Ok(value)
}

fn bounded_line_content(
    content: &str,
    start_line: Option<u64>,
    end_line: Option<u64>,
) -> Result<String, CapabilityError> {
    let start = start_line.unwrap_or(1);
    let end = end_line.unwrap_or(u64::MAX);
    if end < start {
        return Err(CapabilityError::InvalidParams {
            message: "endLine must be greater than or equal to startLine".to_owned(),
        });
    }

    let mut selected = String::new();
    for (index, line) in content.split_inclusive('\n').enumerate() {
        let line_number = u64::try_from(index)
            .ok()
            .and_then(|index| index.checked_add(1))
            .unwrap_or(u64::MAX);
        if line_number > end {
            break;
        }
        if line_number >= start {
            selected.push_str(line);
        }
    }
    Ok(selected)
}

pub(crate) fn write_file(path: &str, content: &str) -> Result<Value, CapabilityError> {
    trace_out_of_home(path, "write_file");
    if Path::new(path).parent().is_none() && path == "/" {
        return Err(CapabilityError::InvalidParams {
            message: "refusing to write to filesystem root".to_owned(),
        });
    }
    let existed = Path::new(path).exists();
    if let Some(parent) = Path::new(path).parent() {
        std::fs::create_dir_all(parent).map_err(|error| CapabilityError::Custom {
            code: errors::FILESYSTEM_ERROR.into(),
            message: error.to_string(),
            details: None,
        })?;
    }
    std::fs::write(path, content.as_bytes()).map_err(|error| CapabilityError::Custom {
        code: errors::FILE_ERROR.into(),
        message: error.to_string(),
        details: None,
    })?;
    Ok(serde_json::json!({
        "path": path,
        "bytesWritten": content.len(),
        "created": !existed,
    }))
}

pub(crate) fn edit_file(
    path: &str,
    old_string: &str,
    new_string: &str,
    replace_all: bool,
) -> Result<Value, CapabilityError> {
    trace_out_of_home(path, "edit_file");
    if old_string.is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: "oldString must not be empty".to_owned(),
        });
    }
    let content = read_text(path)?;
    let occurrences = content.matches(old_string).count();
    if occurrences == 0 {
        return Err(CapabilityError::Custom {
            code: "PATTERN_NOT_FOUND".to_owned(),
            message: "oldString was not found in the file".to_owned(),
            details: Some(serde_json::json!({"path": path})),
        });
    }
    if occurrences > 1 && !replace_all {
        return Err(CapabilityError::Custom {
            code: "MULTIPLE_OCCURRENCES".to_owned(),
            message: format!(
                "oldString matched {occurrences} times; pass replaceAll=true or make the string more specific"
            ),
            details: Some(serde_json::json!({"path": path, "occurrences": occurrences})),
        });
    }
    let updated = if replace_all {
        content.replace(old_string, new_string)
    } else {
        content.replacen(old_string, new_string, 1)
    };
    std::fs::write(path, updated.as_bytes()).map_err(|error| CapabilityError::Custom {
        code: errors::FILE_ERROR.into(),
        message: error.to_string(),
        details: None,
    })?;
    let replacements = if replace_all { occurrences } else { 1 };
    Ok(serde_json::json!({
        "path": path,
        "replacements": replacements,
        "diff": unified_diff(&content, &updated),
    }))
}

pub(crate) fn apply_patch(
    path: &str,
    old_string: &str,
    new_string: &str,
    replace_all: bool,
) -> Result<Value, CapabilityError> {
    if old_string.is_empty() {
        return append_patch(path, new_string);
    }
    edit_file(path, old_string, new_string, replace_all)
}

fn append_patch(path: &str, new_string: &str) -> Result<Value, CapabilityError> {
    trace_out_of_home(path, "apply_patch");
    if new_string.is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: "newString must not be empty when oldString is empty".to_owned(),
        });
    }
    let content = read_text(path)?;
    let updated = format!("{content}{new_string}");
    std::fs::write(path, updated.as_bytes()).map_err(|error| CapabilityError::Custom {
        code: errors::FILE_ERROR.into(),
        message: error.to_string(),
        details: None,
    })?;
    Ok(serde_json::json!({
        "path": path,
        "replacements": 1,
        "diff": unified_diff(&content, &updated),
    }))
}

pub(crate) fn diff_file(path: &str, new_content: &str) -> Result<Value, CapabilityError> {
    let content = read_text(path)?;
    Ok(serde_json::json!({
        "path": path,
        "diff": unified_diff(&content, new_content),
    }))
}

pub(crate) fn find(
    path: &str,
    pattern: &str,
    type_filter: &str,
    max_depth: Option<usize>,
    max_results: usize,
    exclude: &[String],
) -> Result<Value, CapabilityError> {
    trace_out_of_home(path, "find");
    let root = PathBuf::from(path);
    let matcher = globset::GlobBuilder::new(pattern)
        .literal_separator(false)
        .build()
        .map_err(|error| CapabilityError::InvalidParams {
            message: format!("invalid glob pattern: {error}"),
        })?
        .compile_matcher();
    let exclude_matchers = exclude
        .iter()
        .filter_map(|pattern| {
            globset::GlobBuilder::new(pattern)
                .literal_separator(false)
                .build()
                .ok()
                .map(|glob| glob.compile_matcher())
        })
        .collect::<Vec<_>>();
    let mut walker = walkdir::WalkDir::new(&root);
    if let Some(depth) = max_depth {
        walker = walker.max_depth(depth);
    }

    let mut matches = Vec::new();
    let mut truncated = false;
    for entry in walker.into_iter().filter_map(Result::ok) {
        let is_dir = entry.file_type().is_dir();
        match type_filter {
            "file" if is_dir => continue,
            "directory" if !is_dir => continue,
            _ => {}
        }
        let rel_path = entry.path().strip_prefix(&root).unwrap_or(entry.path());
        if rel_path.as_os_str().is_empty() {
            continue;
        }
        if !matcher.is_match(rel_path) && !matcher.is_match(entry.file_name()) {
            continue;
        }
        if exclude_matchers
            .iter()
            .any(|matcher| matcher.is_match(rel_path) || matcher.is_match(entry.file_name()))
        {
            continue;
        }
        if matches.len() >= max_results {
            truncated = true;
            break;
        }
        let metadata = entry.metadata().ok();
        matches.push(serde_json::json!({
            "path": rel_path.to_string_lossy(),
            "absolutePath": entry.path().to_string_lossy(),
            "isDirectory": is_dir,
            "size": metadata.as_ref().map(std::fs::Metadata::len),
        }));
    }
    Ok(serde_json::json!({
        "path": path,
        "matches": matches,
        "truncated": truncated,
    }))
}

pub(crate) fn search_text(
    path: &str,
    pattern: &str,
    file_pattern: Option<&str>,
    context: usize,
    max_results: usize,
) -> Result<Value, CapabilityError> {
    trace_out_of_home(path, "search_text");
    let regex = regex::Regex::new(pattern).map_err(|error| CapabilityError::InvalidParams {
        message: format!("invalid regex pattern: {error}"),
    })?;
    let file_matcher = match file_pattern {
        Some(pattern) => Some(
            globset::GlobBuilder::new(pattern)
                .literal_separator(false)
                .build()
                .map_err(|error| CapabilityError::InvalidParams {
                    message: format!("invalid filePattern: {error}"),
                })?
                .compile_matcher(),
        ),
        None => None,
    };
    let mut matches = Vec::new();
    let mut truncated = false;
    for entry in walkdir::WalkDir::new(path)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().is_file())
    {
        if let Some(matcher) = &file_matcher
            && !matcher.is_match(entry.path())
            && !matcher.is_match(entry.file_name())
        {
            continue;
        }
        let Ok(content) = std::fs::read_to_string(entry.path()) else {
            continue;
        };
        let lines = content.lines().collect::<Vec<_>>();
        for (index, line) in lines.iter().enumerate() {
            if !regex.is_match(line) {
                continue;
            }
            if matches.len() >= max_results {
                truncated = true;
                break;
            }
            let start = index.saturating_sub(context);
            let end = (index + context + 1).min(lines.len());
            matches.push(serde_json::json!({
                "path": entry.path().to_string_lossy(),
                "line": index + 1,
                "text": line,
                "context": lines[start..end],
            }));
        }
        if truncated {
            break;
        }
    }
    Ok(serde_json::json!({
        "path": path,
        "matches": matches,
        "truncated": truncated,
    }))
}

fn read_text(path: &str) -> Result<String, CapabilityError> {
    std::fs::read_to_string(path).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            CapabilityError::NotFound {
                code: errors::FILE_NOT_FOUND.into(),
                message: format!("File not found: {path}"),
            }
        } else {
            CapabilityError::Custom {
                code: errors::FILE_ERROR.into(),
                message: error.to_string(),
                details: None,
            }
        }
    })
}

fn unified_diff(old: &str, new: &str) -> String {
    let old_lines = old.lines().collect::<Vec<_>>();
    let new_lines = new.lines().collect::<Vec<_>>();
    let mut output = String::new();
    output.push_str("--- before\n+++ after\n");
    let max = old_lines.len().max(new_lines.len());
    for index in 0..max {
        match (old_lines.get(index), new_lines.get(index)) {
            (Some(left), Some(right)) if left == right => {
                let _ = writeln!(output, " {left}");
            }
            (Some(left), Some(right)) => {
                let _ = writeln!(output, "-{left}");
                let _ = writeln!(output, "+{right}");
            }
            (Some(left), None) => {
                let _ = writeln!(output, "-{left}");
            }
            (None, Some(right)) => {
                let _ = writeln!(output, "+{right}");
            }
            (None, None) => {}
        }
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    /// INTENT REGRESSION GUARD — C1 (trusted-local filesystem trust boundary).
    ///
    /// The three filesystem capabilities deliberately accept paths that escape
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
        let result = read_file_bounded(&traversal, None, None)
            .expect("trusted-local filesystem MUST allow traversal reads");
        assert_eq!(result["content"].as_str().unwrap(), "trusted-local");

        // list_dir also accepts traversal (picker-browse use case).
        let parent_traversal = format!("{}/..", inner.to_string_lossy());
        let listing = list_dir(&parent_traversal, false)
            .expect("trusted-local list_dir MUST allow traversal");
        let entries = listing["entries"].as_array().unwrap();
        assert!(entries.iter().any(|e| e["name"] == "secret.txt"));
    }

    #[test]
    fn read_file_supports_1_based_line_bounds() {
        let tmp = tempfile::tempdir().unwrap();
        let target = tmp.path().join("readme.md");
        std::fs::write(&target, "one\ntwo\nthree\nfour\n").unwrap();

        let result =
            read_file_bounded(target.to_str().unwrap(), Some(2), Some(3)).expect("bounded read");
        assert_eq!(result["content"], "two\nthree\n");
        assert_eq!(result["startLine"], 2);
        assert_eq!(result["endLine"], 3);
    }

    #[test]
    fn read_file_rejects_inverted_line_bounds() {
        let tmp = tempfile::tempdir().unwrap();
        let target = tmp.path().join("readme.md");
        std::fs::write(&target, "one\ntwo\n").unwrap();

        let error = read_file_bounded(target.to_str().unwrap(), Some(3), Some(2))
            .expect_err("inverted bounds rejected");
        assert!(
            error
                .to_string()
                .contains("endLine must be greater than or equal to startLine")
        );
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
