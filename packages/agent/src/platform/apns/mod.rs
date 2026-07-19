//! Private APNs token custody and relay delivery.
//!
//! The device domain owns redacted registration resources and the notifications
//! domain owns user-visible delivery policy/evidence. This module is the narrow
//! transport boundary between them: raw tokens remain in a private `0600` file
//! below `~/.tron/internal/notifications/`, and the optional relay sender reads
//! credentials only from runtime environment variables.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `relay` | HMAC-authenticated HTTPS client for the APNs relay |
//! | `store` | Atomic private raw-token custody keyed by SHA-256 hash |
//! | `types` | Redacted transport-neutral request/result records |
//!
//! # Invariants
//!
//! - Raw APNs tokens never enter engine resources, traces, logs, or provider
//!   projections.
//! - Relay delivery is disabled unless both `TRON_RELAY_URL` and
//!   `TRON_RELAY_SECRET` are present at runtime.
//! - A batch has exactly one APNs environment and bundle id.

mod relay;
mod store;
mod types;

use std::path::Path;
use std::sync::Arc;

pub(crate) use store::{DeviceTokenRecord, DeviceTokenStore};
pub(crate) use types::{ApnsBatch, ApnsNotification, ApnsSendResult, PushSender};

/// Injected APNs transport dependencies shared by device and notification
/// domain handlers.
#[derive(Clone, Debug)]
pub struct ApnsRuntime {
    pub(crate) token_store: Arc<dyn DeviceTokenStore>,
    pub(crate) sender: Option<Arc<dyn PushSender>>,
}

impl ApnsRuntime {
    /// Disabled runtime used by external integration harnesses that construct
    /// `ServerRuntimeContext` directly.
    #[doc(hidden)]
    pub fn disabled() -> Self {
        Self {
            token_store: Arc::new(store::DisabledDeviceTokenStore),
            sender: None,
        }
    }

    pub(crate) fn production(internal_dir: &Path) -> Self {
        Self {
            token_store: Arc::new(store::FileDeviceTokenStore::new(
                internal_dir
                    .join("notifications")
                    .join("device_tokens.json"),
            )),
            sender: relay::RelaySender::from_runtime_env()
                .map(|sender| Arc::new(sender) as Arc<dyn PushSender>),
        }
    }

    #[cfg(test)]
    pub(crate) fn test(
        token_store: Arc<dyn DeviceTokenStore>,
        sender: Option<Arc<dyn PushSender>>,
    ) -> Self {
        Self {
            token_store,
            sender,
        }
    }

    #[cfg(test)]
    pub(crate) fn disabled_for_test() -> Self {
        Self::test(MemoryDeviceTokenStore::shared(), None)
    }

    pub(crate) fn transport_enabled(&self) -> bool {
        self.sender.is_some()
    }
}

#[cfg(test)]
pub(crate) use store::MemoryDeviceTokenStore;
#[cfg(test)]
pub(crate) use types::MockPushSender;
