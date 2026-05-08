//! Canonical function inventory for the repo domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] = &["repo::list_sessions", "repo::get_divergence"];
