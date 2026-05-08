//! Canonical function inventory for the skills domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] = &[
    "skills::list",
    "skills::get",
    "skills::refresh",
    "skills::activate",
    "skills::deactivate",
    "skills::active",
];
