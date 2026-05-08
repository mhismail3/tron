//! Worktree operation implementations.
//!
//! Repository/worktree reads, safe index changes, branch workflows, diffs, and
//! destructive worktree operations live here behind canonical `worktree::*`
//! functions.

use super::*;
use crate::server::shared::error_mapping::map_worktree_error;
use crate::server::shared::errors::CapabilityError;
use crate::server::shared::params::{opt_bool, opt_string, require_bool, require_string_param};
use crate::worktree::types::CommitOptions;
use crate::worktree::{count_diff_stats, split_diff_by_file};
use serde_json::Value;
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
