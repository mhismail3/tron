//! Device domain contract constants.

pub(crate) const WORKER: &str = "device";
#[cfg(test)]
pub(crate) const DEVICE_LIFECYCLE_TOPIC: &str = "device.lifecycle";
pub(crate) const READ_SCOPE: &str = "device.read";
#[cfg(test)]
pub(crate) const WRITE_SCOPE: &str = "device.write";
pub(crate) const RESOURCE_READ_SCOPE: &str = "resource.read";
#[cfg(test)]
pub(crate) const RESOURCE_WRITE_SCOPE: &str = "resource.write";
pub(crate) const SCHEMA_VERSION: &str = "tron.device.registration.v1";
