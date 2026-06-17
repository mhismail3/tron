//! Core types for the local transcription engine.

use std::sync::{Arc, Mutex, OnceLock};

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

/// Runtime state for the local transcription sidecar.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TranscriptionRuntimeState {
    /// The setting is off, so no local sidecar should be running.
    Disabled,
    /// Startup has not been requested yet.
    NotStarted,
    /// The sidecar is creating its venv, downloading the model, or loading MLX.
    Loading,
    /// At least one worker is ready to accept audio.
    Ready,
    /// Startup failed and needs a server restart or settings change to retry.
    Failed,
}

impl TranscriptionRuntimeState {
    /// Stable wire value exposed through `transcription::list_models`.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Disabled => "disabled",
            Self::NotStarted => "not_started",
            Self::Loading => "loading",
            Self::Ready => "ready",
            Self::Failed => "failed",
        }
    }
}

/// Snapshot of sidecar readiness published to clients.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TranscriptionRuntimeStatus {
    /// Current sidecar state.
    pub state: TranscriptionRuntimeState,
    /// Optional user-actionable detail for loading or failed states.
    pub message: Option<String>,
}

impl Default for TranscriptionRuntimeStatus {
    fn default() -> Self {
        Self {
            state: TranscriptionRuntimeState::NotStarted,
            message: None,
        }
    }
}

/// Shared one-time slot plus observable sidecar startup state.
#[derive(Clone)]
pub struct SharedTranscriptionEngine {
    inner: Arc<SharedTranscriptionEngineInner>,
}

struct SharedTranscriptionEngineInner {
    engine: OnceLock<Arc<dyn TranscriptionEngine>>,
    status: Mutex<TranscriptionRuntimeStatus>,
}

impl SharedTranscriptionEngine {
    /// Create an empty runtime slot.
    pub fn new() -> Self {
        Self {
            inner: Arc::new(SharedTranscriptionEngineInner {
                engine: OnceLock::new(),
                status: Mutex::new(TranscriptionRuntimeStatus::default()),
            }),
        }
    }

    /// Return the ready engine if startup has completed.
    pub fn get(&self) -> Option<&Arc<dyn TranscriptionEngine>> {
        self.inner.engine.get()
    }

    /// Mark startup as disabled by settings.
    pub fn mark_disabled(&self) {
        self.set_status(TranscriptionRuntimeState::Disabled, None);
    }

    /// Mark startup as in progress.
    pub fn mark_loading(&self, message: impl Into<String>) {
        self.set_status(TranscriptionRuntimeState::Loading, Some(message.into()));
    }

    /// Store the ready engine. Returns false if a previous engine already won.
    pub fn mark_ready(&self, engine: Arc<dyn TranscriptionEngine>) -> bool {
        let inserted = self.inner.engine.set(engine).is_ok();
        if inserted {
            self.set_status(TranscriptionRuntimeState::Ready, None);
        }
        inserted
    }

    /// Mark startup as failed.
    pub fn mark_failed(&self, message: impl Into<String>) {
        self.set_status(TranscriptionRuntimeState::Failed, Some(message.into()));
    }

    /// Return a copy of the current runtime status.
    pub fn status(&self) -> TranscriptionRuntimeStatus {
        self.inner
            .status
            .lock()
            .expect("transcription runtime status poisoned")
            .clone()
    }

    fn set_status(&self, state: TranscriptionRuntimeState, message: Option<String>) {
        let mut guard = self
            .inner
            .status
            .lock()
            .expect("transcription runtime status poisoned");
        *guard = TranscriptionRuntimeStatus { state, message };
    }
}

impl Default for SharedTranscriptionEngine {
    fn default() -> Self {
        Self::new()
    }
}

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

    #[test]
    fn shared_engine_tracks_startup_state() {
        let shared = SharedTranscriptionEngine::new();
        assert_eq!(shared.status().state, TranscriptionRuntimeState::NotStarted);

        shared.mark_loading("loading model");
        let loading = shared.status();
        assert_eq!(loading.state, TranscriptionRuntimeState::Loading);
        assert_eq!(loading.message.as_deref(), Some("loading model"));

        shared.mark_failed("download failed");
        let failed = shared.status();
        assert_eq!(failed.state, TranscriptionRuntimeState::Failed);
        assert_eq!(failed.message.as_deref(), Some("download failed"));
    }
}
