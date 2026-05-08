//! Canonical function inventory for the plan domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] = &["plan::enter", "plan::exit", "plan::get_state"];
