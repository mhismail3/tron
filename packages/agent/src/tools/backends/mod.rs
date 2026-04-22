//! # tools/backends — DI trait implementations
//!
//! The `tools/` module defines traits (`FileSystem`, `HttpClient`,
//! `ProcessRunner`, `NotifyDelegate`, `SubagentSpawner`) that every tool
//! calls through. This module supplies the concrete implementations —
//! one real, one stub per trait.
//!
//! Real backends are constructed during server startup (see
//! `packages/agent/src/main.rs`) and injected via `ToolContext`
//! ([`crate::tools::traits::ToolContext`]). Tests construct a
//! `ToolContext` populated with stubs (see `testutil`), so no tool
//! ever reaches a real syscall during unit-test runs.
//!
//! ## Submodules
//!
//! | Module         | Trait implementations |
//! |----------------|-----------------------|
//! | [`filesystem`] | [`RealFileSystem`] — `std::fs` wrapper |
//! | [`http`]       | [`ReqwestHttpClient`] — reqwest with timeout + redirect policy |
//! | [`process`]    | [`TokioProcessRunner`] — `tokio::process` with streaming stdout/stderr |
//! | [`stubs`]      | [`StubNotifyDelegate`], [`StubSubagentSpawner`] — registry-friendly no-op backends |
//!
//! ## Invariants
//!
//! - The stub backends exist so that every tool is constructible even
//!   when a feature flag is off (e.g. `apns` disabled → stub notify).
//!   Execution returns a warning result carrying
//!   [`stubs::STUB_NOTIFY_WARNING`] rather than panicking.

pub mod filesystem;
pub mod http;
pub mod process;
pub mod stubs;

pub use filesystem::RealFileSystem;
pub use http::ReqwestHttpClient;
pub use process::TokioProcessRunner;
pub use stubs::{STUB_NOTIFY_WARNING, StubNotifyDelegate, StubSubagentSpawner};
