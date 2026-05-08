//! Canonical function inventory for the notifications domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] = &[
    "notifications::list",
    "notifications::mark_read",
    "notifications::mark_all_read",
];
