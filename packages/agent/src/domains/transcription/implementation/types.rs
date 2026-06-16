//! Core types for the local transcription engine.

use std::sync::{Arc, OnceLock};

use async_trait::async_trait;

#[derive(Debug, Clone)]
/// Normalized result returned by a local transcription backend.
pub struct TranscriptionResult {
    /// Transcribed text returned by the backend before domain cleanup.
    pub text: String,
    /// BCP-47-ish language code reported by the backend.
    pub language: String,
    /// Approximate audio duration reported by the backend.
    pub duration_seconds: f64,
}

#[derive(Debug, thiserror::Error)]
/// Errors from local transcription setup or sidecar execution.
pub enum TranscriptionError {
    /// Transcription runtime setup failed before audio processing began.
    #[error("setup error: {0}")]
    Setup(String),
    /// The sidecar process failed, timed out, or returned an invalid response.
    #[error("sidecar error: {0}")]
    Sidecar(String),
    /// Filesystem or process IO failed while preparing/running transcription.
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

#[async_trait]
/// Async boundary implemented by local speech-to-text engines.
pub trait TranscriptionEngine: Send + Sync {
    /// Transcribe one in-memory audio payload.
    async fn transcribe(
        &self,
        audio_bytes: &[u8],
        mime_type: &str,
    ) -> Result<TranscriptionResult, TranscriptionError>;
}

/// Shared one-time slot populated when the local transcription engine starts.
pub type SharedTranscriptionEngine = Arc<OnceLock<Arc<dyn TranscriptionEngine>>>;

/// Adds transcription-specific setup/sidecar context to fallible operations.
pub trait ResultExt<T> {
    /// Map an arbitrary error into a setup error with contextual text.
    fn setup(self, context: &str) -> Result<T, TranscriptionError>;
    /// Map an arbitrary error into a sidecar error with contextual text.
    fn sidecar(self, context: &str) -> Result<T, TranscriptionError>;
}

impl<T, E: std::fmt::Display> ResultExt<T> for Result<T, E> {
    fn setup(self, context: &str) -> Result<T, TranscriptionError> {
        self.map_err(|e| TranscriptionError::Setup(format!("{context}: {e}")))
    }

    fn sidecar(self, context: &str) -> Result<T, TranscriptionError> {
        self.map_err(|e| TranscriptionError::Sidecar(format!("{context}: {e}")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn result_ext_adds_context() {
        let err: Result<(), &str> = Err("missing python");
        let mapped = err.setup("find_python");
        assert!(
            matches!(mapped, Err(TranscriptionError::Setup(message)) if message == "find_python: missing python")
        );
    }

    #[test]
    fn io_error_converts() {
        let error = std::io::Error::new(std::io::ErrorKind::BrokenPipe, "pipe");
        let converted: TranscriptionError = error.into();
        assert!(matches!(converted, TranscriptionError::Io(_)));
    }
}
