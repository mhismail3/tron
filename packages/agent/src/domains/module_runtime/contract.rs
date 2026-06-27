//! Module runtime domain contract constants.

pub(crate) const WORKER: &str = "module_runtime";
pub(crate) const MODULE_RUNTIME_TOPIC: &str = "module_runtime.lifecycle";
pub(crate) const READ_SCOPE: &str = "module_runtime.read";
pub(crate) const WRITE_SCOPE: &str = "module_runtime.write";
pub(crate) const RESOURCE_READ_SCOPE: &str = "resource.read";
pub(crate) const RESOURCE_WRITE_SCOPE: &str = "resource.write";
pub(crate) const MODULE_RUNTIME_STATE_SCHEMA_VERSION: &str =
    crate::engine::MODULE_RUNTIME_STATE_PAYLOAD_SCHEMA_VERSION;
