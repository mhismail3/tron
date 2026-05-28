//! filesystem domain worker.
//!
//! This module owns canonical function execution for the filesystem namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//!
//! Model/session paths are resolved against trusted engine runtime metadata for
//! the active session working directory and must remain inside that directory
//! before reaching the raw service helpers.
//! `filesystem::apply_patch` owns both exact replacement and explicit append
//! semantics: `oldString == ""` appends `newString` exactly so the model-facing
//! execute orchestrator can normalize append requests without first probing a
//! guaranteed-failing replacement.
//! Directory discovery stays bounded at the target contract (`maxResults`),
//! while the execute orchestrator owns harmless alias normalization such as
//! `maxEntries`.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

use crate::domains::filesystem::service as filesystem_service;
use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;
use crate::engine::invocation::RUNTIME_METADATA_WORKING_DIRECTORY;
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, FunctionId, Invocation, TraceId,
};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::opt_bool;
use crate::shared::server::params::opt_string;
use crate::shared::server::params::opt_u64;
use crate::shared::server::params::require_string_param;
use serde_json::Value;
use std::path::{Component, Path, PathBuf};

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::worker::domain_worker_module(
            "filesystem",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

pub(crate) mod service;

fn resolve_invocation_path(invocation: &Invocation, path: &str) -> Result<String, CapabilityError> {
    let Some(working_directory) = invocation
        .causal_context
        .runtime_metadata(RUNTIME_METADATA_WORKING_DIRECTORY)
        .filter(|value| !value.trim().is_empty())
    else {
        return Ok(path.to_owned());
    };

    let root = std::fs::canonicalize(working_directory).map_err(|error| {
        CapabilityError::InvalidParams {
            message: format!("active working directory is not available: {error}"),
        }
    })?;
    let requested = Path::new(path);
    let candidate = if requested.is_absolute() {
        requested.to_path_buf()
    } else {
        root.join(requested)
    };
    let bounded = path_inside_working_directory(&root, &candidate, path)?;
    Ok(bounded.to_string_lossy().into_owned())
}

fn path_inside_working_directory(
    root: &Path,
    candidate: &Path,
    original: &str,
) -> Result<PathBuf, CapabilityError> {
    if let Ok(canonical) = candidate.canonicalize() {
        if canonical.starts_with(root) {
            return Ok(canonical);
        }
        return Err(path_outside_working_directory(original));
    }

    let normalized = normalize_path(candidate)?;
    if !normalized.starts_with(root) {
        return Err(path_outside_working_directory(original));
    }
    ensure_existing_ancestor_inside_root(root, &normalized, original)?;
    Ok(normalized)
}

fn normalize_path(path: &Path) -> Result<PathBuf, CapabilityError> {
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
                        message: "path must stay inside the active working directory".to_owned(),
                    });
                }
            }
        }
    }
    Ok(normalized)
}

fn ensure_existing_ancestor_inside_root(
    root: &Path,
    normalized: &Path,
    original: &str,
) -> Result<(), CapabilityError> {
    let mut ancestor = normalized;
    loop {
        if ancestor.exists() {
            let canonical =
                ancestor
                    .canonicalize()
                    .map_err(|error| CapabilityError::InvalidParams {
                        message: format!("canonicalize path ancestor: {error}"),
                    })?;
            if canonical.starts_with(root) {
                return Ok(());
            }
            return Err(path_outside_working_directory(original));
        }
        ancestor = ancestor
            .parent()
            .ok_or_else(|| CapabilityError::InvalidParams {
                message: "path must have an existing ancestor inside the active working directory"
                    .to_owned(),
            })?;
    }
}

fn path_outside_working_directory(path: &str) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: format!("path `{path}` is outside the active working directory"),
    }
}

