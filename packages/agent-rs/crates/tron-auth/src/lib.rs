//! # tron-auth
//!
//! OAuth 2.0 and API key authentication for LLM providers.
//!
//! Supports two auth modes:
//! - **API key**: Direct key-based auth
//! - **OAuth**: Token-based auth with refresh (Anthropic, Google, `OpenAI`)
//!
//! Token refresh runs with configurable expiry buffer. Auth state is persisted
//! to `~/.tron/auth.json` (sync load at startup, async at runtime).

#![deny(unsafe_code)]
