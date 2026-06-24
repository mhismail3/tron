//! Canonical path helpers for grant file-root policy.

use std::path::{Component, Path, PathBuf};

use crate::engine::kernel::errors::{EngineError, Result};

pub(super) fn root_allows_path(root: &str, path: &Path) -> Result<bool> {
    let canonical_root = canonical_payload_path(root)?;
    Ok(path.starts_with(canonical_root))
}

pub(super) fn canonical_payload_path(path: impl AsRef<Path>) -> Result<PathBuf> {
    let candidate = path.as_ref();
    let display = candidate.display();
    if candidate.exists() {
        return candidate.canonicalize().map_err(|error| {
            EngineError::PolicyViolation(format!("canonicalize file path {display}: {error}"))
        });
    }
    let absolute = if candidate.is_absolute() {
        candidate.to_path_buf()
    } else {
        std::env::current_dir()
            .map_err(|error| EngineError::HandlerFailed(format!("read current dir: {error}")))?
            .join(candidate)
    };
    let mut ancestor = absolute.as_path();
    while !ancestor.exists() {
        ancestor = ancestor.parent().ok_or_else(|| {
            EngineError::PolicyViolation(format!("file path {display} has no existing ancestor"))
        })?;
    }
    let canonical_ancestor = ancestor.canonicalize().map_err(|error| {
        EngineError::PolicyViolation(format!("canonicalize file path ancestor: {error}"))
    })?;
    let suffix = absolute
        .strip_prefix(ancestor)
        .unwrap_or_else(|_| Path::new(""));
    Ok(normalize_suffix(&canonical_ancestor, suffix))
}

fn normalize_suffix(canonical_ancestor: &Path, suffix: &Path) -> PathBuf {
    let mut normalized = canonical_ancestor.to_path_buf();
    for component in suffix.components() {
        match component {
            Component::CurDir => {}
            Component::Normal(part) => normalized.push(part),
            Component::ParentDir => {
                normalized.pop();
            }
            Component::RootDir | Component::Prefix(_) => {}
        }
    }
    normalized
}
