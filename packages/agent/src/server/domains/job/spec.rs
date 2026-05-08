//! Canonical function inventory for the job domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] = &[
    "job::background",
    "job::cancel",
    "job::list",
    "job::subscribe",
    "job::unsubscribe",
];
