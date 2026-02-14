//! APNS (Apple Push Notification Service) module.
//!
//! Provides JWT-based authentication and HTTP/2 push notification delivery
//! to Apple's APNs servers. Configuration is loaded from `~/.tron/mods/apns/`.

mod config;
mod service;
mod types;

pub use config::{load_apns_config, ApnsConfig};
pub use service::ApnsService;
pub use types::{ApnsNotification, ApnsSendResult};
