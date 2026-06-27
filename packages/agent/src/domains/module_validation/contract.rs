//! Module validation domain contract constants.

pub(crate) const WORKER: &str = "module_validation";
pub(crate) const MODULE_VALIDATION_LIFECYCLE_TOPIC: &str = "module_validation.lifecycle";
pub(crate) const READ_SCOPE: &str = "module_validation.read";
pub(crate) const WRITE_SCOPE: &str = "module_validation.write";
pub(crate) const RESOURCE_READ_SCOPE: &str = "resource.read";
pub(crate) const RESOURCE_WRITE_SCOPE: &str = "resource.write";
pub(crate) const MODULE_VALIDATION_REPORT_SCHEMA_VERSION: &str =
    crate::engine::MODULE_VALIDATION_REPORT_PAYLOAD_SCHEMA_VERSION;
