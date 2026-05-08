//! Canonical function inventory for the system domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] = &[
    "system::ping",
    "system::get_info",
    "system::get_diagnostics",
    "system::shutdown",
    "system::check_for_updates",
    "system::get_update_status",
];
