//! Local transcription implementation.
//!
//! The Rust boundary is a small async trait. The default implementation uses a
//! Python `parakeet-mlx` sidecar and keeps all venv/model cache files under
//! `~/.tron/internal/transcription/`.

pub mod runtime;
pub mod types;

pub use runtime::mlx::MlxEngine;
pub use types::{
    ResultExt, SharedTranscriptionEngine, TranscriptionEngine, TranscriptionError,
    TranscriptionResult, TranscriptionRuntimeState, TranscriptionRuntimeStatus,
};