async fn filesystem_list_dir_value(
    invocation: &Invocation,
    _deps: &Deps,
) -> Result<Value, CapabilityError> {
    let params = Some(&invocation.payload);
    let home = crate::shared::paths::home_dir();
    let path = match opt_string(params, "path") {
        Some(path) => resolve_invocation_path(invocation, &path)?,
        None => invocation
            .causal_context
            .runtime_metadata(RUNTIME_METADATA_WORKING_DIRECTORY)
            .map(ToOwned::to_owned)
            .unwrap_or(home),
    };
    let show_hidden = opt_bool(params, "showHidden").unwrap_or(false);
    let max_results = usize::try_from(opt_u64(params, "maxResults", 500))
        .unwrap_or(500)
        .min(10_000);
    run_blocking_task("filesystem::list_dir", move || {
        filesystem_service::list_dir(&path, show_hidden, max_results)
    })
    .await
}

async fn filesystem_get_home_value(_deps: &Deps) -> Result<Value, CapabilityError> {
    let home = crate::shared::paths::home_dir();
    run_blocking_task("filesystem::get_home", move || {
        Ok(filesystem_service::get_home(&home))
    })
    .await
}

async fn file_read_value(invocation: &Invocation, _deps: &Deps) -> Result<Value, CapabilityError> {
    let params = Some(&invocation.payload);
    let path = require_string_param(params, "path")?;
    let start_line = optional_line_bound(params, "startLine")?;
    let end_line = optional_line_bound(params, "endLine")?;
    let path = resolve_invocation_path(invocation, &path)?;
    run_blocking_task("filesystem::read_file", move || {
        filesystem_service::read_file_bounded(&path, start_line, end_line)
    })
    .await
}

fn optional_line_bound(params: Option<&Value>, key: &str) -> Result<Option<u64>, CapabilityError> {
    let Some(value) = params.and_then(|params| params.get(key)) else {
        return Ok(None);
    };
    let Some(number) = value.as_u64() else {
        return Err(CapabilityError::InvalidParams {
            message: format!("{key} must be a positive integer"),
        });
    };
    if number == 0 {
        return Err(CapabilityError::InvalidParams {
            message: format!("{key} must be 1 or greater"),
        });
    }
    Ok(Some(number))
}

async fn filesystem_write_file_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let params = Some(&invocation.payload);
    let path = require_string_param(params, "path")?;
    let path = resolve_invocation_path(invocation, &path)?;
    let content = require_string_param(params, "content")?;
    let mut value = run_blocking_task("filesystem::write_file", move || {
        filesystem_service::write_file(&path, &content)
    })
    .await?;
    attach_materialized_file_ref(deps, invocation, &mut value, "updated").await?;
    Ok(value)
}

async fn filesystem_edit_file_value(
    invocation: &Invocation,
    deps: &Deps,
    role: &str,
) -> Result<Value, CapabilityError> {
    let params = Some(&invocation.payload);
    let path = require_string_param(params, "path")?;
    let path = resolve_invocation_path(invocation, &path)?;
    let path_for_ref = path.clone();
    let old_string = require_string_param(params, "oldString")?;
    let new_string = require_string_param(params, "newString")?;
    let replace_all = opt_bool(params, "replaceAll").unwrap_or(false);
    let mut value = run_blocking_task("filesystem::edit_file", move || {
        filesystem_service::edit_file(&path, &old_string, &new_string, replace_all)
    })
    .await?;
    let path_for_ref = value["path"]
        .as_str()
        .map(str::to_owned)
        .unwrap_or(path_for_ref);
    attach_patch_and_materialized_file_refs(deps, invocation, &mut value, &path_for_ref, role)
        .await?;
    Ok(value)
}

async fn filesystem_apply_patch_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let params = Some(&invocation.payload);
    let path = require_string_param(params, "path")?;
    let path = resolve_invocation_path(invocation, &path)?;
    let path_for_ref = path.clone();
    let old_string = require_string_param(params, "oldString")?;
    let new_string = require_string_param(params, "newString")?;
    let replace_all = opt_bool(params, "replaceAll").unwrap_or(false);
    let mut value = run_blocking_task("filesystem::apply_patch", move || {
        filesystem_service::apply_patch(&path, &old_string, &new_string, replace_all)
    })
    .await?;
    let path_for_ref = value["path"]
        .as_str()
        .map(str::to_owned)
        .unwrap_or(path_for_ref);
    attach_patch_and_materialized_file_refs(
        deps,
        invocation,
        &mut value,
        &path_for_ref,
        "applied_patch",
    )
    .await?;
    Ok(value)
}

