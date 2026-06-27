//! Module install domain contract constants.

pub(crate) const WORKER: &str = "module_install";
pub(crate) const MODULE_INSTALL_LIFECYCLE_TOPIC: &str = "module_install.lifecycle";
pub(crate) const READ_SCOPE: &str = "module_install.read";
pub(crate) const WRITE_SCOPE: &str = "module_install.write";
pub(crate) const RESOURCE_READ_SCOPE: &str = "resource.read";
pub(crate) const RESOURCE_WRITE_SCOPE: &str = "resource.write";
pub(crate) const MODULE_INSTALL_REQUEST_SCHEMA_VERSION: &str =
    crate::engine::MODULE_INSTALL_REQUEST_PAYLOAD_SCHEMA_VERSION;
pub(crate) const MODULE_INSTALL_DECISION_SCHEMA_VERSION: &str =
    crate::engine::MODULE_INSTALL_DECISION_PAYLOAD_SCHEMA_VERSION;
