//! # server/platform — OS / vendor integrations
//!
//! Platform-specific services that live on the server side and are required
//! by the primitive loop shell.
//!
//! ## Submodules
//!
//! | Module | Content |
//! |--------|---------|
//! | [`device_broker`] | Engine-stream request/response broker for paired devices |
//!
//! ## Invariants
//!
//! - The retained platform layer may broker local paired-device responses, but
//!   it does not own push notification state or product delivery policy.

pub mod device_broker;
