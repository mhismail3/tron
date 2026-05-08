//! Canonical function inventory for the git domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] = &[
    "git::clone",
    "git::sync_main",
    "git::push",
    "git::list_local_branches",
    "git::list_remote_branches",
];
