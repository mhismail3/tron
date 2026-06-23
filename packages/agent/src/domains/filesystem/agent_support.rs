//! Shared helpers for the filesystem agent toolbox.

use std::fs;
use std::io::Read;
use std::path::{Component, Path, PathBuf};

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{
    EngineResource, EngineResourceScope, EngineResourceVersion, Invocation,
    RUNTIME_METADATA_WORKING_DIRECTORY,
};
use crate::shared::server::errors::CapabilityError;

pub(super) const SCHEMA_VERSION: &str = "tron.filesystem_agent_tools.v1";
pub(super) const PATCH_PROPOSAL_KIND: &str = "patch_proposal";
pub(super) const PATCH_PROPOSAL_SCHEMA_ID: &str = "tron.resource.patch_proposal.v1";
pub(super) const MATERIALIZED_FILE_KIND: &str = "materialized_file";
pub(super) const MATERIALIZED_FILE_SCHEMA_ID: &str = "tron.resource.materialized_file.v1";
pub(super) const DEFAULT_READ_BYTES: usize = 64 * 1024;
pub(super) const MAX_READ_BYTES: usize = 256 * 1024;
pub(super) const MAX_WRITE_BYTES: usize = 512 * 1024;
pub(super) const DEFAULT_DIFF_BYTES: usize = 64 * 1024;
pub(super) const MAX_DIFF_BYTES: usize = 128 * 1024;
pub(super) const DEFAULT_RESULTS: usize = 100;
pub(super) const MAX_RESULTS: usize = 1_000;
pub(super) const MAX_WALK_ENTRIES: usize = 10_000;
pub(super) const MAX_LINE_PREVIEW: usize = 300;

#[derive(Clone)]
pub(super) struct ResolvedPath {
    pub(super) root: PathBuf,
    pub(super) canonical: PathBuf,
    pub(super) relative: String,
}

#[derive(Clone)]
pub(super) struct FileSnapshot {
    pub(super) exists: bool,
    pub(super) is_binary: bool,
    pub(super) size_bytes: u64,
    pub(super) content_hash: Option<String>,
    pub(super) text: Option<String>,
    pub(super) truncated: bool,
}

#[derive(Clone)]
pub(super) struct MutationPlan {
    pub(super) path: ResolvedPath,
    pub(super) commit: bool,
    pub(super) reason: Option<String>,
    pub(super) before: FileSnapshot,
    pub(super) after_content: String,
    pub(super) after_hash: String,
    pub(super) diff: String,
    pub(super) diff_truncated: bool,
}

pub(super) fn resolve_payload_path(
    invocation: &Invocation,
    payload: &Value,
    allow_missing: bool,
) -> Result<ResolvedPath, CapabilityError> {
    let root = working_root(invocation)?;
    resolve_path(&root, required_str(payload, "path")?, allow_missing)
}

pub(super) fn working_root(invocation: &Invocation) -> Result<PathBuf, CapabilityError> {
    let raw = invocation
        .causal_context
        .runtime_metadata(RUNTIME_METADATA_WORKING_DIRECTORY)
        .ok_or_else(|| invalid("filesystem tools require trusted working directory metadata"))?;
    crate::shared::foundation::paths::normalize_working_directory(raw).map_err(internal)
}

pub(super) fn resolve_path(
    root: &Path,
    raw: &str,
    allow_missing: bool,
) -> Result<ResolvedPath, CapabilityError> {
    let raw = raw.trim();
    if raw.is_empty() {
        return Err(invalid("path must not be empty"));
    }
    let requested = Path::new(raw);
    if requested.is_absolute() {
        return Err(invalid("filesystem tool paths must be relative"));
    }
    let mut clean = PathBuf::new();
    for component in requested.components() {
        match component {
            Component::CurDir => {}
            Component::Normal(part) => clean.push(part),
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                return Err(invalid("filesystem tool paths must not escape the root"));
            }
        }
    }
    let candidate = if clean.as_os_str().is_empty() {
        root.to_path_buf()
    } else {
        root.join(clean)
    };
    let canonical = canonicalize_candidate(&candidate, allow_missing)?;
    if !canonical.starts_with(root) {
        return Err(invalid(format!(
            "path escapes authorized root: {}",
            requested.display()
        )));
    }
    let relative = relative_to(root, &canonical);
    Ok(ResolvedPath {
        root: root.to_path_buf(),
        canonical,
        relative: if relative.is_empty() {
            ".".to_owned()
        } else {
            relative
        },
    })
}

