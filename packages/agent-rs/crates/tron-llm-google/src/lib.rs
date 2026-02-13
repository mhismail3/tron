//! # tron-llm-google
//!
//! Google/Gemini LLM provider implementation.
//!
//! Implements the `Provider` trait from `tron-llm` for the Gemini API:
//! - Message converter (Context -> Gemini format with `thoughtSignature`)
//! - Stream handler, OAuth (Cloud Code Assist + Antigravity)
//! - Safety filter handling

#![deny(unsafe_code)]
