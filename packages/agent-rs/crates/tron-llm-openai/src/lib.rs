//! # tron-llm-openai
//!
//! `OpenAI` LLM provider implementation.
//!
//! Implements the `Provider` trait from `tron-llm` for the Chat Completions API:
//! - Message converter (Context -> Chat Completions format)
//! - Stream handler, OAuth (Codex) + API key
//! - Reasoning effort configuration

#![deny(unsafe_code)]
