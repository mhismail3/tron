//! Canonical git/worktree workflow engine functions.
//!
//! Client protocols reach these operations through engine triggers targeting
//! canonical `git::*` and `worktree::*` function ids. Operation modules keep
//! coordinator behavior local to the worktree worker while preserving the
//! existing coordinator-owned event emission and error mapping.

mod branches;
mod conflicts;
mod finalize;
mod merge;
mod rebase;
mod remote;
mod shared;
mod subagent;

pub use branches::{ListLocalBranchesOperation, ListRemoteBranchesOperation};
pub use conflicts::{
    AbortMergeOperation, ContinueMergeOperation, ListConflictsOperation, ResolveConflictOperation,
};
pub use finalize::FinalizeSessionOperation;
pub use merge::StartMergeOperation;
pub use rebase::RebaseOnMainOperation;
pub use remote::{PushOperation, SyncMainOperation};
pub use subagent::ResolveConflictsWithSubagentOperation;

use serde_json::{Value, json};
use tracing::instrument;

use crate::server::shared::error_mapping::map_worktree_error;
use crate::server::shared::errors::CapabilityError;
use crate::server::shared::params::{opt_bool, opt_string, opt_u64, require_string_param};
use crate::worktree::WorktreeError;
use crate::worktree::types::RebaseOnMainResult;

use super::Deps;
