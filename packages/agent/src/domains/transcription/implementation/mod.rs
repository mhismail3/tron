//! Transcription engine using a parakeet-mlx Python sidecar.
//!
//! Replaces the previous ONNX-native approach with an MLX backend (Apple Silicon)
//! that correctly handles speech onset (no first-word-loss).
//! The sidecar is disabled by default on fresh installs because enabling it
//! downloads a local Parakeet model. The Mac wizard or iOS settings flip
//! `server.transcription.enabled` after the user opts in.
//!
//! # Architecture
//!
//! ```text
//! audio bytes → temp file → worker.py (stdin/stdout JSON lines)
//! → parakeet-mlx (MLX backend) → text result
//! ```
//!
//! The app bundle ships only `worker.py` and `requirements.txt`. The Mac
//! wrapper copies those files into `~/.tron/internal/transcription/` during
//! first-run setup; the Python venv and HuggingFace cache are created there
//! by the sidecar only after transcription is enabled.
//!
//! ## Module Position
//!
//! Standalone (no tron module dependencies).
//! Depended on by: server.

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
