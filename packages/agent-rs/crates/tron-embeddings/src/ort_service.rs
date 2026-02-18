//! ONNX Runtime embedding service (feature-gated behind `ort`).
//!
//! Downloads Qwen3-Embedding-0.6B-ONNX via `hf-hub`, tokenizes with
//! `tokenizers`, runs inference via `ort`, then applies last-token pooling
//! and Matryoshka truncation (1024d → 512d) with L2 normalization.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};

use async_trait::async_trait;
use tracing::{debug, info};

use crate::config::EmbeddingConfig;
use crate::errors::{EmbeddingError, Result};
use crate::normalize::matryoshka_truncate;
use crate::service::EmbeddingService;

/// Combined session + tokenizer state behind a single mutex.
struct InferenceState {
    session: ort::session::Session,
    tokenizer: tokenizers::Tokenizer,
}

/// ONNX-based embedding service using Qwen3-Embedding-0.6B.
pub struct OnnxEmbeddingService {
    config: EmbeddingConfig,
    state: parking_lot::Mutex<Option<InferenceState>>,
    ready: AtomicBool,
}

impl OnnxEmbeddingService {
    /// Create a new ONNX embedding service (not yet initialized).
    pub fn new(config: EmbeddingConfig) -> Self {
        Self {
            config,
            state: parking_lot::Mutex::new(None),
            ready: AtomicBool::new(false),
        }
    }

    /// Initialize the service: download model + tokenizer, create ONNX session.
    ///
    /// Does blocking I/O internally (model download, file reads).
    /// Caller should `tokio::spawn` this as a fire-and-forget task.
    pub async fn initialize(&self) -> Result<()> {
        let (tokenizer, session) = tokio::task::spawn_blocking({
            let config = self.config.clone();
            move || -> Result<(tokenizers::Tokenizer, ort::session::Session)> {
                initialize_inner(&config).map_err(|e| EmbeddingError::Internal(e.to_string()))
            }
        })
        .await
        .map_err(|e| EmbeddingError::Internal(format!("join error: {e}")))??;

        *self.state.lock() = Some(InferenceState { session, tokenizer });
        self.ready.store(true, Ordering::SeqCst);

        info!("ONNX embedding service ready");
        Ok(())
    }

    /// Get the expected model cache path.
    pub fn model_path(&self) -> PathBuf {
        PathBuf::from(self.config.resolved_cache_dir())
    }
}

/// Initialize model: download via `hf-hub`, create tokenizer and ONNX session.
///
/// Uses `Box<dyn Error>` internally so all calls can use `?` directly.
/// The caller maps the error to `EmbeddingError::Internal` at the boundary.
fn initialize_inner(
    config: &EmbeddingConfig,
) -> std::result::Result<
    (tokenizers::Tokenizer, ort::session::Session),
    Box<dyn std::error::Error + Send + Sync>,
> {
    let cache_dir = config.resolved_cache_dir();
    debug!(cache_dir, model = %config.model, "downloading model via hf-hub");

    let api = hf_hub::api::sync::ApiBuilder::new()
        .with_cache_dir(PathBuf::from(&cache_dir))
        .build()?;

    let repo = api.model(config.model.clone());

    let model_filename = format!("onnx/model_{}.onnx", config.dtype);
    let model_path = repo.get(&model_filename)?;
    let tokenizer_path = repo.get("tokenizer.json")?;

    info!(model = %model_path.display(), tokenizer = %tokenizer_path.display(), "model files ready");

    let tok = tokenizers::Tokenizer::from_file(&tokenizer_path)
        .map_err(|e| format!("tokenizer load: {e}"))?;

    let session = ort::session::Session::builder()?
        .with_intra_threads(2)?
        .with_log_level(ort::logging::LogLevel::Warning)?
        .commit_from_file(&model_path)?;

    info!(model = %model_path.display(), "ONNX model loaded");
    Ok((tok, session))
}

/// Run inference on a batch of texts.
///
/// Delegates to `run_inference_inner` which uses `Box<dyn Error>` internally,
/// then maps any error to `EmbeddingError::Inference` at the boundary.
fn run_inference(
    session: &mut ort::session::Session,
    tokenizer: &tokenizers::Tokenizer,
    texts: &[String],
    config: &EmbeddingConfig,
) -> Result<Vec<Vec<f32>>> {
    run_inference_inner(session, tokenizer, texts, config)
        .map_err(|e| EmbeddingError::Inference(e.to_string()))
}

