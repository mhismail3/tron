//! ONNX Runtime embedding service (feature-gated behind `ort`).
//!
//! This is a stub — real ONNX inference requires model download
//! and is tested under a separate integration feature flag.

use async_trait::async_trait;
use std::path::PathBuf;

use crate::config::EmbeddingConfig;
use crate::errors::{EmbeddingError, Result};
use crate::service::EmbeddingService;

/// ONNX-based embedding service using the `ort` crate.
pub struct OnnxEmbeddingService {
    config: EmbeddingConfig,
    ready: bool,
}

impl OnnxEmbeddingService {
    /// Create a new ONNX embedding service (not yet initialized).
    pub fn new(config: EmbeddingConfig) -> Self {
        Self {
            config,
            ready: false,
        }
    }

    /// Get the expected model cache path.
    pub fn model_path(&self) -> PathBuf {
        PathBuf::from(self.config.resolved_cache_dir())
    }
}

#[async_trait]
impl EmbeddingService for OnnxEmbeddingService {
    async fn embed(&self, _texts: &[String]) -> Result<Vec<Vec<f32>>> {
        if !self.ready {
            return Err(EmbeddingError::NotReady);
        }
        Err(EmbeddingError::Internal(
            "ONNX inference not implemented in stub".into(),
        ))
    }

    fn is_ready(&self) -> bool {
        self.ready
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
    async fn ort_service_not_ready_without_model() {
        let svc = OnnxEmbeddingService::new(EmbeddingConfig::default());
        assert!(!svc.is_ready());
        let result = svc.embed(&["test".to_string()]).await;
        assert!(matches!(result, Err(EmbeddingError::NotReady)));
    }
}
