//! Durable shared-checkout collision coordination.
//!
//! The live function catalog stamps one source-owned [`WorkspaceEffect`] onto
//! every prepared invocation. Scoped mutations additionally carry the active
//! reusable assignment's immutable canonical write prefixes. This module
//! resolves a physical in-workspace target, rejects lexical and symlink
//! escapes, reserves it in `workers.sqlite`, and parks without polling the
//! provider. Process claims reserve the whole workspace because arbitrary
//! local processes do not expose a trustworthy write set.
//!
//! These checks coordinate Tron-managed work. They are not OS containment:
//! root-session mutations retain their existing local-user authority outside
//! the shared checkout, and `process_run` may write anywhere its local user can.

use std::path::{Component, Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use crate::domains::worker_kernel::persistence::{
    NewWorkspaceClaim, WorkerStore, WorkspaceClaimHolder, WorkspaceClaimKind, WorkspaceClaimState,
};
use crate::domains::worker_kernel::runtime::WorkerRuntime;
use crate::engine::{Invocation, WorkspaceEffect};

const CLAIM_RECONCILIATION_INTERVAL: Duration = Duration::from_millis(250);

pub(super) struct WorkspaceClaimGuard {
    store: WorkerStore,
    changes: Arc<tokio::sync::Notify>,
    claim_id: String,
    process_gate: bool,
    released: bool,
}

impl WorkspaceClaimGuard {
    pub(super) fn claim_id(&self) -> &str {
        &self.claim_id
    }

    pub(super) fn bind_process(&self, process_id: u32) -> Result<(), String> {
        self.store
            .bind_workspace_process_claim(&self.claim_id, process_id)?;
        Ok(())
    }

    pub(super) fn prepare_process_gate(&mut self) -> Result<PathBuf, String> {
        let gate = self.store.prepare_workspace_process_gate(&self.claim_id)?;
        self.process_gate = true;
        Ok(gate)
    }

    pub(super) fn allow_process(&self) -> Result<(), String> {
        if !self.process_gate {
            return Err("workspace process admission gate was not prepared".to_owned());
        }
        self.store.allow_workspace_process_gate(&self.claim_id)
    }

    pub(super) fn finish<T>(mut self, result: Result<T, String>) -> Result<T, String> {
        let cleanup = if self.process_gate {
            self.store.abort_workspace_process_gate(&self.claim_id)
        } else {
            Ok(())
        };
        let release =
            cleanup.and_then(|()| self.store.release_workspace_claim(&self.claim_id, false));
        if release.is_ok() {
            self.released = true;
            self.changes.notify_waiters();
        }
        match (result, release) {
            (Ok(value), Ok(_)) => Ok(value),
            (Err(error), Ok(_)) => Err(error),
            (Ok(_), Err(release_error)) => Err(release_error),
            (Err(error), Err(release_error)) => Err(format!(
                "{error}; additionally failed to release workspace claim: {release_error}"
            )),
        }
    }
}

impl Drop for WorkspaceClaimGuard {
    fn drop(&mut self) {
        if self.released {
            return;
        }
        if self.process_gate
            && let Err(error) = self.store.abort_workspace_process_gate(&self.claim_id)
        {
            tracing::error!(
                claim_id = %self.claim_id,
                error = %error,
                "workspace process gate cleanup failed; retaining its durable claim"
            );
            return;
        }
        if self
            .store
            .release_workspace_claim(&self.claim_id, true)
            .is_ok()
        {
            self.released = true;
            self.changes.notify_waiters();
        }
    }
}

pub(super) struct ClaimedMutation {
    pub(super) path: PathBuf,
    pub(super) claim: Option<WorkspaceClaimGuard>,
}

pub(super) async fn claim_mutation(
    invocation: &Invocation,
    runtime: &WorkerRuntime,
    raw_path: &str,
) -> Result<ClaimedMutation, String> {
    require_effect(invocation, WorkspaceEffect::ScopedWrite)?;
    reject_parent_components(raw_path)?;

    let legacy_path = super::support::resolve_path(invocation, raw_path)?;
    let Some((workspace_id, workspace_root)) = workspace_context(invocation)? else {
        if invocation.causal_context.agent_execution_id().is_some() {
            return Err(
                "reusable-agent filesystem mutations require a durable workspace".to_owned(),
            );
        }
        return Ok(ClaimedMutation {
            path: legacy_path,
            claim: None,
        });
    };

    if invocation.causal_context.agent_execution_id().is_some() && Path::new(raw_path).is_absolute()
    {
        return Err(
            "reusable-agent filesystem mutations require workspace-relative paths".to_owned(),
        );
    }

    let candidate = if Path::new(raw_path).is_absolute() {
        PathBuf::from(raw_path)
    } else {
        workspace_root.join(raw_path)
    };
    let target = resolve_physical_workspace_target(&workspace_root, &candidate)?;
    let Some((_path, canonical_scope)) = target else {
        if invocation.causal_context.agent_execution_id().is_some() {
            return Err("reusable-agent filesystem mutation escapes its workspace".to_owned());
        }
        // Ordinary root sessions preserve their existing explicit absolute-path
        // authority. Only shared-checkout paths participate in collision claims.
        return Ok(ClaimedMutation {
            path: legacy_path,
            claim: None,
        });
    };

    if invocation.causal_context.agent_execution_id().is_some() {
        let scopes = invocation
            .causal_context
            .agent_write_scopes()
            .ok_or_else(|| "reusable-agent assignment has no write-scope snapshot".to_owned())?;
        if !scopes
            .iter()
            .any(|scope| scope_allows(scope, &canonical_scope))
        {
            return Err(format!(
                "workspace mutation '{canonical_scope}' is outside the assignment write scopes"
            ));
        }
    }

    let claim = acquire_claim(
        invocation,
        runtime,
        workspace_id,
        WorkspaceClaimKind::ScopedWrite,
        canonical_scope,
    )
    .await?;
    // Re-resolve after parking: an earlier writer may have created a path or
    // changed a parent. This closes symlink/case races before publication.
    let (path, scope_after_wait) = resolve_physical_workspace_target(&workspace_root, &candidate)?
        .ok_or_else(|| {
            "workspace mutation target escaped while waiting for its claim".to_owned()
        })?;
    if scope_after_wait != claim_scope(runtime, claim.claim_id())? {
        return Err("workspace mutation target changed while waiting for its claim".to_owned());
    }
    Ok(ClaimedMutation {
        path,
        claim: Some(claim),
    })
}

pub(super) async fn claim_process(
    invocation: &Invocation,
    runtime: &WorkerRuntime,
) -> Result<Option<WorkspaceClaimGuard>, String> {
    require_effect(invocation, WorkspaceEffect::ArbitraryProcess)?;
    let Some((workspace_id, _)) = workspace_context(invocation)? else {
        if invocation.causal_context.agent_execution_id().is_some() {
            return Err("reusable-agent processes require a durable workspace".to_owned());
        }
        return Ok(None);
    };
    acquire_claim(
        invocation,
        runtime,
        workspace_id,
        WorkspaceClaimKind::WorkspaceProcess,
        ".".to_owned(),
    )
    .await
    .map(Some)
}

fn require_effect(invocation: &Invocation, expected: WorkspaceEffect) -> Result<(), String> {
    let actual = invocation.causal_context.declared_workspace_effect();
    if actual != expected {
        return Err(format!(
            "workspace coordination contract mismatch: expected {}, found {}",
            expected.as_str(),
            actual.as_str()
        ));
    }
    Ok(())
}

fn workspace_context(invocation: &Invocation) -> Result<Option<(&str, PathBuf)>, String> {
    let Some(workspace_id) = invocation.causal_context.workspace_id.as_deref() else {
        return Ok(None);
    };
    let working_directory = invocation
        .causal_context
        .working_directory()
        .ok_or_else(|| "workspace effect requires a trusted working directory".to_owned())?;
    let root = crate::shared::foundation::paths::normalize_working_directory(working_directory)?;
    Ok(Some((workspace_id, root)))
}

fn claim_holder(
    invocation: &Invocation,
    runtime: &WorkerRuntime,
    workspace_id: &str,
) -> Result<WorkspaceClaimHolder, String> {
    match (
        invocation.causal_context.agent_execution_id(),
        invocation.causal_context.agent_id(),
    ) {
        (Some(execution_id), Some(agent_id)) => Ok(WorkspaceClaimHolder::AgentExecution {
            execution_id: execution_id.to_owned(),
            agent_id: agent_id.to_owned(),
        }),
        (Some(_), None) | (None, Some(_)) => {
            Err("workspace claim has incomplete reusable-agent identity".to_owned())
        }
        (None, None) => {
            let session_id = invocation
                .causal_context
                .session_id
                .as_deref()
                .ok_or_else(|| "workspace effect requires a durable session holder".to_owned())?;
            runtime.validate_workspace_claim_session(session_id, workspace_id)?;
            Ok(WorkspaceClaimHolder::Session {
                session_id: session_id.to_owned(),
            })
        }
    }
}

async fn acquire_claim(
    invocation: &Invocation,
    runtime: &WorkerRuntime,
    workspace_id: &str,
    kind: WorkspaceClaimKind,
    canonical_scope: String,
) -> Result<WorkspaceClaimGuard, String> {
    let holder = claim_holder(invocation, runtime, workspace_id)?;
    let record = runtime
        .store()
        .request_workspace_claim(&NewWorkspaceClaim {
            idempotency_key: format!("workspace-effect:{}", invocation.id),
            holder,
            workspace_id: workspace_id.to_owned(),
            kind,
            canonical_scope,
        })?;
    let changes = runtime.workspace_claim_changes();
    let guard = WorkspaceClaimGuard {
        store: runtime.store().clone(),
        changes: Arc::clone(&changes),
        claim_id: record.claim_id,
        process_gate: false,
        released: false,
    };
    if record.state == WorkspaceClaimState::Held {
        return Ok(guard);
    }
    metrics::counter!(
        "agent_workspace_claim_contention_total",
        "kind" => kind.as_str().to_owned()
    )
    .increment(1);
    let queued_at = chrono::DateTime::parse_from_rfc3339(&record.requested_at)
        .ok()
        .map(|timestamp| timestamp.with_timezone(&chrono::Utc));
    loop {
        let notified = changes.notified();
        let current = runtime
            .store()
            .workspace_claim(guard.claim_id())?
            .ok_or_else(|| "queued workspace claim disappeared".to_owned())?;
        match current.state {
            WorkspaceClaimState::Held => {
                if let Some(queued_at) = queued_at.as_ref() {
                    let seconds = chrono::Utc::now()
                        .signed_duration_since(*queued_at)
                        .num_milliseconds()
                        .max(0) as f64
                        / 1_000.0;
                    metrics::histogram!(
                        "agent_workspace_claim_queue_seconds",
                        "kind" => kind.as_str().to_owned()
                    )
                    .record(seconds);
                }
                return Ok(guard);
            }
            WorkspaceClaimState::Queued => {}
            WorkspaceClaimState::Released | WorkspaceClaimState::Cancelled => {
                return Err("workspace claim terminalized before acquisition".to_owned());
            }
        }
        tokio::select! {
            () = notified => {}
            () = tokio::time::sleep(CLAIM_RECONCILIATION_INTERVAL) => {}
        }
    }
}

fn claim_scope(runtime: &WorkerRuntime, claim_id: &str) -> Result<String, String> {
    runtime
        .store()
        .workspace_claim(claim_id)?
        .map(|claim| claim.canonical_scope)
        .ok_or_else(|| "workspace claim disappeared during validation".to_owned())
}

fn reject_parent_components(raw_path: &str) -> Result<(), String> {
    if raw_path.contains('\0')
        || Path::new(raw_path)
            .components()
            .any(|component| component == Component::ParentDir)
    {
        return Err("workspace mutation paths must not contain '..' or NUL".to_owned());
    }
    Ok(())
}

fn scope_allows(grant: &str, target: &str) -> bool {
    if grant == "." {
        return true;
    }
    let grant_path = Path::new(grant);
    let canonical_grant = !grant.is_empty()
        && !grant.ends_with('/')
        && !grant_path.is_absolute()
        && grant_path
            .components()
            .all(|component| matches!(component, Component::Normal(_)));
    canonical_grant && Path::new(target).starts_with(grant_path)
}

fn resolve_physical_workspace_target(
    workspace_root: &Path,
    candidate: &Path,
) -> Result<Option<(PathBuf, String)>, String> {
    let lexical_relative = candidate
        .strip_prefix(workspace_root)
        .ok()
        .map(PathBuf::from);
    let lexically_in_workspace = lexical_relative.is_some();
    if std::fs::symlink_metadata(candidate).is_ok_and(|metadata| metadata.file_type().is_symlink())
    {
        return Err(format!(
            "workspace mutation refuses symbolic-link target {}",
            candidate.display()
        ));
    }

    let mut existing = candidate.to_path_buf();
    let mut tail = Vec::new();
    while std::fs::symlink_metadata(&existing).is_err() {
        let component = existing
            .file_name()
            .ok_or_else(|| "workspace mutation target has no existing ancestor".to_owned())?
            .to_os_string();
        tail.push(component);
        if !existing.pop() {
            return Err("workspace mutation target has no existing ancestor".to_owned());
        }
    }
    let mut physical = existing
        .canonicalize()
        .map_err(|error| format!("resolve workspace target {}: {error}", existing.display()))?;
    if !physical.starts_with(workspace_root) {
        return if lexically_in_workspace {
            Err("workspace mutation path escapes through a symbolic link".to_owned())
        } else {
            Ok(None)
        };
    }
    for component in tail.iter().rev() {
        physical.push(component);
    }
    let relative = physical.strip_prefix(workspace_root).ok();
    let Some(relative) = relative else {
        return Ok(None);
    };
    if relative.as_os_str().is_empty()
        || relative
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return Err("workspace mutation target must be a canonical non-root path".to_owned());
    }
    // Validate after resolving the nearest existing ancestor. This both
    // preserves exact case admission and recognizes absolute paths that enter
    // the workspace through an OS-level canonical alias (for example
    // `/var` -> `/private/var` on macOS) instead of silently skipping claims.
    validate_existing_component_case(
        workspace_root,
        lexical_relative.as_deref().unwrap_or(relative),
    )?;
    let scope = relative
        .components()
        .map(|component| component.as_os_str().to_string_lossy())
        .collect::<Vec<_>>()
        .join("/");
    if scope.is_empty() {
        return Err("workspace mutation cannot reserve the workspace root".to_owned());
    }
    Ok(Some((physical, scope)))
}

