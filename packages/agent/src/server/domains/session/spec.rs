//! Canonical function inventory for the session domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] = &[
    "session::create",
    "session::resume",
    "session::list",
    "session::delete",
    "session::fork",
    "session::get_head",
    "session::get_state",
    "session::get_history",
    "session::reconstruct",
    "session::archive",
    "session::unarchive",
    "session::archive_older_than",
    "session::export",
];
