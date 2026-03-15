//! # embeddings
//!
//! Semantic embeddings and vector search for the Tron agent.
//!
//! Uses EmbeddingGemma-300M with q4 quantization via `ort`:
//! - Tokenize -> inference -> mean pooling
//! - Matryoshka truncation (768d -> 512d) + L2 normalization
//! - `SQLite` BLOB storage with brute-force KNN search
//! - Hybrid retrieval: vector cosine + FTS5 BM25 via Reciprocal Rank Fusion
//!
//! ## Module Position
//!
//! Standalone (no tron module dependencies).
//! Depended on by: server.

#![deny(unsafe_code)]

pub mod config;
#[path = "pipeline/controller.rs"]
pub mod controller;
pub mod errors;
#[path = "retrieval/hybrid.rs"]
pub mod hybrid;
#[path = "retrieval/normalize.rs"]
pub mod normalize;
#[cfg(feature = "ort")]
#[path = "pipeline/ort_service.rs"]
pub mod ort_service;
#[cfg(feature = "ort")]
pub use ort_service::OnnxEmbeddingService;
#[path = "pipeline/service.rs"]
pub mod service;
#[path = "retrieval/text.rs"]
pub mod text;
#[path = "retrieval/vector_repo.rs"]
pub mod vector_repo;

pub use config::EmbeddingConfig;
pub use controller::{BackfillEntry, BackfillResult, EmbeddingController, WorkspaceMemory};
pub use errors::{EmbeddingError, Result};
pub use hybrid::{HybridResult, HybridSearchOptions, apply_temporal_decay, reciprocal_rank_fusion};
pub use normalize::{cosine_similarity, l2_norm, l2_normalize, matryoshka_truncate};
pub use service::{EmbeddingService, MockEmbeddingService};
pub use text::{build_embedding_text, build_lesson_texts, with_document_prefix, with_query_prefix};
pub use vector_repo::{SearchOptions, VectorRepository, VectorSearchResult};