async fn attach_materialized_file_ref(
    deps: &Deps,
    invocation: &Invocation,
    value: &mut Value,
    role: &str,
) -> Result<(), CapabilityError> {
    let path =
        value
            .get("path")
            .and_then(Value::as_str)
            .ok_or_else(|| CapabilityError::Internal {
                message: "filesystem mutation result missing path".to_owned(),
            })?;
    let content = if std::path::Path::new(path).is_dir() {
        String::new()
    } else {
        std::fs::read_to_string(path).map_err(|error| CapabilityError::Internal {
            message: format!("read materialized filesystem output: {error}"),
        })?
    };
    let result = invoke_resource_capability(
        deps,
        invocation,
        "materialized_file::update",
        serde_json::json!({
            "path": path,
            "content": content,
        }),
    )
    .await?;
    let refs = result
        .get("resourceRefs")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .map(|mut resource_ref| {
            resource_ref["role"] = serde_json::json!(role);
            resource_ref
        })
        .collect::<Vec<_>>();
    value["resourceRefs"] = Value::Array(refs);
    Ok(())
}

async fn attach_patch_and_materialized_file_refs(
    deps: &Deps,
    invocation: &Invocation,
    value: &mut Value,
    path: &str,
    role: &str,
) -> Result<(), CapabilityError> {
    attach_materialized_file_ref(deps, invocation, value, "updated_file").await?;
    let patch = invoke_resource_capability(
        deps,
        invocation,
        "patch::propose",
        serde_json::json!({
            "targetPath": path,
            "diff": value.get("diff").cloned().unwrap_or_else(|| serde_json::json!("")),
        }),
    )
    .await?;
    let mut refs = value
        .get("resourceRefs")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if let Some(patch_refs) = patch.get("resourceRefs").and_then(Value::as_array) {
        refs.extend(patch_refs.iter().cloned().map(|mut resource_ref| {
            resource_ref["role"] = serde_json::json!(role);
            resource_ref
        }));
    }
    value["resourceRefs"] = Value::Array(refs);
    Ok(())
}

async fn invoke_resource_capability(
    deps: &Deps,
    parent: &Invocation,
    function_id: &str,
    payload: Value,
) -> Result<Value, CapabilityError> {
    let mut causal = CausalContext::new(
        ActorId::new("system:filesystem").map_err(engine_capability_error)?,
        ActorKind::System,
        AuthorityGrantId::new("engine-system").map_err(engine_capability_error)?,
        TraceId::new(parent.causal_context.trace_id.as_str()).map_err(engine_capability_error)?,
    )
    .with_parent_invocation(parent.id.clone())
    .with_scope("resource.write")
    .with_idempotency_key(format!("{}:{}", parent.id.as_str(), function_id));
    if let Some(session_id) = &parent.causal_context.session_id {
        causal = causal.with_session_id(session_id.clone());
    }
    if let Some(workspace_id) = &parent.causal_context.workspace_id {
        causal = causal.with_workspace_id(workspace_id.clone());
    }
    let result = deps
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new(function_id).map_err(engine_capability_error)?,
            payload,
            causal,
        ))
        .await;
    if let Some(error) = result.error {
        return Err(engine_capability_error(error));
    }
    result.value.ok_or_else(|| CapabilityError::Internal {
        message: format!("{function_id} returned no value"),
    })
}

fn engine_capability_error(error: impl std::fmt::Display) -> CapabilityError {
    CapabilityError::Custom {
        code: "ENGINE_RESOURCE_MATERIALIZATION_FAILED".to_owned(),
        message: error.to_string(),
        details: None,
    }
}

