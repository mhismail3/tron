//! Canonical function inventory for the sandbox domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] = &[
    "sandbox::list_containers",
    "sandbox::start_container",
    "sandbox::stop_container",
    "sandbox::kill_container",
    "sandbox::remove_container",
];
