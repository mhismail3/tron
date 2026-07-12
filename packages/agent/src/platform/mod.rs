//! # server/platform — OS / vendor integrations
//!
//! Platform-specific services that live on the server side and are required
//! by the primitive loop shell.
//!
//! ## Submodules
//!
//! | Module | Content |
//! |--------|---------|
//! | [`apns`] | Private device-token custody and optional APNs relay delivery |
//! | [`device_broker`] | Engine-stream request/response broker for paired devices |
//!
//! ## Invariants
//!
//! - APNs owns only private token custody and transport. Device registration
//!   metadata and notification delivery policy remain in their domains.
//! - The paired-device broker does not own push notification state.

pub mod apns;
pub mod device_broker;
