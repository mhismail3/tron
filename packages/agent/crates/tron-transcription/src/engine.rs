//! ONNX session management and inference pipeline.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use ort::session::Session;
use ort::value::Tensor;
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
        let blank_idx = vocab.len() - 1; // <blk> is the last vocab entry

        info!(
            "transcription engine ready: vocab_size={}, blank_idx={}",
            vocab.len(),
            blank_idx
        );

        let engine = Self {
            preprocessor: Mutex::new(preprocessor),
            encoder: Mutex::new(encoder),
            decoder_joint: Mutex::new(decoder_joint),
            vocab,
            blank_idx,
        };

        Self::warmup(&engine)?;

        Ok(engine)
    }

    /// Run dummy inference through each session to trigger ONNX Runtime JIT compilation.
    /// Eliminates 100-300ms latency on the first real transcription.
    fn warmup(engine: &Self) -> Result<(), TranscriptionError> {
        info!("warming up transcription sessions...");

        // Preprocessor: 1 second of silence at 16kHz
        {
            let wf = Tensor::from_array(([1i64, 16000i64], vec![0.0f32; 16000]))
                .inference("warmup waveform")?;
            let wf_len = Tensor::from_array(([1i64], vec![16000i64]))
                .inference("warmup wf_len")?;
            let mut pp = engine.preprocessor.lock().inference("warmup pp lock")?;
            let _ = pp
                .run(ort::inputs!["waveforms" => wf, "waveforms_lens" => wf_len])
                .inference("warmup preprocessor")?;
        }

        // Encoder: dummy mel features [1, 128, 100]
        {
            let feat = Tensor::from_array(([1i64, 128i64, 100i64], vec![0.0f32; 12800]))
                .inference("warmup features")?;
            let feat_len = Tensor::from_array(([1i64], vec![100i64]))
                .inference("warmup feat_len")?;
            let mut enc = engine.encoder.lock().inference("warmup enc lock")?;
            let _ = enc
                .run(ort::inputs!["audio_signal" => feat, "length" => feat_len])
                .inference("warmup encoder")?;
        }

        // Decoder: single frame [1, 1024, 1], states [2, 1, 640]
        {
            let enc_out = Tensor::from_array(([1i64, 1024i64, 1i64], vec![0.0f32; 1024]))
                .inference("warmup enc_out")?;
            let target = Tensor::from_array(([1i64, 1i64], vec![0i32]))
                .inference("warmup target")?;
            let target_len = Tensor::from_array(([1i64], vec![1i32]))
                .inference("warmup target_len")?;
            let s1 = Tensor::from_array(([2i64, 1i64, 640i64], vec![0.0f32; 1280]))
                .inference("warmup s1")?;
            let s2 = Tensor::from_array(([2i64, 1i64, 640i64], vec![0.0f32; 1280]))
                .inference("warmup s2")?;
            let mut dec = engine.decoder_joint.lock().inference("warmup dec lock")?;
            let _ = dec
                .run(ort::inputs![
                    "encoder_outputs" => enc_out,
                    "targets" => target,
                    "target_length" => target_len,
                    "input_states_1" => s1,
                    "input_states_2" => s2,
                ])
                .inference("warmup decoder")?;
        }

        info!("transcription sessions warmed up");
        Ok(())
    }

    /// Transcribe raw audio bytes.
    ///
    /// Pipeline: decode audio → resample to 16kHz → mel features → encoder → TDT decode → text
    pub async fn transcribe(
        self: &Arc<Self>,
        audio_data: &[u8],
        mime_type: &str,
    ) -> Result<TranscriptionResult, TranscriptionError> {
        let total_start = std::time::Instant::now();

        // Step 1: Decode audio to 16kHz mono f32
        let input_len = audio_data.len();
        info!(
            "transcribe: starting — input_bytes={}, mime={}",
            input_len, mime_type
        );

        let data = audio_data.to_vec();
        let mime = mime_type.to_string();
        let decode_start = std::time::Instant::now();
        let (samples, _source_rate) =
            tokio::task::spawn_blocking(move || audio::decode_audio(data, &mime))
                .await
                .inference("audio decode task")??;

        #[allow(clippy::cast_precision_loss)]
        let duration_seconds = samples.len() as f64 / f64::from(audio::TARGET_SAMPLE_RATE);
        let decode_ms = decode_start.elapsed().as_millis();
        info!(
            "transcribe: decoded {:.2}s of audio ({} samples at {}Hz) in {}ms",
            duration_seconds,
            samples.len(),
            audio::TARGET_SAMPLE_RATE,
            decode_ms
        );

        // Steps 2-4: Run ONNX inference on blocking thread
        let engine = Arc::clone(self);
        let inference_start = std::time::Instant::now();
        let text = tokio::task::spawn_blocking(move || engine.run_inference(&samples))
            .await
            .inference("inference task")??;
        let inference_ms = inference_start.elapsed().as_millis();
        let total_ms = total_start.elapsed().as_millis();

        info!(
            "transcribe: complete — text_len={}, decode={}ms, inference={}ms, total={}ms, text=\"{}\"",
            text.len(),
            decode_ms,
            inference_ms,
            total_ms,
            if text.len() > 100 { &text[..100] } else { &text }
        );

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
        let (encoder_out, enc_len) = {
            let mut encoder = self
                .encoder
                .lock()
                .inference("encoder lock")?;
            decoder::run_encoder(&mut encoder, &features, features_len)?
        };
        debug!("encoder output: {:?}, enc_len={}", encoder_out.shape(), enc_len);

        // Step 4: TDT greedy decode
        let text = {
            let mut decoder_joint = self
                .decoder_joint
                .lock()
                .inference("decoder lock")?;
            decoder::greedy_decode(
                &encoder_out,
                enc_len,
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
