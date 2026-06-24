//! Serializable DTOs for read-only git/worktree evidence.

use serde::Serialize;

pub(crate) const SCHEMA_VERSION: &str = "tron.git.v1";

#[derive(Debug, Clone, Serialize)]
pub(crate) struct GitPathInfo {
    #[serde(rename = "root")]
    pub(crate) root: &'static str,
    #[serde(rename = "relativePath")]
    pub(crate) relative_path: String,
    #[serde(rename = "repoRelativePath")]
    pub(crate) repo_relative_path: String,
    #[serde(rename = "nestedPath")]
    pub(crate) nested_path: bool,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct GitRepositoryInfo {
    #[serde(rename = "repoRoot")]
    pub(crate) repo_root: String,
    #[serde(rename = "worktreeRoot")]
    pub(crate) worktree_root: String,
    #[serde(rename = "headOid")]
    pub(crate) head_oid: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct GitBranchInfo {
    pub(crate) kind: String,
    pub(crate) name: Option<String>,
    #[serde(rename = "headOid")]
    pub(crate) head_oid: Option<String>,
    pub(crate) upstream: Option<String>,
    pub(crate) ahead: Option<i64>,
    pub(crate) behind: Option<i64>,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct GitStatusEntry {
    pub(crate) path: String,
    pub(crate) xy: String,
    pub(crate) status: String,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct GitStatusCounts {
    pub(crate) staged: usize,
    pub(crate) unstaged: usize,
    pub(crate) untracked: usize,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct GitStatusSummary {
    pub(crate) staged: Vec<GitStatusEntry>,
    pub(crate) unstaged: Vec<GitStatusEntry>,
    pub(crate) untracked: Vec<GitStatusEntry>,
    pub(crate) counts: GitStatusCounts,
    pub(crate) dirty: bool,
    pub(crate) truncated: bool,
    pub(crate) limit: usize,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct BoundedText {
    pub(crate) text: String,
    pub(crate) truncated: bool,
    #[serde(rename = "bytes")]
    pub(crate) bytes: usize,
    #[serde(rename = "maxBytes")]
    pub(crate) max_bytes: usize,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct GitStatusEvidence {
    #[serde(rename = "schemaVersion")]
    pub(crate) schema_version: &'static str,
    pub(crate) status: &'static str,
    pub(crate) operation: &'static str,
    pub(crate) path: GitPathInfo,
    pub(crate) repository: GitRepositoryInfo,
    pub(crate) branch: GitBranchInfo,
    pub(crate) dirty: bool,
    pub(crate) changes: GitStatusSummary,
    #[serde(rename = "rawStatus")]
    pub(crate) raw_status: BoundedText,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct GitDiffEvidence {
    #[serde(rename = "schemaVersion")]
    pub(crate) schema_version: &'static str,
    pub(crate) status: &'static str,
    pub(crate) operation: &'static str,
    pub(crate) path: GitPathInfo,
    pub(crate) repository: GitRepositoryInfo,
    #[serde(rename = "trackedOnly")]
    pub(crate) tracked_only: bool,
    pub(crate) diff: BoundedText,
    pub(crate) staged: BoundedText,
    pub(crate) unstaged: BoundedText,
}
