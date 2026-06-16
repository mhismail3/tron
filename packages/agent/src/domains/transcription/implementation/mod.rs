//! Local transcription implementation.
//!
//! The Rust boundary is a small async trait. The default implementation uses a
//! Python `parakeet-mlx` sidecar and keeps all venv/model cache files under
//! `~/.tron/internal/transcription/`.

#[path = "runtime/mlx.rs"]
pub mod mlx;
pub mod types;
#[path = "runtime/venv.rs"]
pub mod venv;

pub use mlx::MlxEngine;
pub use types::{
    ResultExt, SharedTranscriptionEngine, TranscriptionEngine, TranscriptionError,
    TranscriptionResult,
};
