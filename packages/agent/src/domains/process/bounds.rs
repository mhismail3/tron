//! Boundary validation for host process execution.
//!
//! `process::run` is intentionally flexible, so this module owns the compensating
//! invariants that keep that flexibility bounded by active session worktree truth
//! and by an explicit child-process environment allowlist.

use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};

use serde_json::Value;

use super::Deps;
use crate::engine::Invocation;
use crate::shared::server::errors::CapabilityError;

pub(super) fn validate_read_only_process_boundaries(
    root: &Path,
    command: &str,
    cwd: &str,
) -> Result<(), CapabilityError> {
    bounded_process_path(root, cwd, "cwd")?;
    for segment in command.split([';', '&', '|']) {
        validate_read_only_segment_paths(root, segment)?;
    }
    Ok(())
}

fn validate_read_only_segment_paths(root: &Path, segment: &str) -> Result<(), CapabilityError> {
    let tokens = shellish_tokens(segment);
    let Some(command) = tokens.first().map(String::as_str) else {
        return Ok(());
    };

    for (index, token) in tokens.iter().enumerate() {
        if let Some(path) = token.strip_prefix("--git-dir=") {
            bounded_process_path(root, path, "--git-dir")?;
        }
        if let Some(path) = token.strip_prefix("--work-tree=") {
            bounded_process_path(root, path, "--work-tree")?;
        }
        if matches!(token.as_str(), "-C" | "--git-dir" | "--work-tree")
            && let Some(path) = tokens.get(index + 1)
        {
            bounded_process_path(root, path, token)?;
        }
    }

    match command {
        "cd" => {
            if let Some(path) = tokens.get(1) {
                bounded_process_path(root, path, "cd path")?;
            }
        }
        "rg" | "grep" | "egrep" | "fgrep" => {
            validate_search_command_paths(root, &tokens)?;
        }
        "sed" => {
            validate_sed_command_paths(root, &tokens)?;
        }
        "find" => {
            validate_find_command_paths(root, &tokens)?;
        }
        "cat" | "head" | "tail" | "wc" | "stat" | "file" | "du" | "df" | "ls" | "test" => {
            for token in tokens
                .iter()
                .skip(1)
                .filter(|token| !token.starts_with('-'))
            {
                if shell_token_is_operator_or_literal(token) {
                    continue;
                }
                bounded_process_path(root, token, "read_only command operand")?;
            }
        }
        _ => {}
    }
    Ok(())
}

fn validate_search_command_paths(root: &Path, tokens: &[String]) -> Result<(), CapabilityError> {
    let mut pattern_seen = false;
    let mut skip_next = false;
    for token in tokens.iter().skip(1) {
        if skip_next {
            skip_next = false;
            continue;
        }
        if token.starts_with('-') {
            if matches!(
                token.as_str(),
                "-e" | "--regexp" | "-f" | "--file" | "-g" | "--glob" | "--type" | "-t" | "-m"
            ) {
                skip_next = true;
            }
            continue;
        }
        if !pattern_seen {
            pattern_seen = true;
            continue;
        }
        bounded_process_path(root, token, "read_only search path")?;
    }
    Ok(())
}

fn validate_sed_command_paths(root: &Path, tokens: &[String]) -> Result<(), CapabilityError> {
    let mut script_seen = false;
    let mut skip_next = false;
    for token in tokens.iter().skip(1) {
        if skip_next {
            skip_next = false;
            continue;
        }
        if token.starts_with('-') {
            if matches!(token.as_str(), "-e" | "--expression") {
                skip_next = true;
                script_seen = true;
            }
            continue;
        }
        if !script_seen {
            script_seen = true;
            continue;
        }
        bounded_process_path(root, token, "read_only sed path")?;
    }
    Ok(())
}

