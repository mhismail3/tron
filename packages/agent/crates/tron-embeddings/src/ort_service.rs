//! ONNX Runtime embedding service (feature-gated behind `ort`).
//!
//! Downloads EmbeddingGemma-300M-ONNX via `hf-hub`, tokenizes with
//! `tokenizers`, runs inference via `ort`, then applies mean pooling
//! and Matryoshka truncation (768d → 512d) with L2 normalization.

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

/// ONNX-based embedding service using EmbeddingGemma-300M.
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
    // EmbeddingGemma uses split ONNX files (model.onnx + model.onnx_data).
    // Download the external data file to the same directory so ONNX Runtime finds it.
    let model_data_filename = format!("onnx/model_{}.onnx_data", config.dtype);
    let _data_path = repo.get(&model_data_filename).ok();
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

    let inputs: Vec<tokenizers::EncodeInput> = texts.iter().map(|s| s.as_str().into()).collect();
    let encodings = tokenizer.encode_batch(inputs, true)?;

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

    // Some ONNX models accept only input_ids + attention_mask (2 inputs),
    // others also need position_ids (3 inputs). Check by name, not count.
    let has_position_ids = session.inputs().iter().any(|i| i.name() == "position_ids");
    let outputs = if has_position_ids {
        let position_ids_tensor = ort::value::Tensor::from_array((shape, position_ids))?;
        session.run(ort::inputs![
            input_ids_tensor,
            attention_mask_tensor,
            position_ids_tensor
        ])?
    } else {
        session.run(ort::inputs![input_ids_tensor, attention_mask_tensor])?
    };

    let output_value = &outputs[0];
    let (output_shape, output_data) = output_value.try_extract_tensor::<f32>()?;

    #[allow(clippy::cast_sign_loss, clippy::cast_possible_truncation)]
    let dims: Vec<usize> = output_shape.iter().map(|&d| d as usize).collect();
    if dims.len() != 3 || dims[0] != batch_size {
        return Err(format!("unexpected output shape: {output_shape:?}").into());
    }
    let seq_len_out = dims[1];
    let hidden_dim = dims[2];

    // Mean pooling: sum(token_embeddings * attention_mask) / sum(attention_mask)
    let mut results = Vec::with_capacity(batch_size);
    for i in 0..batch_size {
        let embedding =
            mean_pool(output_data, &attention_mask, i, max_len, seq_len_out, hidden_dim);
        let truncated = matryoshka_truncate(&embedding, config.dimensions);
        results.push(truncated);
    }

    Ok(results)
}

/// Mean pooling over non-padding tokens for a single batch item.
///
/// For each hidden dimension, sums the token values weighted by the attention mask,
/// then divides by the total number of non-padding tokens.
fn mean_pool(
    output_data: &[f32],
    attention_mask: &[i64],
    batch_idx: usize,
    seq_len: usize,
    seq_len_out: usize,
    hidden_dim: usize,
) -> Vec<f32> {
    let mask_offset = batch_idx * seq_len;
    let data_offset = batch_idx * seq_len_out * hidden_dim;
    let mut sum = vec![0.0f32; hidden_dim];
    let mut mask_sum = 0.0f32;

    for j in 0..seq_len.min(seq_len_out) {
        let mask_val = attention_mask[mask_offset + j] as f32;
        if mask_val > 0.0 {
            mask_sum += mask_val;
            let token_base = data_offset + j * hidden_dim;
            for d in 0..hidden_dim {
                sum[d] += output_data[token_base + d] * mask_val;
            }
        }
    }

    if mask_sum > 0.0 {
        for s in &mut sum[..hidden_dim] {
            *s /= mask_sum;
        }
    }

    sum
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

    fn count_tokens(&self, text: &str) -> usize {
        let guard = self.state.lock();
        if let Some(ref state) = *guard {
            state
                .tokenizer
                .encode(text, false)
                .map_or(text.len() / 4, |enc| enc.len())
        } else {
            text.len() / 4
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn ort_service_not_ready_without_init() {
        let svc = OnnxEmbeddingService::new(EmbeddingConfig::default());
        assert!(!svc.is_ready());
        let result = svc.embed(&["test".to_string()]).await;
        assert!(matches!(result, Err(EmbeddingError::NotReady)));
    }

    #[test]
    fn mean_pool_uniform_mask() {
        // 1 batch item, 3 tokens, 4 hidden dims, all tokens active
        let output_data = vec![
            1.0, 2.0, 3.0, 4.0, // token 0
            5.0, 6.0, 7.0, 8.0, // token 1
            9.0, 10.0, 11.0, 12.0, // token 2
        ];
        let mask = vec![1i64, 1, 1];
        let result = mean_pool(&output_data, &mask, 0, 3, 3, 4);
        assert_eq!(result, vec![5.0, 6.0, 7.0, 8.0]);
    }

    #[test]
    fn mean_pool_with_padding() {
        // 1 batch item, 4 tokens (2 real + 2 padding), 2 hidden dims
        let output_data = vec![
            2.0, 4.0, // token 0 (real)
            6.0, 8.0, // token 1 (real)
            0.0, 0.0, // token 2 (padding)
            0.0, 0.0, // token 3 (padding)
        ];
        let mask = vec![1i64, 1, 0, 0];
        let result = mean_pool(&output_data, &mask, 0, 4, 4, 2);
        assert_eq!(result, vec![4.0, 6.0]);
    }

    #[test]
    fn mean_pool_batch_offset() {
        // 2 batch items, seq_len 2, hidden_dim 2
        let output_data = vec![
            1.0, 2.0, // batch 0, token 0
            3.0, 4.0, // batch 0, token 1
            10.0, 20.0, // batch 1, token 0
            30.0, 40.0, // batch 1, token 1
        ];
        let mask = vec![1i64, 1, 1, 0]; // batch 0: both active, batch 1: only first
        let r0 = mean_pool(&output_data, &mask, 0, 2, 2, 2);
        let r1 = mean_pool(&output_data, &mask, 1, 2, 2, 2);
        assert_eq!(r0, vec![2.0, 3.0]);
        assert_eq!(r1, vec![10.0, 20.0]);
    }

    #[test]
    fn mean_pool_all_padding_returns_zeros() {
        let output_data = vec![1.0, 2.0, 3.0, 4.0];
        let mask = vec![0i64, 0];
        let result = mean_pool(&output_data, &mask, 0, 2, 2, 2);
        assert_eq!(result, vec![0.0, 0.0]);
    }
}
