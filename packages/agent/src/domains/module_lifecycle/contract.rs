//! Module lifecycle domain contract constants.

pub(crate) const WORKER: &str = "module_lifecycle";
pub(crate) const MODULE_LIFECYCLE_TOPIC: &str = "module_lifecycle.lifecycle";
pub(crate) const READ_SCOPE: &str = "module_lifecycle.read";
pub(crate) const WRITE_SCOPE: &str = "module_lifecycle.write";
pub(crate) const RESOURCE_READ_SCOPE: &str = "resource.read";
pub(crate) const RESOURCE_WRITE_SCOPE: &str = "resource.write";
pub(crate) const MODULE_LIFECYCLE_STATE_SCHEMA_VERSION: &str =
    crate::engine::MODULE_LIFECYCLE_STATE_PAYLOAD_SCHEMA_VERSION;
