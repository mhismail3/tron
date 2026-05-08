//! Canonical function inventory for the voice_notes domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] = &[
    "voice_notes::save",
    "voice_notes::list",
    "voice_notes::delete",
];