async fn filesystem_diff_value(
    invocation: &Invocation,
    _deps: &Deps,
) -> Result<Value, CapabilityError> {
    let params = Some(&invocation.payload);
    let path = require_string_param(params, "path")?;
    let path = resolve_invocation_path(invocation, &path)?;
    let new_content = require_string_param(params, "newContent")?;
    run_blocking_task("filesystem::diff", move || {
        filesystem_service::diff_file(&path, &new_content)
    })
    .await
}

async fn filesystem_find_value(
    invocation: &Invocation,
    _deps: &Deps,
) -> Result<Value, CapabilityError> {
    let params = Some(&invocation.payload);
    let home = crate::shared::paths::home_dir();
    let path = match opt_string(params, "path") {
        Some(path) => resolve_invocation_path(invocation, &path)?,
        None => invocation
            .causal_context
            .runtime_metadata(RUNTIME_METADATA_WORKING_DIRECTORY)
            .map(ToOwned::to_owned)
            .unwrap_or(home),
    };
    let pattern = require_string_param(params, "pattern")?;
    let type_filter = opt_string(params, "type").unwrap_or_else(|| "all".to_owned());
    let max_depth = match opt_u64(params, "maxDepth", 0) {
        0 => None,
        value => usize::try_from(value).ok(),
    };
    let max_results = usize::try_from(opt_u64(params, "maxResults", 200)).unwrap_or(200);
    let exclude = params
        .and_then(|value| value.get("exclude"))
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(ToOwned::to_owned)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    run_blocking_task("filesystem::find", move || {
        filesystem_service::find(
            &path,
            &pattern,
            &type_filter,
            max_depth,
            max_results.min(10_000),
            &exclude,
        )
    })
    .await
}

async fn filesystem_search_text_value(
    invocation: &Invocation,
    _deps: &Deps,
) -> Result<Value, CapabilityError> {
    let params = Some(&invocation.payload);
    let home = crate::shared::paths::home_dir();
    let path = match opt_string(params, "path") {
        Some(path) => resolve_invocation_path(invocation, &path)?,
        None => invocation
            .causal_context
            .runtime_metadata(RUNTIME_METADATA_WORKING_DIRECTORY)
            .map(ToOwned::to_owned)
            .unwrap_or(home),
    };
    let pattern = require_string_param(params, "pattern")?;
    let file_pattern = opt_string(params, "filePattern");
    let context = usize::try_from(opt_u64(params, "context", 0))
        .unwrap_or(0)
        .min(20);
    let max_results = usize::try_from(opt_u64(params, "maxResults", 100))
        .unwrap_or(100)
        .min(10_000);
    run_blocking_task("filesystem::search_text", move || {
        filesystem_service::search_text(
            &path,
            &pattern,
            file_pattern.as_deref(),
            context,
            max_results,
        )
    })
    .await
}

