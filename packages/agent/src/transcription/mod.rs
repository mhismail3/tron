//! Transcription engine using a parakeet-mlx Python sidecar.
//!
//! Replaces the previous ONNX-native approach with an MLX backend (Apple Silicon)
//! that correctly handles speech onset (no first-word-loss).
//!
//! # Architecture
//!
//! ```text
//! audio bytes → temp file → worker.py (stdin/stdout JSON lines)
//! → parakeet-mlx (MLX backend) → text result
//! ```
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
pub use types::{ResultExt, TranscriptionError, TranscriptionResult};
