//! Canonical function inventory for the transcription domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] = &[
    "transcription::audio",
    "transcription::list_models",
    "transcription::download_model",
];
