//! Capability binding domain contract constants.

pub(crate) const WORKER: &str = "capability_binding";
pub(crate) const CAPABILITY_BINDING_LIFECYCLE_TOPIC: &str = "capability_binding.lifecycle";
pub(crate) const READ_SCOPE: &str = "capability_binding.read";
pub(crate) const WRITE_SCOPE: &str = "capability_binding.write";
pub(crate) const RESOURCE_READ_SCOPE: &str = "resource.read";
pub(crate) const RESOURCE_WRITE_SCOPE: &str = "resource.write";
pub(crate) const CAPABILITY_BINDING_REQUEST_SCHEMA_VERSION: &str =
    crate::engine::CAPABILITY_BINDING_REQUEST_PAYLOAD_SCHEMA_VERSION;
pub(crate) const CAPABILITY_BINDING_DECISION_SCHEMA_VERSION: &str =
    crate::engine::CAPABILITY_BINDING_DECISION_PAYLOAD_SCHEMA_VERSION;
pub(crate) const CAPABILITY_BINDING_POLICY_SCHEMA_VERSION: &str =
    crate::engine::CAPABILITY_BINDING_POLICY_PAYLOAD_SCHEMA_VERSION;
pub(crate) const CAPABILITY_SHADOW_TRIAL_REQUEST_SCHEMA_VERSION: &str =
    crate::engine::CAPABILITY_SHADOW_TRIAL_REQUEST_PAYLOAD_SCHEMA_VERSION;
pub(crate) const CAPABILITY_SHADOW_TRIAL_DECISION_SCHEMA_VERSION: &str =
    crate::engine::CAPABILITY_SHADOW_TRIAL_DECISION_PAYLOAD_SCHEMA_VERSION;
pub(crate) const CAPABILITY_SHADOW_TRIAL_RUN_SCHEMA_VERSION: &str =
    crate::engine::CAPABILITY_SHADOW_TRIAL_RUN_PAYLOAD_SCHEMA_VERSION;
pub(crate) const CAPABILITY_SHADOW_TRIAL_EVIDENCE_SCHEMA_VERSION: &str =
    crate::engine::CAPABILITY_SHADOW_TRIAL_EVIDENCE_PAYLOAD_SCHEMA_VERSION;