fn run_inference_inner(
    session: &mut ort::session::Session,
    tokenizer: &tokenizers::Tokenizer,
    texts: &[String],
    config: &EmbeddingConfig,
) -> std::result::Result<Vec<Vec<f32>>, Box<dyn std::error::Error + Send + Sync>> {
    if texts.is_empty() {
        return Ok(Vec::new());
    }

    let encodings = tokenizer.encode_batch(texts.to_vec(), true)?;

    let max_len = encodings
        .iter()
        .map(|e| e.get_ids().len())
        .max()
        .unwrap_or(0);
    if max_len == 0 {
        return Err("empty tokenization".into());
    }

    let batch_size = texts.len();

    let mut input_ids = vec![0i64; batch_size * max_len];
    let mut attention_mask = vec![0i64; batch_size * max_len];
    let mut position_ids = vec![0i64; batch_size * max_len];

    for (i, enc) in encodings.iter().enumerate() {
        let ids = enc.get_ids();
        let mask = enc.get_attention_mask();
        let offset = i * max_len;
        for (j, &id) in ids.iter().enumerate() {
            input_ids[offset + j] = i64::from(id);
        }
        for (j, &m) in mask.iter().enumerate() {
            attention_mask[offset + j] = i64::from(m);
            if m != 0 {
                #[allow(clippy::cast_possible_wrap)]
                {
                    position_ids[offset + j] = j as i64;
                }
            }
        }
    }

    #[allow(clippy::cast_possible_wrap)]
    let shape = vec![batch_size as i64, max_len as i64];

    let input_ids_tensor = ort::value::Tensor::from_array((shape.clone(), input_ids))?;
    let attention_mask_tensor =
        ort::value::Tensor::from_array((shape.clone(), attention_mask.clone()))?;
    let position_ids_tensor = ort::value::Tensor::from_array((shape, position_ids))?;

    let outputs = session.run(ort::inputs![
        input_ids_tensor,
        attention_mask_tensor,
        position_ids_tensor
    ])?;

    let output_value = &outputs[0];
    let (output_shape, output_data) = output_value.try_extract_tensor::<f32>()?;

    #[allow(clippy::cast_sign_loss, clippy::cast_possible_truncation)]
    let dims: Vec<usize> = output_shape.iter().map(|&d| d as usize).collect();
    if dims.len() != 3 || dims[0] != batch_size {
        return Err(format!("unexpected output shape: {output_shape:?}").into());
    }
    let seq_len_out = dims[1];
    let hidden_dim = dims[2];

    let mut results = Vec::with_capacity(batch_size);
    for i in 0..batch_size {
        let last_idx = last_non_padding_index(&attention_mask, i, max_len);
        let base = i * seq_len_out * hidden_dim + last_idx * hidden_dim;
        let embedding: Vec<f32> = output_data[base..base + hidden_dim].to_vec();
        let truncated = matryoshka_truncate(&embedding, config.dimensions);
        results.push(truncated);
    }

    Ok(results)
}

/// Find the index of the last non-padding token for batch item `i`.
fn last_non_padding_index(attention_mask: &[i64], batch_idx: usize, seq_len: usize) -> usize {
    let offset = batch_idx * seq_len;
    let mut last = 0;
    for j in 0..seq_len {
        if attention_mask[offset + j] != 0 {
            last = j;
        }
    }
    last
}

#[async_trait]
impl EmbeddingService for OnnxEmbeddingService {
    async fn embed(&self, texts: &[String]) -> Result<Vec<Vec<f32>>> {
        if !self.is_ready() {
            return Err(EmbeddingError::NotReady);
        }

        // Take state out of mutex (brief lock), run inference on blocking thread,
        // then restore state. This avoids holding a sync mutex across async work.
        let mut state = self.state.lock().take().ok_or(EmbeddingError::NotReady)?;
        let config = self.config.clone();
        let texts = texts.to_vec();

        let (result, returned_state) = tokio::task::spawn_blocking(move || {
            let r = run_inference(&mut state.session, &state.tokenizer, &texts, &config);
            (r, state)
        })
        .await
        .map_err(|e| EmbeddingError::Internal(format!("join: {e}")))?;

        // Restore state even on inference error (state is still valid)
        *self.state.lock() = Some(returned_state);
        result
    }

    fn is_ready(&self) -> bool {
        self.ready.load(Ordering::SeqCst)
    }

    fn is_model_cached(&self) -> bool {
        self.model_path().exists()
    }

    fn dimensions(&self) -> usize {
        self.config.dimensions
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ort_service_implements_trait() {
        fn assert_embedding_service<T: EmbeddingService>() {}
        assert_embedding_service::<OnnxEmbeddingService>();
    }

    #[tokio::test]
    async fn ort_service_not_ready_without_init() {
        let svc = OnnxEmbeddingService::new(EmbeddingConfig::default());
        assert!(!svc.is_ready());
        let result = svc.embed(&["test".to_string()]).await;
        assert!(matches!(result, Err(EmbeddingError::NotReady)));
    }

    #[test]
    fn last_non_padding_basic() {
        let mask = vec![1i64, 1, 1, 0, 0];
        assert_eq!(last_non_padding_index(&mask, 0, 5), 2);
    }

    #[test]
    fn last_non_padding_all_ones() {
        let mask = vec![1i64, 1, 1, 1];
        assert_eq!(last_non_padding_index(&mask, 0, 4), 3);
    }

    #[test]
    fn last_non_padding_batch_offset() {
        // batch of 2, seq_len 3
        let mask = vec![1i64, 1, 0, 1, 1, 1];
        assert_eq!(last_non_padding_index(&mask, 0, 3), 1);
        assert_eq!(last_non_padding_index(&mask, 1, 3), 2);
    }
}