async fn filesystem_create_dir_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let params = Some(&invocation.payload);
    let path = require_string_param(params, "path")?;
    let path = resolve_invocation_path(invocation, &path)?;
    let mut value = run_blocking_task("filesystem::create_dir", move || {
        filesystem_service::create_dir(&path)
    })
    .await?;
    attach_materialized_file_ref(deps, invocation, &mut value, "created_directory").await?;
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn test_invocation(working_directory: Option<&str>) -> Invocation {
        test_invocation_with_payload(
            "filesystem::read_file",
            json!({"path": "README.md"}),
            working_directory,
        )
    }

    fn test_invocation_with_payload(
        function_id: &str,
        payload: Value,
        working_directory: Option<&str>,
    ) -> Invocation {
        let mut causal = CausalContext::new(
            ActorId::new("agent:test").expect("actor id"),
            ActorKind::Agent,
            AuthorityGrantId::new("agent-capability-runtime").expect("grant id"),
            TraceId::new("trace").expect("trace id"),
        );
        if let Some(working_directory) = working_directory {
            causal = causal.with_runtime_metadata(
                RUNTIME_METADATA_WORKING_DIRECTORY,
                working_directory.to_owned(),
            );
        }
        Invocation::new_sync(
            FunctionId::new(function_id).expect("function id"),
            payload,
            causal,
        )
    }

    #[test]
    fn relative_paths_resolve_against_session_working_directory_metadata() {
        let tempdir = tempfile::tempdir().expect("tempdir");
        std::fs::write(tempdir.path().join("README.md"), "hello").expect("write fixture");
        let root = tempdir.path().to_string_lossy().into_owned();
        let invocation = test_invocation(Some(&root));

        let resolved = resolve_invocation_path(&invocation, "README.md").expect("resolve");

        assert_eq!(
            resolved,
            tempdir
                .path()
                .join("README.md")
                .canonicalize()
                .expect("canonical path")
                .to_string_lossy()
                .into_owned()
        );
    }

    #[test]
    fn absolute_paths_inside_session_working_directory_are_allowed() {
        let tempdir = tempfile::tempdir().expect("tempdir");
        std::fs::write(tempdir.path().join("README.md"), "hello").expect("write fixture");
        let root = tempdir.path().to_string_lossy().into_owned();
        let invocation = test_invocation(Some(&root));
        let absolute = tempdir.path().join("README.md");

        let resolved =
            resolve_invocation_path(&invocation, &absolute.to_string_lossy()).expect("resolve");

        assert_eq!(
            resolved,
            absolute
                .canonicalize()
                .expect("canonical path")
                .to_string_lossy()
                .into_owned()
        );
    }

    #[test]
    fn absolute_paths_outside_session_working_directory_are_rejected() {
        let tempdir = tempfile::tempdir().expect("tempdir");
        let root = tempdir.path().to_string_lossy().into_owned();
        let invocation = test_invocation(Some(&root));

        let error = resolve_invocation_path(&invocation, "/etc/passwd").expect_err("reject");

        assert!(
            error
                .to_string()
                .contains("outside the active working directory")
        );
    }

    #[test]
    fn relative_parent_escapes_are_rejected() {
        let tempdir = tempfile::tempdir().expect("tempdir");
        let root = tempdir.path().to_string_lossy().into_owned();
        let invocation = test_invocation(Some(&root));

        let error = resolve_invocation_path(&invocation, "../outside.txt").expect_err("reject");

        assert!(
            error
                .to_string()
                .contains("outside the active working directory")
        );
    }

    #[cfg(unix)]
    #[test]
    fn symlink_escapes_are_rejected() {
        let tempdir = tempfile::tempdir().expect("tempdir");
        let outside = tempfile::tempdir().expect("outside tempdir");
        std::fs::write(outside.path().join("secret.txt"), "secret").expect("write outside file");
        std::os::unix::fs::symlink(outside.path(), tempdir.path().join("linked"))
            .expect("symlink fixture");
        let root = tempdir.path().to_string_lossy().into_owned();
        let invocation = test_invocation(Some(&root));

        let error = resolve_invocation_path(&invocation, "linked/secret.txt").expect_err("reject");

        assert!(
            error
                .to_string()
                .contains("outside the active working directory")
        );
    }

    #[test]
    fn direct_invocations_without_runtime_working_directory_keep_existing_relative_paths() {
        let invocation = test_invocation(None);

        let resolved = resolve_invocation_path(&invocation, "README.md").expect("resolve");

        assert_eq!(resolved, "README.md");
    }

    #[tokio::test]
    async fn list_dir_honors_max_results_bound() {
        let tempdir = tempfile::tempdir().expect("tempdir");
        for name in ["c.txt", "b.txt", "a.txt"] {
            std::fs::write(tempdir.path().join(name), "fixture").expect("write fixture");
        }
        let root = tempdir.path().to_string_lossy().into_owned();
        let invocation = test_invocation_with_payload(
            "filesystem::list_dir",
            json!({"path": ".", "maxResults": 2}),
            Some(&root),
        );

        let deps = Deps {
            engine_host: crate::engine::EngineHostHandle::new_in_memory().expect("host"),
        };
        let result = filesystem_list_dir_value(&invocation, &deps)
            .await
            .expect("list dir");

        let entries = result["entries"].as_array().expect("entries");
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0]["name"], json!("a.txt"));
        assert_eq!(entries[1]["name"], json!("b.txt"));
    }
}
