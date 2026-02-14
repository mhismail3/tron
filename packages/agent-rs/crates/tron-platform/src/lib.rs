//! # tron-platform
//!
//! Platform integrations for external services.
//!
//! - **Browser**: CDP connection management and handlers (feature-gated: `browser`)
//! - **APNS**: JWT signing, HTTP/2 push to Apple servers (feature-gated: `apns`)
//! - **Worktrees**: Pure-Rust git worktree create/merge/cleanup via `gix`
//! - **Transcription**: Sidecar process management for audio-to-text
//! - **Canvas**: Canvas store and export (JSON, Markdown, PDF)

#![deny(unsafe_code)]

#[cfg(feature = "apns")]
pub mod apns;
