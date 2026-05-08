//! Canonical function inventory for the cron domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] = &[
    "cron::list",
    "cron::get",
    "cron::create",
    "cron::update",
    "cron::delete",
    "cron::run",
    "cron::status",
    "cron::get_runs",
];