fn canonicalize_candidate(path: &Path, allow_missing: bool) -> Result<PathBuf, CapabilityError> {
    if path.exists() {
        return path
            .canonicalize()
            .map_err(|error| map_io_error(error, path));
    }
    if !allow_missing {
        return Err(not_found(path));
    }
    let mut missing = Vec::new();
    let mut ancestor = path;
    while !ancestor.exists() {
        let name = ancestor
            .file_name()
            .ok_or_else(|| invalid("path has no existing ancestor"))?;
        missing.push(name.to_os_string());
        ancestor = ancestor
            .parent()
            .ok_or_else(|| invalid("path has no existing ancestor"))?;
    }
    let mut canonical = ancestor
        .canonicalize()
        .map_err(|error| map_io_error(error, ancestor))?;
    for part in missing.iter().rev() {
        canonical.push(part);
    }
    Ok(canonical)
}

pub(super) fn read_snapshot(
    path: &Path,
    max_bytes: usize,
) -> Result<FileSnapshot, CapabilityError> {
    let metadata = fs::symlink_metadata(path).map_err(|error| map_io_error(error, path))?;
    if !metadata.is_file() {
        return Err(invalid(format!("path is not a file: {}", path.display())));
    }
    let size_bytes = metadata.len();
    let mut file = fs::File::open(path).map_err(|error| map_io_error(error, path))?;
    let mut bytes = Vec::new();
    file.by_ref()
        .take(u64::try_from(max_bytes.saturating_add(1)).unwrap_or(u64::MAX))
        .read_to_end(&mut bytes)
        .map_err(|error| map_io_error(error, path))?;
    let truncated = bytes.len() > max_bytes || size_bytes > u64::try_from(max_bytes).unwrap();
    bytes.truncate(max_bytes);
    let is_binary = bytes.contains(&0) || std::str::from_utf8(&bytes).is_err();
    let text = if is_binary {
        None
    } else {
        Some(String::from_utf8(bytes.clone()).map_err(|error| invalid(error.to_string()))?)
    };
    let content_hash = if truncated {
        None
    } else {
        Some(sha256_hex(&bytes))
    };
    Ok(FileSnapshot {
        exists: true,
        is_binary,
        size_bytes,
        content_hash,
        text,
        truncated,
    })
}

pub(super) fn snapshot_value(snapshot: &FileSnapshot, include_content: bool) -> Value {
    json!({
        "exists": snapshot.exists,
        "isBinary": snapshot.is_binary,
        "sizeBytes": snapshot.size_bytes,
        "contentHash": snapshot.content_hash,
        "truncated": snapshot.truncated,
        "content": if include_content { snapshot.text.clone().map(Value::String).unwrap_or(Value::Null) } else { Value::Null },
        "preview": snapshot.text.as_deref().map(|text| truncate_chars(text, DEFAULT_READ_BYTES))
    })
}

pub(super) fn entry_value(root: &Path, path: &Path) -> Value {
    let metadata = fs::symlink_metadata(path).ok();
    let is_symlink = metadata
        .as_ref()
        .is_some_and(|metadata| metadata.file_type().is_symlink());
    let canonical = path.canonicalize().ok();
    let authorized = canonical
        .as_ref()
        .is_some_and(|path| path.starts_with(root));
    let target_metadata = if authorized {
        fs::metadata(path).ok()
    } else {
        None
    };
    json!({
        "name": path.file_name().and_then(|name| name.to_str()).unwrap_or_default(),
        "relativePath": relative_to(root, path),
        "isDirectory": target_metadata.as_ref().is_some_and(fs::Metadata::is_dir),
        "isFile": target_metadata.as_ref().is_some_and(fs::Metadata::is_file),
        "isSymlink": is_symlink,
        "authorized": authorized,
        "sizeBytes": target_metadata.as_ref().filter(|m| m.is_file()).map(fs::Metadata::len)
    })
}

pub(super) fn unified_diff(
    relative_path: &str,
    before: Option<&str>,
    after: &str,
    before_binary: bool,
    max_bytes: usize,
) -> (String, bool) {
    let mut diff = format!("--- a/{relative_path}\n+++ b/{relative_path}\n@@\n");
    if before_binary {
        diff.push_str("-<binary content omitted>\n");
    } else if let Some(before) = before {
        for line in before.lines() {
            diff.push('-');
            diff.push_str(line);
            diff.push('\n');
            if diff.len() > max_bytes {
                diff.truncate(max_bytes);
                return (diff, true);
            }
        }
    } else {
        diff.push_str("-<missing>\n");
    }
    for line in after.lines() {
        diff.push('+');
        diff.push_str(line);
        diff.push('\n');
        if diff.len() > max_bytes {
            diff.truncate(max_bytes);
            return (diff, true);
        }
    }
    (diff, false)
}

pub(super) fn resource_scope(invocation: &Invocation) -> EngineResourceScope {
    if let Some(session_id) = &invocation.causal_context.session_id {
        EngineResourceScope::Session(session_id.clone())
    } else if let Some(workspace_id) = &invocation.causal_context.workspace_id {
        EngineResourceScope::Workspace(workspace_id.clone())
    } else {
        EngineResourceScope::System
    }
}

