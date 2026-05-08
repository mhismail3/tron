//! Canonical git engine functions.
//!
//! Client protocols reach these operations through engine triggers targeting
//! canonical `git::*` function ids. The helpers keep git service behavior
//! behind engine policy, idempotency, leases, and compensation
//! metadata.

pub(crate) mod contract;

pub(crate) mod service;

use serde_json::Value;
use tokio::time::{Duration, timeout};
use tracing::instrument;

use crate::server::domains::git::service as git_service;
use crate::server::shared::context::ServerCapabilityContext;
use crate::server::shared::errors::{self, CapabilityError};
use crate::server::shared::params::require_string_param;

use super::*;
use crate::engine::Invocation;

pub(crate) fn worker_module(
    deps: &EngineCapabilityDeps,
) -> crate::engine::Result<DomainWorkerModule> {
    let git_deps = Deps::from_engine(deps);
    let worktree_deps = crate::server::domains::worktree::Deps::from_engine(deps);
    let mut module =
        super::domain_worker_module("git", Vec::new(), git_deps.clone(), super::git_handler)?;
    module.functions.extend(
        contract::capabilities()?
            .into_iter()
            .map(|spec| {
                if spec.method == "git::clone" {
                    super::domain_function_registration(spec, git_deps.clone(), super::git_handler)
                } else {
                    super::domain_function_registration(
                        spec,
                        worktree_deps.clone(),
                        super::git_workflow_handler,
                    )
                }
            })
            .collect::<crate::engine::Result<Vec<_>>>()?,
    );
    Ok(module)
}

#[derive(Clone)]
pub(crate) struct Deps {
    capability_context: Arc<ServerCapabilityContext>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &EngineCapabilityDeps) -> Self {
        Self {
            capability_context: deps.capability_context.clone(),
        }
    }
}

const CLONE_TIMEOUT: Duration = Duration::from_secs(300);

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    match method {
        "git::clone" => {
            CloneOperation
                .run(
                    Some(invocation.payload.clone()),
                    deps.capability_context.as_ref(),
                )
                .await
        }
        _ => Err(CapabilityError::Internal {
            message: format!("operation {method} is not git-owned"),
        }),
    }
}

/// Clone a git repository.
pub struct CloneOperation;

impl CloneOperation {
    #[instrument(skip(self, ctx), fields(method = "git::clone"))]
    async fn run(
        &self,
        params: Option<Value>,
        ctx: &ServerCapabilityContext,
    ) -> Result<Value, CapabilityError> {
        let url = require_string_param(params.as_ref(), "url")?;
        let target_path = require_string_param(params.as_ref(), "targetPath")?;
        let url_for_clone = url.clone();
        let clone_request = ctx
            .run_blocking("git.clone.prepare", move || {
                git_service::prepare_clone(&url, &target_path)
            })
            .await?;

        // Execute git clone with timeout
        let output = timeout(
            CLONE_TIMEOUT,
            tokio::process::Command::new("git")
                .args([
                    "clone",
                    "--depth",
                    "1",
                    &url_for_clone,
                    &clone_request.target_dir.to_string_lossy(),
                ])
                .output(),
        )
        .await
        .map_err(|_| CapabilityError::Custom {
            code: errors::GIT_ERROR.into(),
            message: "Clone timed out. Try again or use a smaller repository.".into(),
            details: None,
        })?
        .map_err(|e| CapabilityError::Internal {
            message: format!("Failed to execute git clone: {e}"),
        })?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let message = if stderr.contains("Repository not found") {
                "Repository not found. Check the URL and ensure the repo is public.".into()
            } else if stderr.contains("Could not resolve host") {
                "Network error. Check your connection.".into()
            } else if stderr.contains("Authentication failed") {
                "Authentication failed. This may be a private repository.".into()
            } else {
                format!("git clone failed: {stderr}")
            };
            return Err(CapabilityError::Custom {
                code: errors::GIT_ERROR.into(),
                message,
                details: None,
            });
        }

        Ok(serde_json::json!({
            "success": true,
            "path": clone_request.target_dir.to_string_lossy(),
            "repoName": clone_request.repo_name,
        }))
    }
}
