//! Canonical function inventory for the settings domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] = &[
    "settings::get",
    "settings::update",
    "settings::reset_to_defaults",
];