fn validate_find_command_paths(root: &Path, tokens: &[String]) -> Result<(), CapabilityError> {
    let mut expression_started = false;
    let mut skip_next = false;
    for token in tokens.iter().skip(1) {
        if skip_next {
            skip_next = false;
            continue;
        }
        if token.starts_with('-') {
            expression_started = true;
            if matches!(
                token.as_str(),
                "-name"
                    | "-iname"
                    | "-path"
                    | "-ipath"
                    | "-regex"
                    | "-iregex"
                    | "-maxdepth"
                    | "-mindepth"
                    | "-type"
            ) {
                skip_next = true;
            }
            continue;
        }
        if expression_started {
            continue;
        }
        bounded_process_path(root, token, "read_only find path")?;
    }
    Ok(())
}

fn shellish_tokens(command: &str) -> Vec<String> {
    command
        .split(|ch: char| ch.is_whitespace() || matches!(ch, '(' | ')' | '`'))
        .map(|token| token.trim_matches(|ch: char| matches!(ch, '"' | '\'' | ',' | ':')))
        .filter(|token| !token.is_empty())
        .map(ToOwned::to_owned)
        .collect()
}

fn shell_token_is_operator_or_literal(token: &str) -> bool {
    matches!(
        token,
        "!" | "=" | "==" | "!=" | "-a" | "-o" | "-e" | "-f" | "-d" | "-r" | "-s" | "-"
    ) || token.parse::<i64>().is_ok()
        || token
            .chars()
            .all(|ch| ch.is_ascii_digit() || matches!(ch, ',' | '$' | 'p' | 'n'))
}

pub(super) fn active_session_root(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Option<PathBuf>, CapabilityError> {
    let Some(session_id) = invocation.causal_context.session_id.as_deref() else {
        return Ok(None);
    };
    let root = if let Some(worktree) = deps
        .worktree_coordinator
        .as_ref()
        .and_then(|coordinator| coordinator.effective_working_dir(session_id))
    {
        worktree
    } else {
        deps.event_store
            .get_session(session_id)
            .map_err(|error| CapabilityError::Internal {
                message: format!("load active session for process root: {error}"),
            })?
            .ok_or_else(|| CapabilityError::InvalidParams {
                message: "active session working directory is not available".to_owned(),
            })?
            .working_directory
    };
    let canonical =
        Path::new(&root)
            .canonicalize()
            .map_err(|error| CapabilityError::InvalidParams {
                message: format!("active session working directory is not available: {error}"),
            })?;
    Ok(Some(canonical))
}

pub(super) fn require_active_session_root(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<PathBuf, CapabilityError> {
    active_session_root(invocation, deps)?.ok_or_else(|| CapabilityError::InvalidParams {
        message: "process::run requires an active session worktree".to_owned(),
    })
}

pub(super) fn bounded_process_path(
    root: &Path,
    raw_path: &str,
    label: &str,
) -> Result<PathBuf, CapabilityError> {
    if raw_path.trim().is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: format!("{label} cannot be empty"),
        });
    }
    if raw_path.contains('$') {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "{label} uses shell expansion; pass a literal path inside the active session worktree"
            ),
        });
    }
    if raw_path
        .chars()
        .any(|ch| matches!(ch, '*' | '?' | '[' | ']' | '{' | '}'))
    {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "{label} uses shell glob or brace expansion; pass a literal path inside the active session worktree"
            ),
        });
    }
    if raw_path.starts_with('~') {
        return Err(CapabilityError::InvalidParams {
            message: format!("{label} must stay inside the active session worktree"),
        });
    }
    let path = Path::new(raw_path);
    let candidate = if path.is_absolute() {
        path.to_path_buf()
    } else {
        root.join(path)
    };
    bounded_candidate_path(root, &candidate, label)
}

