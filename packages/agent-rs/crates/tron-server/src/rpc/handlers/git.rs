//! Git handler: clone.

use async_trait::async_trait;
use serde_json::Value;
use tokio::time::{timeout, Duration};
use tracing::instrument;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::{self, RpcError};
use crate::rpc::handlers::require_string_param;
use crate::rpc::registry::MethodHandler;

const CLONE_TIMEOUT: Duration = Duration::from_secs(300);

/// Validate a GitHub/GitLab URL.
fn is_valid_git_url(url: &str) -> bool {
    let re = regex::Regex::new(
        r"^https://(github\.com|gitlab\.com|bitbucket\.org)/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+(\.git)?$",
    )
    .expect("valid regex");
    re.is_match(url)
}

/// Check for path traversal in a target directory.
fn has_path_traversal(path: &str) -> bool {
    path.contains("..") || path.contains('\0')
}

/// Clone a git repository.
pub struct CloneHandler;

#[async_trait]
impl MethodHandler for CloneHandler {
    #[instrument(skip(self, _ctx), fields(method = "git.clone"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let url = require_string_param(params.as_ref(), "url")?;
        let target_path = require_string_param(params.as_ref(), "targetPath")?;

        if !is_valid_git_url(&url) {
            return Err(RpcError::InvalidParams {
                message: format!("Invalid git URL: {url}"),
            });
        }

        if has_path_traversal(&target_path) {
            return Err(RpcError::InvalidParams {
                message: "Target directory contains path traversal".into(),
            });
        }

        let repo_name = url
            .rsplit('/')
            .next()
            .unwrap_or("repo")
            .trim_end_matches(".git");

        let target_dir = std::path::PathBuf::from(&target_path);

        // Check if target already exists
        if target_dir.exists() {
            return Err(RpcError::Custom {
                code: errors::ALREADY_EXISTS.into(),
                message: format!("Target directory already exists: {}", target_dir.display()),
                details: None,
            });
        }

        // Ensure parent dir exists
        if let Some(parent) = target_dir.parent() {
            std::fs::create_dir_all(parent).map_err(|e| RpcError::Internal {
                message: format!("Failed to create parent directory: {e}"),
            })?;
        }

        // Execute git clone with timeout
        let output = timeout(
            CLONE_TIMEOUT,
            tokio::process::Command::new("git")
                .args(["clone", "--depth", "1", &url, &target_dir.to_string_lossy()])
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
            "path": target_dir.to_string_lossy(),
            "repoName": repo_name,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[test]
    fn valid_github_url() {
        assert!(is_valid_git_url("https://github.com/user/repo"));
        assert!(is_valid_git_url("https://github.com/user/repo.git"));
        assert!(is_valid_git_url("https://gitlab.com/org/project"));
        assert!(is_valid_git_url("https://bitbucket.org/team/repo"));
    }

    #[test]
    fn invalid_git_url() {
        assert!(!is_valid_git_url("http://github.com/user/repo"));
        assert!(!is_valid_git_url("https://evil.com/user/repo"));
        assert!(!is_valid_git_url("not a url"));
        assert!(!is_valid_git_url("https://github.com/../../../etc/passwd"));
    }

    #[test]
    fn path_traversal_detected() {
        assert!(has_path_traversal("../../../etc"));
        assert!(has_path_traversal("/tmp/test/../../../etc"));
        assert!(!has_path_traversal("/tmp/my-repo"));
        assert!(!has_path_traversal("/home/user/Workspace/repo"));
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
            .handle(
                Some(json!({"url": "https://github.com/user/repo"})),
                &ctx,
            )
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
