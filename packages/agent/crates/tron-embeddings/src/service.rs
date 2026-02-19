//! Embedding service trait and mock implementation.

use async_trait::async_trait;
use sha2::{Digest, Sha256};
use std::sync::atomic::{AtomicBool, Ordering};

use crate::errors::{EmbeddingError, Result};
use crate::normalize::l2_normalize;

/// Trait for embedding text into vectors.
#[async_trait]
pub trait EmbeddingService: Send + Sync {
    /// Embed a batch of texts.
    async fn embed(&self, texts: &[String]) -> Result<Vec<Vec<f32>>>;

    /// Embed a single text (default: calls `embed` with one item).
    async fn embed_single(&self, text: &str) -> Result<Vec<f32>> {
        let results = self.embed(&[text.to_string()]).await?;
        results
            .into_iter()
            .next()
            .ok_or_else(|| EmbeddingError::Inference("empty result".into()))
    }

    /// Whether the service is ready for inference.
    fn is_ready(&self) -> bool;

    /// Whether the model is cached locally.
    fn is_model_cached(&self) -> bool;

    /// Output embedding dimensions.
    fn dimensions(&self) -> usize;
}

/// Mock embedding service for testing.
///
/// Generates deterministic embeddings by hashing input text with SHA-256,
/// using the hash bytes as seeds for the vector components.
pub struct MockEmbeddingService {
    dims: usize,
    ready: AtomicBool,
}

impl MockEmbeddingService {
    /// Create a new mock service with the given dimensions.
    pub fn new(dims: usize) -> Self {
        Self {
            dims,
            ready: AtomicBool::new(true),
        }
    }

    /// Set whether this mock is ready.
    pub fn set_ready(&self, ready: bool) {
        self.ready.store(ready, Ordering::SeqCst);
    }

    fn hash_to_vector(&self, text: &str) -> Vec<f32> {
        let mut hasher = Sha256::new();
        hasher.update(text.as_bytes());
        let hash = hasher.finalize();

        let mut v: Vec<f32> = (0..self.dims)
            .map(|i| {
                let byte_idx = i % hash.len();
                // Map byte to [-1, 1] range
                (f32::from(hash[byte_idx]) / 127.5) - 1.0
            })
            .collect();

        l2_normalize(&mut v);
        v
    }
}

#[async_trait]
impl EmbeddingService for MockEmbeddingService {
    async fn embed(&self, texts: &[String]) -> Result<Vec<Vec<f32>>> {
        if !self.is_ready() {
            return Err(EmbeddingError::NotReady);
        }
        Ok(texts.iter().map(|t| self.hash_to_vector(t)).collect())
    }

    fn is_ready(&self) -> bool {
        self.ready.load(Ordering::SeqCst)
    }

    fn is_model_cached(&self) -> bool {
        true
    }

    fn dimensions(&self) -> usize {
        self.dims
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::normalize::l2_norm;

    #[tokio::test]
    async fn mock_single_returns_correct_dims() {
        let svc = MockEmbeddingService::new(512);
        let result = svc.embed_single("test").await.unwrap();
        assert_eq!(result.len(), 512);
    }

    #[tokio::test]
    async fn mock_batch_correct_count() {
        let svc = MockEmbeddingService::new(512);
        let texts = vec!["a".to_string(), "b".to_string(), "c".to_string()];
        let results = svc.embed(&texts).await.unwrap();
        assert_eq!(results.len(), 3);
        for r in &results {
            assert_eq!(r.len(), 512);
        }
    }

    #[tokio::test]
    async fn mock_deterministic_same_input() {
        let svc = MockEmbeddingService::new(512);
        let a = svc.embed_single("hello world").await.unwrap();
        let b = svc.embed_single("hello world").await.unwrap();
        assert_eq!(a, b);
    }

    #[tokio::test]
    async fn mock_different_inputs_different_outputs() {
        let svc = MockEmbeddingService::new(512);
        let a = svc.embed_single("hello").await.unwrap();
        let b = svc.embed_single("world").await.unwrap();
        assert_ne!(a, b);
    }

    #[tokio::test]
    async fn mock_not_ready_returns_error() {
        let svc = MockEmbeddingService::new(512);
        svc.set_ready(false);
        let result = svc.embed_single("test").await;
        assert!(matches!(result, Err(EmbeddingError::NotReady)));
    }

    #[tokio::test]
    async fn embed_single_default_impl() {
        let svc = MockEmbeddingService::new(64);
        let result = svc.embed_single("test").await.unwrap();
        assert_eq!(result.len(), 64);
        let norm = l2_norm(&result);
        assert!((norm - 1.0).abs() < 1e-5, "should be unit vector");
    }
}
