//! Worktree operation implementations.
//!
//! Repository/worktree reads, safe index changes, branch workflows, diffs, and
//! destructive worktree operations live here behind canonical `worktree::*`
//! functions.

use crate::domains::worktree::types::CommitOptions;
use crate::domains::worktree::{count_diff_stats, split_diff_by_file};
use crate::shared::server::error_mapping::map_worktree_error;
use crate::shared::server::params::require_bool;
use tracing::instrument;

// ── Helpers ─────────────────────────────────────────────────────────

// Operation modules grouped by workflow.

mod shared;
pub(crate) use shared::*;
mod status;
pub(crate) use status::*;
mod commit;
pub(crate) use commit::*;
mod list;
pub(crate) use list::*;
mod branch;
pub(crate) use branch::*;
mod diff;
pub(crate) use diff::*;
mod index;
pub(crate) use index::*;
