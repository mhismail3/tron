//! Worktree workflow operations.
use super::*;

pub(crate) fn require_session_and_paths(
    params: Option<&Value>,
) -> Result<(String, Vec<String>), CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let paths = params
        .and_then(|p| p.get("paths"))
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    if paths.is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: "Missing or empty required parameter: paths".into(),
        });
    }
    for path in &paths {
        validate_relative_worktree_path(path)?;
    }
    Ok((session_id, paths))
}

pub(crate) fn validate_relative_worktree_path(path: &str) -> Result<(), CapabilityError> {
    if path.is_empty() || path.contains('\0') {
        return Err(CapabilityError::InvalidParams {
            message: "Path must be a non-empty relative path".into(),
        });
    }
    let candidate = std::path::Path::new(path);
    if candidate.is_absolute()
        || candidate.components().any(|component| {
            matches!(
                component,
                std::path::Component::ParentDir
                    | std::path::Component::RootDir
                    | std::path::Component::Prefix(_)
            )
        })
    {
        return Err(CapabilityError::InvalidParams {
            message: format!("Path escapes repository root: {path}"),
        });
    }
    Ok(())
}

/// Stage files: `git add -- <paths>`
pub struct StageFilesOperation;

impl StageFilesOperation {
    #[instrument(skip(self, deps), fields(method = "worktree::stage_files"))]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let (session_id, paths) = require_session_and_paths(params.as_ref())?;
        let dir = resolve_diff_dir(deps, &session_id)?;

        let mut args = vec!["-C".to_string(), dir, "add".to_string(), "--".to_string()];
        args.extend(paths);

        let output = tokio::process::Command::new("git")
            .args(&args)
            .output()
            .await
            .map_err(|e| CapabilityError::Internal {
                message: format!("Failed to run git add: {e}"),
            })?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(CapabilityError::Internal {
                message: format!("git add failed: {stderr}"),
            });
        }

        Ok(serde_json::json!({ "success": true }))
    }
}

/// Unstage files: `git restore --staged -- <paths>` (or `git rm --cached` for repos with no commits)
pub struct UnstageFilesOperation;

impl UnstageFilesOperation {
    #[instrument(skip(self, deps), fields(method = "worktree::unstage_files"))]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let (session_id, paths) = require_session_and_paths(params.as_ref())?;
        let dir = resolve_diff_dir(deps, &session_id)?;

        // Check if repo has commits
        let has_commits = tokio::process::Command::new("git")
            .args(["-C", &dir, "rev-parse", "HEAD"])
            .output()
            .await
            .map(|o| o.status.success())
            .unwrap_or(false);

        let output = if has_commits {
            let mut args = vec![
                "-C".to_string(),
                dir,
                "restore".to_string(),
                "--staged".to_string(),
                "--".to_string(),
            ];
            args.extend(paths);
            tokio::process::Command::new("git")
                .args(&args)
                .output()
                .await
        } else {
            // No commits: use git rm --cached
            let mut args = vec![
                "-C".to_string(),
                dir,
                "rm".to_string(),
                "--cached".to_string(),
                "--".to_string(),
            ];
            args.extend(paths);
            tokio::process::Command::new("git")
                .args(&args)
                .output()
                .await
        };

        let output = output.map_err(|e| CapabilityError::Internal {
            message: format!("Failed to run git unstage: {e}"),
        })?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(CapabilityError::Internal {
                message: format!("git unstage failed: {stderr}"),
            });
        }

        Ok(serde_json::json!({ "success": true }))
    }
}

/// Discard file changes: restores tracked files from HEAD, deletes untracked files.
pub struct DiscardFilesOperation;

impl DiscardFilesOperation {
    #[instrument(skip(self, deps), fields(method = "worktree::discard_files"))]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let (session_id, paths) = require_session_and_paths(params.as_ref())?;
        let dir = resolve_diff_dir(deps, &session_id)?;
        let repo_root = std::path::Path::new(&dir);

        // Canonicalize repo root once for symlink-safe comparison (macOS /var → /private/var)
        let canonical_root = repo_root
            .canonicalize()
            .unwrap_or_else(|_| repo_root.to_path_buf());

        // Validate all paths before taking any action
        for path in &paths {
            // Reject absolute paths
            if path.starts_with('/') {
                return Err(CapabilityError::InvalidParams {
                    message: format!("Path must be relative: {path}"),
                });
            }
            // Reject path traversal components
            if path.contains("..") {
                return Err(CapabilityError::InvalidParams {
                    message: format!("Path escapes repository root: {path}"),
                });
            }
            // Resolve and check the path stays within repo root
            let resolved = canonical_root.join(path);
            let canonical = resolved.canonicalize().unwrap_or_else(|_| resolved.clone());
            if !canonical.starts_with(&canonical_root) {
                return Err(CapabilityError::InvalidParams {
                    message: format!("Path escapes repository root: {path}"),
                });
            }
        }

        for path in &paths {
            // Check if file is tracked
            let is_tracked = tokio::process::Command::new("git")
                .args(["-C", &dir, "ls-files", "--error-unmatch", path])
                .output()
                .await
                .map(|o| o.status.success())
                .unwrap_or(false);

            if is_tracked {
                // Tracked: restore from HEAD
                let output = tokio::process::Command::new("git")
                    .args(["-C", &dir, "checkout", "--", path])
                    .output()
                    .await
                    .map_err(|e| CapabilityError::Internal {
                        message: format!("Failed to run git checkout: {e}"),
                    })?;
                if !output.status.success() {
                    let stderr = String::from_utf8_lossy(&output.stderr);
                    return Err(CapabilityError::Internal {
                        message: format!("git checkout failed for {path}: {stderr}"),
                    });
                }
            } else {
                // Untracked: delete from filesystem
                let full_path = canonical_root.join(path);
                if full_path.exists() {
                    tokio::fs::remove_file(&full_path).await.map_err(|e| {
                        CapabilityError::Internal {
                            message: format!("Failed to delete {path}: {e}"),
                        }
                    })?;
                } else {
                    return Err(CapabilityError::Internal {
                        message: format!("File not found: {path}"),
                    });
                }
            }
        }

        Ok(serde_json::json!({ "success": true }))
    }
}
