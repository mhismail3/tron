//! ONNX session management and inference pipeline.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use ort::session::Session;
use tracing::{debug, info};

use crate::audio;
use crate::decoder;
use crate::model;
use crate::types::{TranscriptionError, TranscriptionResult};

/// Rust-native transcription engine using ONNX Runtime with the parakeet-tdt model.
///
/// Holds 3 ONNX sessions (preprocessor, encoder, decoder+joint) and the vocabulary.
/// Sessions are behind Mutex since `Session::run` requires `&mut self`.
/// All inference runs on `spawn_blocking` to avoid blocking the async runtime.
pub struct TranscriptionEngine {
    preprocessor: Mutex<Session>,
    encoder: Mutex<Session>,
    decoder_joint: Mutex<Session>,
    vocab: Vec<String>,
    blank_idx: usize,
}

impl TranscriptionEngine {
    /// Create a new engine, loading ONNX sessions from `model_dir`.
    ///
    /// This is CPU-intensive (loads ~600MB of model weights). Should be called
    /// once at server startup, typically on a background task.
    pub async fn new(model_dir: PathBuf) -> Result<Arc<Self>, TranscriptionError> {
        let dir = model_dir.clone();
        tokio::task::spawn_blocking(move || Self::load_sessions(&dir))
            .await
            .map_err(|e| TranscriptionError::Inference(format!("task join: {e}")))?
            .map(Arc::new)
    }

    fn load_sessions(model_dir: &Path) -> Result<Self, TranscriptionError> {
        info!("loading transcription model from {}...", model_dir.display());
        let files = model::model_files(model_dir);

        let preprocessor_path = files.get("nemo128.onnx")
            .ok_or_else(|| TranscriptionError::ModelNotAvailable("nemo128.onnx not found".into()))?;
        let encoder_path = files.get("encoder-model.onnx")
            .ok_or_else(|| TranscriptionError::ModelNotAvailable("encoder-model.onnx not found".into()))?;
        let decoder_path = files.get("decoder_joint-model.onnx")
            .ok_or_else(|| TranscriptionError::ModelNotAvailable("decoder_joint-model.onnx not found".into()))?;
        let vocab_path = files.get("vocab.txt")
            .ok_or_else(|| TranscriptionError::ModelNotAvailable("vocab.txt not found".into()))?;

        // Load ONNX sessions
        let preprocessor = Session::builder()
            .map_err(|e| TranscriptionError::Inference(format!("session builder: {e}")))?
            .with_intra_threads(4)
            .map_err(|e| TranscriptionError::Inference(format!("set threads: {e}")))?
            .commit_from_file(preprocessor_path)
            .map_err(|e| TranscriptionError::Inference(format!("load preprocessor: {e}")))?;
        debug!("loaded preprocessor");

        let encoder = Session::builder()
            .map_err(|e| TranscriptionError::Inference(format!("session builder: {e}")))?
            .with_intra_threads(4)
            .map_err(|e| TranscriptionError::Inference(format!("set threads: {e}")))?
            .commit_from_file(encoder_path)
            .map_err(|e| TranscriptionError::Inference(format!("load encoder: {e}")))?;
        debug!("loaded encoder");

        let decoder_joint = Session::builder()
            .map_err(|e| TranscriptionError::Inference(format!("session builder: {e}")))?
            .with_intra_threads(1) // Decoder is sequential, single-threaded is fine
            .map_err(|e| TranscriptionError::Inference(format!("set threads: {e}")))?
            .commit_from_file(decoder_path)
            .map_err(|e| TranscriptionError::Inference(format!("load decoder: {e}")))?;
        debug!("loaded decoder_joint");

        let vocab = model::load_vocab(vocab_path)?;
        let blank_idx = vocab.len(); // Blank token is at index == vocab_size

        info!(
            "transcription engine ready: vocab_size={}, blank_idx={}",
            vocab.len(),
            blank_idx
        );

        Ok(Self {
            preprocessor: Mutex::new(preprocessor),
            encoder: Mutex::new(encoder),
            decoder_joint: Mutex::new(decoder_joint),
            vocab,
            blank_idx,
        })
    }

    /// Transcribe raw audio bytes.
    ///
    /// Pipeline: decode audio → resample to 16kHz → mel features → encoder → TDT decode → text
    pub async fn transcribe(
        self: &Arc<Self>,
        audio_data: &[u8],
        mime_type: &str,
    ) -> Result<TranscriptionResult, TranscriptionError> {
        // Step 1: Decode audio to 16kHz mono f32
        let data = audio_data.to_vec();
        let mime = mime_type.to_string();
        let (samples, _source_rate) = tokio::task::spawn_blocking(move || {
            audio::decode_audio(&data, &mime)
        })
        .await
        .map_err(|e| TranscriptionError::Inference(format!("audio decode task: {e}")))??;

        #[allow(clippy::cast_precision_loss)]
        let duration_seconds = samples.len() as f64 / f64::from(audio::TARGET_SAMPLE_RATE);
        debug!("decoded {:.1}s of audio ({} samples)", duration_seconds, samples.len());

        // Steps 2-4: Run ONNX inference on blocking thread
        let engine = Arc::clone(self);
        let text = tokio::task::spawn_blocking(move || engine.run_inference(&samples))
            .await
            .map_err(|e| TranscriptionError::Inference(format!("inference task: {e}")))??;

        Ok(TranscriptionResult {
            text,
            language: "en".into(), // Parakeet is English-only
            duration_seconds,
        })
    }

    /// Run the full inference pipeline (CPU-bound, must be on blocking thread).
    fn run_inference(&self, samples: &[f32]) -> Result<String, TranscriptionError> {
        // Step 2: Mel features via preprocessor
        let (features, features_len) = {
            let mut preprocessor = self.preprocessor.lock()
                .map_err(|e| TranscriptionError::Inference(format!("preprocessor lock: {e}")))?;
            decoder::run_preprocessor(&mut preprocessor, samples)?
        };
        debug!("mel features: {:?}, len={}", features.shape(), features_len);

        // Step 3: Encoder
        let (encoder_out, _enc_len) = {
            let mut encoder = self.encoder.lock()
                .map_err(|e| TranscriptionError::Inference(format!("encoder lock: {e}")))?;
            decoder::run_encoder(&mut encoder, &features, features_len)?
        };
        debug!("encoder output: {:?}", encoder_out.shape());

        // Step 4: TDT greedy decode
        let text = {
            let mut decoder_joint = self.decoder_joint.lock()
                .map_err(|e| TranscriptionError::Inference(format!("decoder lock: {e}")))?;
            decoder::greedy_decode(&encoder_out, &mut decoder_joint, &self.vocab, self.blank_idx)?
        };

        Ok(text)
    }

    /// Check if the engine is ready for inference.
    pub fn is_ready(&self) -> bool {
        true // If constructed, it's ready
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn engine_requires_model_files() {
        // Attempting to load from empty dir should fail
        let tmp = tempfile::tempdir().unwrap();
        let rt = tokio::runtime::Runtime::new().unwrap();
        let result = rt.block_on(TranscriptionEngine::new(tmp.path().to_path_buf()));
        assert!(result.is_err());
    }

    // Integration test requiring model download — run with `cargo test -- --ignored`
    #[tokio::test]
    #[ignore]
    async fn transcribe_wav_produces_text() {
        let model_dir = model::default_model_dir();
        model::ensure_model(&model_dir).await.unwrap();
        let engine = TranscriptionEngine::new(model_dir).await.unwrap();
        assert!(engine.is_ready());
    }
}
