//! Canonical function inventory for the context domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] = &[
    "context::get_snapshot",
    "context::get_detailed_snapshot",
    "context::preview_compaction",
    "context::get_audit_trace",
    "context::should_compact",
    "context::confirm_compaction",
    "context::can_accept_turn",
    "context::clear",
    "context::compact",
];
