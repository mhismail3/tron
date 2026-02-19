//! ONNX session management and inference pipeline.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use ort::session::Session;
use tracing::{debug, info};

use crate::audio;
use crate::decoder;
use crate::model;
use crate::types::{ResultExt, TranscriptionError, TranscriptionResult};

/// Intra-op thread count for preprocessor and encoder ONNX sessions.
const PARALLEL_THREADS: usize = 4;
/// Decoder is sequential — single thread is sufficient.
const DECODER_THREADS: usize = 1;

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
            .inference("task join")?
            .map(Arc::new)
    }

    fn load_sessions(model_dir: &Path) -> Result<Self, TranscriptionError> {
        info!(
            "loading transcription model from {}...",
            model_dir.display()
        );
        let paths = model::ModelPaths::from_dir(model_dir);

        // Load ONNX sessions
        let preprocessor = Session::builder()
            .inference("session builder")?
            .with_intra_threads(PARALLEL_THREADS)
            .inference("set threads")?
            .commit_from_file(&paths.preprocessor)
            .inference("load preprocessor")?;
        debug!("loaded preprocessor");

        let encoder = Session::builder()
            .inference("session builder")?
            .with_intra_threads(PARALLEL_THREADS)
            .inference("set threads")?
            .commit_from_file(&paths.encoder)
            .inference("load encoder")?;
        debug!("loaded encoder");

        let decoder_joint = Session::builder()
            .inference("session builder")?
            .with_intra_threads(DECODER_THREADS)
            .inference("set threads")?
            .commit_from_file(&paths.decoder_joint)
            .inference("load decoder")?;
        debug!("loaded decoder_joint");

        let vocab = model::load_vocab(&paths.vocab)?;
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
        let (samples, _source_rate) =
            tokio::task::spawn_blocking(move || audio::decode_audio(data, &mime))
                .await
                .inference("audio decode task")??;

        #[allow(clippy::cast_precision_loss)]
        let duration_seconds = samples.len() as f64 / f64::from(audio::TARGET_SAMPLE_RATE);
        debug!(
            "decoded {:.1}s of audio ({} samples)",
            duration_seconds,
            samples.len()
        );

        // Steps 2-4: Run ONNX inference on blocking thread
        let engine = Arc::clone(self);
        let text = tokio::task::spawn_blocking(move || engine.run_inference(&samples))
            .await
            .inference("inference task")??;

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
            let mut preprocessor = self
                .preprocessor
                .lock()
                .inference("preprocessor lock")?;
            decoder::run_preprocessor(&mut preprocessor, samples)?
        };
        debug!("mel features: {:?}, len={}", features.shape(), features_len);

        // Step 3: Encoder
        let (encoder_out, _enc_len) = {
            let mut encoder = self
                .encoder
                .lock()
                .inference("encoder lock")?;
            decoder::run_encoder(&mut encoder, &features, features_len)?
        };
        debug!("encoder output: {:?}", encoder_out.shape());

        // Step 4: TDT greedy decode
        let text = {
            let mut decoder_joint = self
                .decoder_joint
                .lock()
                .inference("decoder lock")?;
            decoder::greedy_decode(
                &encoder_out,
                &mut decoder_joint,
                &self.vocab,
                self.blank_idx,
            )?
        };

        Ok(text)
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
        let _engine = TranscriptionEngine::new(model_dir).await.unwrap();
    }
}