fn validate_existing_component_case(root: &Path, relative: &Path) -> Result<(), String> {
    let mut current = root.to_path_buf();
    for component in relative.components() {
        let Component::Normal(component) = component else {
            return Err("workspace mutation path is not canonical".to_owned());
        };
        if !current.is_dir() {
            break;
        }
        let requested = component.to_string_lossy();
        let folded = requested
            .chars()
            .flat_map(char::to_lowercase)
            .collect::<String>();
        let mut matches = Vec::new();
        for entry in std::fs::read_dir(&current)
            .map_err(|error| format!("inspect workspace path {}: {error}", current.display()))?
        {
            let entry = entry.map_err(|error| {
                format!(
                    "inspect workspace entry under {}: {error}",
                    current.display()
                )
            })?;
            let Some(name) = entry.file_name().into_string().ok() else {
                continue;
            };
            if name
                .chars()
                .flat_map(char::to_lowercase)
                .collect::<String>()
                == folded
            {
                matches.push(name);
            }
        }
        if matches.len() > 1
            || matches
                .first()
                .is_some_and(|name| name != requested.as_ref())
        {
            return Err(format!(
                "workspace mutation target has ambiguous case at '{}'",
                requested
            ));
        }
        current.push(component);
        if matches.is_empty() {
            break;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scope_prefixes_are_component_aware() {
        assert!(scope_allows("Sources/A", "Sources/A/file.rs"));
        assert!(scope_allows("Sources/A", "Sources/A"));
        assert!(!scope_allows("Sources/A", "Sources/AB/file.rs"));
        assert!(!scope_allows("Sources/../Secrets", "Secrets/file"));
    }

    #[test]
    fn canonical_target_rejects_symlink_escape_and_case_alias() {
        let temporary = tempfile::tempdir().unwrap();
        let workspace = temporary.path().join("workspace");
        let outside = temporary.path().join("outside");
        std::fs::create_dir_all(workspace.join("Sources")).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        let workspace = workspace.canonicalize().unwrap();

        let case_error =
            resolve_physical_workspace_target(&workspace, &workspace.join("sources/file.rs"))
                .unwrap_err();
        assert!(case_error.contains("ambiguous case"));

        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(&outside, workspace.join("escape")).unwrap();
            let escape =
                resolve_physical_workspace_target(&workspace, &workspace.join("escape/file.rs"))
                    .unwrap_err();
            assert!(escape.contains("escapes through a symbolic link"));
        }
    }
}
