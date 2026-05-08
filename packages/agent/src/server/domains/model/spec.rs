//! Canonical function inventory for the model domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] = &[
    "model::list",
    "model::switch",
    "config::set_reasoning_level",
];
