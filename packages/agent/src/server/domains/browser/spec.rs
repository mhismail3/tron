//! Canonical function inventory for the browser domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] = &[
    "browser::start_stream",
    "browser::stop_stream",
    "browser::get_status",
];
