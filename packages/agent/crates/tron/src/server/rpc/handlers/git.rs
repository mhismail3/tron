//! Git handler: clone.

use async_trait::async_trait;
use serde_json::Value;
use tokio::time::{Duration, timeout};
use tracing::instrument;

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::{self, RpcError};
use crate::server::rpc::git_service;
use crate::server::rpc::handlers::require_string_param;
use crate::server::rpc::registry::MethodHandler;

const CLONE_TIMEOUT: Duration = Duration::from_secs(300);

/// Clone a git repository.
pub struct CloneHandler;

#[async_trait]
impl MethodHandler for CloneHandler {
    #[instrument(skip(self, ctx), fields(method = "git.clone"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[test]
    fn valid_github_url() {
        assert!(git_service::is_valid_git_url(
            "https://github.com/user/repo"
        ));
        assert!(git_service::is_valid_git_url(
            "https://github.com/user/repo.git"
        ));
        assert!(git_service::is_valid_git_url(
            "https://gitlab.com/org/project"
        ));
        assert!(git_service::is_valid_git_url(
            "https://bitbucket.org/team/repo"
        ));
    }

    #[test]
    fn invalid_git_url() {
        assert!(!git_service::is_valid_git_url(
            "http://github.com/user/repo"
        ));
        assert!(!git_service::is_valid_git_url("https://evil.com/user/repo"));
        assert!(!git_service::is_valid_git_url("not a url"));
        assert!(!git_service::is_valid_git_url(
            "https://github.com/../../../etc/passwd"
        ));
    }

    #[test]
    fn path_traversal_detected() {
        assert!(git_service::has_path_traversal("../../../etc"));
        assert!(git_service::has_path_traversal("/tmp/test/../../../etc"));
        assert!(!git_service::has_path_traversal("/tmp/my-repo"));
        assert!(!git_service::has_path_traversal(
            "/home/user/Workspace/repo"
        ));
    }

    #[tokio::test]
    async fn clone_missing_url() {
        let ctx = make_test_context();
        let err = CloneHandler
            .handle(Some(json!({"targetPath": "/tmp/repo"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn clone_missing_target_path() {
        let ctx = make_test_context();
        let err = CloneHandler
            .handle(Some(json!({"url": "https://github.com/user/repo"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn clone_invalid_url() {
        let ctx = make_test_context();
        let err = CloneHandler
            .handle(
                Some(json!({
                    "url": "not-a-valid-url",
                    "targetPath": "/tmp/repo"
                })),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn clone_path_traversal_rejected() {
        let ctx = make_test_context();
        let err = CloneHandler
            .handle(
                Some(json!({
                    "url": "https://github.com/user/repo",
                    "targetPath": "/tmp/../../etc/evil"
                })),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn clone_existing_path_rejected() {
        let ctx = make_test_context();
        let err = CloneHandler
            .handle(
                Some(json!({
                    "url": "https://github.com/user/repo",
                    "targetPath": "/tmp"
                })),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "ALREADY_EXISTS");
    }
}
