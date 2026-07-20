//! Private APNs token custody for authenticated iOS clients.
//!
//! The device domain owns redacted registration resources. This module keeps
//! raw tokens in a private `0600` file below `~/.tron/internal/devices/`; the
//! worker-first kernel has no fixed push-delivery plane.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `store` | Atomic private raw-token custody keyed by SHA-256 hash |
//!
//! # Invariants
//!
//! - Raw APNs tokens never enter engine resources, traces, logs, or provider
//!   projections.
//! - Token custody is transport-only and never becomes a model-facing tool.

mod store;

use std::path::Path;
use std::sync::Arc;

pub(crate) use store::{DeviceTokenRecord, DeviceTokenStore};

/// Injected APNs token-custody dependency used by device registration.
#[derive(Clone, Debug)]
pub struct ApnsRuntime {
    pub(crate) token_store: Arc<dyn DeviceTokenStore>,
}

impl ApnsRuntime {
    /// Disabled runtime used by external integration harnesses that construct
    /// `ServerRuntimeContext` directly.
    #[doc(hidden)]
    pub fn disabled() -> Self {
        Self {
            token_store: Arc::new(store::DisabledDeviceTokenStore),
        }
    }

    pub(crate) fn production(internal_dir: &Path) -> Self {
        Self {
            token_store: Arc::new(store::FileDeviceTokenStore::new(
                internal_dir.join("devices").join("device_tokens.json"),
            )),
        }
    }

    #[cfg(test)]
    pub(crate) fn disabled_for_test() -> Self {
        Self {
            token_store: MemoryDeviceTokenStore::shared(),
        }
    }

    pub(crate) fn transport_enabled(&self) -> bool {
        false
    }
}

#[cfg(test)]
pub(crate) use store::MemoryDeviceTokenStore;
