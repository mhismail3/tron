//! Canonical function inventory for the events domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] = &[
    "events::get_history",
    "events::get_since",
    "events::subscribe",
    "events::unsubscribe",
    "events::append",
];
