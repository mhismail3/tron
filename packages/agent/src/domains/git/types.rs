use std::path::PathBuf;

use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::Value;

pub(super) const SCHEMA_VERSION: &str = "tron.git_readonly.v1";
pub(super) const INDEX_CHANGE_SCHEMA_VERSION: &str = "tron.git_index_change.v1";
pub(super) const DEFAULT_STATUS_BYTES: usize = 64 * 1024;
pub(super) const MAX_STATUS_BYTES: usize = 200 * 1024;
pub(super) const DEFAULT_DIFF_BYTES: usize = 64 * 1024;
pub(super) const MAX_DIFF_BYTES: usize = 128 * 1024;

#[derive(Clone)]
pub(super) struct ResolvedTarget {
    pub(super) working_root: PathBuf,
    pub(super) canonical: PathBuf,
    pub(super) relative_path: String,
}

#[derive(Clone)]
pub(super) struct RepositoryFacts {
    pub(super) worktree_root: PathBuf,
    pub(super) worktree_relative_path: String,
    pub(super) pathspec: String,
    pub(super) branch: Option<String>,
    pub(super) detached_head: bool,
    pub(super) head_oid: Option<String>,
    pub(super) upstream: Option<String>,
    pub(super) ahead: Option<u64>,
    pub(super) behind: Option<u64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct GitIndexChangeRecord {
    pub(super) schema_version: String,
    pub(super) operation: String,
    pub(super) state: String,
    pub(super) repository: Value,
    pub(super) path: Value,
    pub(super) expected_head: String,
    pub(super) head_oid: String,
    pub(super) reason: String,
    pub(super) authority: Value,
    pub(super) before: Value,
    pub(super) after: Value,
    pub(super) evidence: Value,
    pub(super) trace_refs: Vec<Value>,
    pub(super) replay_refs: Vec<Value>,
    pub(super) idempotency: Value,
    pub(super) revision: u64,
    pub(super) created_at: DateTime<Utc>,
}
