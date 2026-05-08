//! Canonical function inventory for the logs domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] = &["logs::ingest", "logs::recent"];
