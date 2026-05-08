//! # server/platform — OS / vendor integrations
//!
//! Platform-specific services that live on the server side but depend
//! on an external SDK or cloud surface. Each integration is feature-gated
//! so a build without the feature flag compiles without the dependency.
//!
//! ## Submodules
//!
//! | Module   | Feature flag | Content |
//! |----------|--------------|---------|
//! | [`apns`] | `apns`       | Apple Push Notification service — JWT auth, HTTP/2 send, 410 Gone handling |
//! | [`codex_app`] | always | Managed Codex App Server child lifecycle |
//! | [`device_broker`] | always | Engine-stream request/response broker for paired devices |
//!
//! ## Invariants
//!
//! - When a feature flag is off, iOS-originating requests that would
//!   trigger a push still return success at the engine transport — the stub
//!   `StubNotifyDelegate` ([`crate::tools::backends::stubs`]) surfaces
//!   a warning so the agent can mention it instead of failing.
//! - APNS 410 Gone responses remove the offending device token from
//!   the local store (see H22); subsequent pushes to the same token
//!   are suppressed without a round-trip.

#[cfg(feature = "apns")]
pub mod apns;
pub mod codex_app;
pub mod device_broker;
