//! Module authoring domain contract constants.

pub(crate) const WORKER: &str = "module_authoring";
pub(crate) const MODULE_AUTHORING_LIFECYCLE_TOPIC: &str = "module_authoring.lifecycle";
pub(crate) const READ_SCOPE: &str = "module_authoring.read";
pub(crate) const WRITE_SCOPE: &str = "module_authoring.write";
pub(crate) const RESOURCE_READ_SCOPE: &str = "resource.read";
pub(crate) const RESOURCE_WRITE_SCOPE: &str = "resource.write";
pub(crate) const MODULE_PROPOSAL_SCHEMA_VERSION: &str =
    crate::engine::MODULE_PROPOSAL_PAYLOAD_SCHEMA_VERSION;
