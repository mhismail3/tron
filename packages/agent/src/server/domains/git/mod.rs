//! Canonical git engine functions.
//!
//! Client protocols reach these operations through engine triggers targeting
//! canonical `git::*` function ids. The helpers keep git service behavior
//! behind engine policy, idempotency, leases, and compensation
//! metadata.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

pub(crate) mod service;

use serde_json::Value;
use tokio::time::{Duration, timeout};
use tracing::instrument;

use crate::server::domains::git::service as git_service;
use crate::server::shared::errors::{self, CapabilityError};
use crate::server::shared::params::require_string_param;

use super::*;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    let git_deps = Deps::from_engine(deps);
    super::domain_worker_module(
        "git",
        contract::STREAM_TOPICS,
        handlers::function_registrations(contract::capabilities()?, git_deps)?,
    )
}

const CLONE_TIMEOUT: Duration = Duration::from_secs(300);

/// Clone a git repository.
pub struct CloneOperation;

impl CloneOperation {
    #[instrument(skip(self), fields(method = "git::clone"))]
    async fn run(&self, params: Option<Value>) -> Result<Value, CapabilityError> {
        let url = require_string_param(params.as_ref(), "url")?;
        let target_path = require_string_param(params.as_ref(), "targetPath")?;
        let url_for_clone = url.clone();
        let clone_request = run_blocking_task("git.clone.prepare", move || {
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
