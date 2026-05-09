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

use tracing::instrument;

use crate::domains::worktree::WorktreeError;
use crate::domains::worktree::types::RebaseOnMainResult;
use crate::shared::server::error_mapping::map_worktree_error;

use super::Deps;
