//! Rust-native transcription engine using ONNX Runtime with the parakeet-tdt-0.6b-v3 model.
//!
//! Replaces the Python `FastAPI` sidecar with zero external dependencies.
//!
//! # Architecture
//!
//! ```text
//! audio bytes → symphonia decode → rubato resample to 16kHz mono f32
//! → nemo128.onnx (preprocessor) → mel features [1, 128, T]
//! → encoder-model.onnx → encoder output [1, T', 1024]
//! → TDT greedy decode (decoder_joint-model.onnx in loop) → token IDs
//! → vocab.txt lookup → text string
//! ```
//!
//! ## Crate Position
//!
//! Standalone (no tron crate dependencies).
//! Depended on by: tron-server.

// Always available (no heavy deps)
pub mod model;
pub mod types;

// Feature-gated (require ort + symphonia + rubato)
#[cfg(feature = "ort")]
pub(crate) mod audio;
#[cfg(feature = "ort")]
pub(crate) mod decoder;
#[cfg(feature = "ort")]
pub mod engine;

pub use types::{ResultExt, TranscriptionError, TranscriptionResult};
#[cfg(feature = "ort")]
pub use engine::TranscriptionEngine;
