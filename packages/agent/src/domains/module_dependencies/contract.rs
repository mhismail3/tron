//! Module dependency domain contract constants.

pub(crate) const WORKER: &str = "module_dependencies";
pub(crate) const MODULE_DEPENDENCY_LIFECYCLE_TOPIC: &str = "module_dependencies.lifecycle";
pub(crate) const READ_SCOPE: &str = "module_dependencies.read";
pub(crate) const WRITE_SCOPE: &str = "module_dependencies.write";
pub(crate) const RESOURCE_READ_SCOPE: &str = "resource.read";
pub(crate) const RESOURCE_WRITE_SCOPE: &str = "resource.write";
pub(crate) const MODULE_DEPENDENCY_REQUEST_SCHEMA_VERSION: &str =
    crate::engine::MODULE_DEPENDENCY_REQUEST_PAYLOAD_SCHEMA_VERSION;
pub(crate) const MODULE_DEPENDENCY_DECISION_SCHEMA_VERSION: &str =
    crate::engine::MODULE_DEPENDENCY_DECISION_PAYLOAD_SCHEMA_VERSION;
pub(crate) const MODULE_DEPENDENCY_POLICY_SCHEMA_VERSION: &str =
    crate::engine::MODULE_DEPENDENCY_POLICY_PAYLOAD_SCHEMA_VERSION;
