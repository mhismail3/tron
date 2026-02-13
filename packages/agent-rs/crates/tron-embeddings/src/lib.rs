//! # tron-embeddings
//!
//! `ONNX`-based semantic embeddings and vector search.
//!
//! Uses Qwen3-Embedding-0.6B with q4 quantization via `ort`:
//! - Tokenize -> inference -> last-token pooling
//! - Matryoshka truncation (1024d -> 512d) + L2 normalization
//! - `sqlite-vec` integration for vector similarity search
//!
//! This crate is feature-gated and only compiled when embeddings are needed.

#![deny(unsafe_code)]
