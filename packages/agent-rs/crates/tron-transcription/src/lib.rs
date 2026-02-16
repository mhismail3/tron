//! Rust-native transcription engine using ONNX Runtime with the parakeet-tdt-0.6b-v3 model.
//!
//! Replaces the Python FastAPI sidecar with zero external dependencies.
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

pub mod audio;
pub mod decoder;
pub mod engine;
pub mod model;
pub mod types;

pub use engine::TranscriptionEngine;
pub use types::{TranscriptionError, TranscriptionResult};
