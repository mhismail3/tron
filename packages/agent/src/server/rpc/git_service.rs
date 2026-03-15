use std::path::PathBuf;
use std::sync::LazyLock;

use regex::Regex;

use crate::server::rpc::errors::{self, RpcError};

static GIT_URL_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"^https://(github\.com|gitlab\.com|bitbucket\.org)/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+(\.git)?$",
    )
    .unwrap()
});

pub(crate) struct CloneRequest {
    pub(crate) repo_name: String,
    pub(crate) target_dir: PathBuf,
}

pub(crate) fn is_valid_git_url(url: &str) -> bool {
    GIT_URL_RE.is_match(url)
}

pub(crate) fn has_path_traversal(path: &str) -> bool {
    path.contains("..") || path.contains('\0')
}

pub(crate) fn prepare_clone(url: &str, target_path: &str) -> Result<CloneRequest, RpcError> {
    if !is_valid_git_url(url) {
        return Err(RpcError::InvalidParams {
            message: format!("Invalid git URL: {url}"),
        });
    }

    if has_path_traversal(target_path) {
        return Err(RpcError::InvalidParams {
            message: "Target directory contains path traversal".into(),
        });
    }

    let repo_name = url
        .rsplit('/')
        .next()
        .unwrap_or("repo")
        .trim_end_matches(".git")
        .to_string();
    let target_dir = PathBuf::from(target_path);

    if target_dir.exists() {
        return Err(RpcError::Custom {
            code: errors::ALREADY_EXISTS.into(),
            message: format!("Target directory already exists: {}", target_dir.display()),
            details: None,
        });
    }

    if let Some(parent) = target_dir.parent() {
        std::fs::create_dir_all(parent).map_err(|error| RpcError::Internal {
            message: format!("Failed to create parent directory: {error}"),
        })?;
    }

    Ok(CloneRequest {
        repo_name,
        target_dir,
    })
}
