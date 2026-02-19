//! # tron-embeddings
//!
//! Semantic embeddings and vector search for the Tron agent.
//!
//! Uses Qwen3-Embedding-0.6B with q4 quantization via `ort`:
//! - Tokenize -> inference -> last-token pooling
//! - Matryoshka truncation (1024d -> 512d) + L2 normalization
//! - `SQLite` BLOB storage with brute-force KNN search
//!
//! ## Crate Position
//!
//! Standalone (no tron crate dependencies).
//! Depended on by: tron-server.

#![deny(unsafe_code)]

pub mod config;
pub mod controller;
pub mod errors;
pub mod normalize;
#[cfg(feature = "ort")]
pub mod ort_service;
pub mod service;
pub mod text;
pub mod vector_repo;

pub use config::EmbeddingConfig;
pub use controller::{EmbeddingController, WorkspaceMemory};
pub use errors::{EmbeddingError, Result};
pub use normalize::{
    batch_truncate_normalize, cosine_similarity, euclidean_distance, l2_norm, l2_normalize,
    matryoshka_truncate,
};
pub use service::{EmbeddingService, MockEmbeddingService};
pub use text::build_embedding_text;
pub use vector_repo::{SearchOptions, VectorRepository, VectorSearchResult};
