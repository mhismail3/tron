//! # tron
//!
//! Unified library crate for the Tron agent. Consolidates all previously
//! separate library crates into a single compilation unit.

#![deny(unsafe_code)]
#![allow(clippy::unnecessary_literal_bound)]

// Foundation (no internal deps)
pub mod core;
pub mod settings;
pub mod skills;
pub mod transcription;

// Services (depend on core/settings)
pub mod events;
pub mod llm;
pub mod tools;
pub mod embeddings;
pub mod cron;
pub mod worktree;

// Orchestration (depends on services)
pub mod runtime;

// Interface (depends on everything)
pub mod server;
