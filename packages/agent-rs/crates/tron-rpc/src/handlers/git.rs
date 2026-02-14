//! Git handler: clone.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::context::RpcContext;
use crate::errors::{self, RpcError};
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

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
        let target = params
            .as_ref()
            .and_then(|p| p.get("targetDirectory"))
            .and_then(Value::as_str);

        if !is_valid_git_url(&url) {
            return Err(RpcError::InvalidParams {
                message: format!("Invalid git URL: {url}"),
            });
        }

        // Determine target directory
        let repo_name = url
            .rsplit('/')
            .next()
            .unwrap_or("repo")
            .trim_end_matches(".git");

        let target_dir = if let Some(t) = target {
            if has_path_traversal(t) {
                return Err(RpcError::InvalidParams {
                    message: "Target directory contains path traversal".into(),
                });
            }
            std::path::PathBuf::from(t)
        } else {
            let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
            std::path::PathBuf::from(home).join("Workspace").join(repo_name)
        };

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

        // Execute git clone
        let output = tokio::process::Command::new("git")
            .args(["clone", "--depth", "1", &url, &target_dir.to_string_lossy()])
            .output()
            .await
            .map_err(|e| RpcError::Internal {
                message: format!("Failed to execute git clone: {e}"),
            })?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(RpcError::Custom {
                code: errors::GIT_ERROR.into(),
                message: format!("git clone failed: {stderr}"),
                details: None,
            });
        }

        Ok(serde_json::json!({
            "success": true,
            "cloned": true,
            "path": target_dir.to_string_lossy(),
            "url": url,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
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
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn clone_invalid_url() {
        let ctx = make_test_context();
        let err = CloneHandler
            .handle(Some(json!({"url": "not-a-valid-url"})), &ctx)
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
                    "targetDirectory": "/tmp/../../etc/evil"
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
                    "targetDirectory": "/tmp"
                })),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "ALREADY_EXISTS");
    }
}
