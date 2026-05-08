//! Canonical function inventory for the device domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] =
    &["device::register", "device::unregister", "device::respond"];