fn bounded_candidate_path(
    root: &Path,
    candidate: &Path,
    label: &str,
) -> Result<PathBuf, CapabilityError> {
    if let Ok(canonical) = candidate.canonicalize() {
        if canonical.starts_with(root) {
            return Ok(canonical);
        }
        return Err(CapabilityError::InvalidParams {
            message: format!("{label} must stay inside the active session worktree"),
        });
    }

    let normalized = normalize_process_path(candidate)?;
    resolve_existing_process_ancestor_inside_root(root, &normalized, label)
}

fn normalize_process_path(path: &Path) -> Result<PathBuf, CapabilityError> {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Prefix(_) | Component::RootDir | Component::Normal(_) => {
                normalized.push(component.as_os_str());
            }
            Component::CurDir => {}
            Component::ParentDir => {
                if !normalized.pop() {
                    return Err(CapabilityError::InvalidParams {
                        message: "path must stay inside the active session worktree".to_owned(),
                    });
                }
            }
        }
    }
    Ok(normalized)
}

fn resolve_existing_process_ancestor_inside_root(
    root: &Path,
    normalized: &Path,
    label: &str,
) -> Result<PathBuf, CapabilityError> {
    let mut ancestor = normalized;
    loop {
        if ancestor.exists() {
            let canonical =
                ancestor
                    .canonicalize()
                    .map_err(|error| CapabilityError::InvalidParams {
                        message: format!("canonicalize {label}: {error}"),
                    })?;
            if canonical.starts_with(root) {
                let suffix = normalized.strip_prefix(ancestor).map_err(|error| {
                    CapabilityError::Internal {
                        message: format!("resolve {label} suffix: {error}"),
                    }
                })?;
                return Ok(canonical.join(suffix));
            }
            return Err(CapabilityError::InvalidParams {
                message: format!("{label} must stay inside the active session worktree"),
            });
        }
        ancestor = ancestor
            .parent()
            .ok_or_else(|| CapabilityError::InvalidParams {
                message: format!(
                    "{label} must have an existing ancestor inside the active session worktree"
                ),
            })?;
    }
}

pub(super) fn validate_process_env(env: &HashMap<String, String>) -> Result<(), CapabilityError> {
    for (key, value) in env {
        if secret_like_env_key(key) || raw_secret_like_value(value) {
            return Err(CapabilityError::InvalidParams {
                message: format!(
                    "process::run env contains secret-like value for {key}; use vault-backed secret refs instead"
                ),
            });
        }
    }
    Ok(())
}

pub(super) fn safe_process_environment() -> HashMap<String, String> {
    const ALLOWED: &[&str] = &[
        "PATH",
        "HOME",
        "USER",
        "LOGNAME",
        "SHELL",
        "TMPDIR",
        "TERM",
        "LANG",
        "LC_ALL",
        "CARGO_HOME",
        "RUSTUP_HOME",
        "DEVELOPER_DIR",
        "SDKROOT",
    ];
    ALLOWED
        .iter()
        .filter_map(|key| {
            std::env::var(key)
                .ok()
                .map(|value| ((*key).to_owned(), value))
        })
        .collect()
}

pub(super) fn secret_like_env_key(key: &str) -> bool {
    let lower = key.to_ascii_lowercase();
    [
        "secret",
        "token",
        "password",
        "passwd",
        "apikey",
        "api_key",
        "credential",
    ]
    .iter()
    .any(|needle| lower.contains(needle))
}

fn raw_secret_like_value(value: &str) -> bool {
    let trimmed = value.trim();
    trimmed.starts_with("sk-")
        || trimmed.starts_with("xox")
        || trimmed.starts_with("ghp_")
        || trimmed.starts_with("github_pat_")
}

pub(super) fn opt_env(params: Option<&Value>) -> HashMap<String, String> {
    params
        .and_then(|value| value.get("env"))
        .and_then(Value::as_object)
        .map(|map| {
            map.iter()
                .filter_map(|(key, value)| {
                    value.as_str().map(|value| (key.clone(), value.to_owned()))
                })
                .collect::<HashMap<_, _>>()
        })
        .unwrap_or_default()
}
