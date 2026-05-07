//! Canonical git engine functions.
//!
//! JSON-RPC reaches these operations through `json_rpc` triggers targeting
//! canonical `git::*` function ids. The adapters keep the previous git service
//! behavior but run behind engine policy, idempotency, leases, and compensation
//! metadata.

use serde_json::Value;
use tokio::time::{Duration, timeout};
use tracing::instrument;

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::{self, RpcError};
use crate::server::rpc::git_service;
use crate::server::rpc::params::require_string_param;

use super::RpcEngineDeps;
use crate::engine::Invocation;

const CLONE_TIMEOUT: Duration = Duration::from_secs(300);

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    match method {
        "git.clone" => {
            CloneHandler
                .run(Some(invocation.payload.clone()), deps.rpc_context.as_ref())
                .await
        }
        _ => Err(RpcError::Internal {
            message: format!("RPC method {method} is not git-owned"),
        }),
    }
}

/// Clone a git repository.
pub struct CloneHandler;

#[allow(dead_code)]
impl CloneHandler {
    #[instrument(skip(self, ctx), fields(method = "git.clone"))]
    async fn run(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
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
        .map_err(|_| RpcError::Custom {
            code: errors::GIT_ERROR.into(),
            message: "Clone timed out. Try again or use a smaller repository.".into(),
            details: None,
        })?
        .map_err(|e| RpcError::Internal {
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
            return Err(RpcError::Custom {
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