pub(super) fn current_version(
    versions: &[EngineResourceVersion],
    resource: &EngineResource,
) -> Result<EngineResourceVersion, CapabilityError> {
    let current = resource
        .current_version_id
        .as_ref()
        .ok_or_else(|| internal("resource has no current version"))?;
    versions
        .iter()
        .find(|version| &version.version_id == current)
        .cloned()
        .ok_or_else(|| internal("resource current version is missing"))
}

pub(super) fn path_value(path: &ResolvedPath) -> Value {
    json!({
        "root": "working_directory",
        "relativePath": path.relative
    })
}

pub(super) fn resource_ref(resource: &EngineResource, role: &str) -> Value {
    json!({
        "role": role,
        "kind": resource.kind,
        "resourceId": resource.resource_id,
        "versionId": resource.current_version_id,
        "schemaId": resource.schema_id,
        "lifecycle": resource.lifecycle
    })
}

pub(super) fn version_ref(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    role: &str,
) -> Value {
    json!({
        "role": role,
        "kind": resource.kind,
        "resourceId": resource.resource_id,
        "versionId": version.version_id,
        "schemaId": resource.schema_id,
        "lifecycle": resource.lifecycle,
        "contentHash": version.content_hash
    })
}

pub(super) fn materialized_file_resource_id(path: &Path) -> String {
    format!(
        "materialized_file:{}",
        sha256_hex(path.to_string_lossy().as_bytes())
    )
}

pub(super) fn relative_to(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .unwrap_or(path)
        .to_string_lossy()
        .trim_start_matches('/')
        .to_owned()
}

pub(super) fn path_has_hidden_component(relative: &str) -> bool {
    relative.split('/').any(|part| part.starts_with('.'))
}

pub(super) fn wildcard_match(pattern: &str, text: &str) -> bool {
    fn inner(pattern: &[u8], text: &[u8]) -> bool {
        match (pattern.first(), text.first()) {
            (None, None) => true,
            (None, Some(_)) => false,
            (Some(b'*'), _) => {
                inner(&pattern[1..], text) || (!text.is_empty() && inner(pattern, &text[1..]))
            }
            (Some(b'?'), Some(_)) => inner(&pattern[1..], &text[1..]),
            (Some(a), Some(b)) if a == b => inner(&pattern[1..], &text[1..]),
            _ => false,
        }
    }
    inner(pattern.as_bytes(), text.as_bytes())
}

pub(super) fn truncate_chars(value: &str, max: usize) -> String {
    if value.len() <= max {
        return value.to_owned();
    }
    let mut end = max;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_owned()
}

pub(super) fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

pub(super) fn required_str<'a>(
    payload: &'a Value,
    field: &str,
) -> Result<&'a str, CapabilityError> {
    optional_str(payload, field)?.ok_or_else(|| invalid(format!("{field} is required")))
}

pub(super) fn optional_str<'a>(
    payload: &'a Value,
    field: &str,
) -> Result<Option<&'a str>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if !value.trim().is_empty() => Ok(Some(value)),
        Some(Value::String(_)) => Err(invalid(format!("{field} must not be empty"))),
        Some(_) => Err(invalid(format!("{field} must be a string"))),
    }
}

pub(super) fn optional_bool(payload: &Value, field: &str) -> Result<Option<bool>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(value)) => Ok(Some(*value)),
        Some(_) => Err(invalid(format!("{field} must be a boolean"))),
    }
}

pub(super) fn optional_usize(
    payload: &Value,
    field: &str,
) -> Result<Option<usize>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(value)) => value
            .as_u64()
            .and_then(|value| usize::try_from(value).ok())
            .filter(|value| *value > 0)
            .map(Some)
            .ok_or_else(|| invalid(format!("{field} must be a positive integer"))),
        Some(_) => Err(invalid(format!("{field} must be a positive integer"))),
    }
}

pub(super) fn map_io_error(error: std::io::Error, path: &Path) -> CapabilityError {
    if error.kind() == std::io::ErrorKind::NotFound {
        return not_found(path);
    }
    CapabilityError::Custom {
        code: "FILESYSTEM_ERROR".to_owned(),
        message: format!("{}: {error}", path.display()),
        details: None,
    }
}

pub(super) fn not_found(path: &Path) -> CapabilityError {
    CapabilityError::NotFound {
        code: "FILESYSTEM_NOT_FOUND".to_owned(),
        message: format!("filesystem path not found: {}", path.display()),
    }
}

pub(super) fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}

pub(super) fn internal(message: impl Into<String>) -> CapabilityError {
    CapabilityError::Internal {
        message: message.into(),
    }
}
