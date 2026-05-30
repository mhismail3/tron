//! Module package lifecycle primitive.
//!
//! Modules are resource-backed packages plus canonical capability invocations.
//! This primitive owns package/config/activation resource wrappers and grant
//! derivation for activation. Local process packages launch only by composing a
//! child `worker::spawn` invocation; module code validates package resources and
//! records activation lineage but never owns a process runtime, package table,
//! health table, policy table, recovery table, or action multiplexer. Source
//! registration, local Ed25519 trust roots, signature verification, trust-root
//! renewal, key-rotation evidence, trust-decision expiry, revocation
//! enforcement, trust-change simulation, trust-review evidence, scheduled trust
//! audits, trust-audit status, trust-audit retention review, policy audits,
//! trust reconciliation, source approvals, conformance, health, integrity, and
//! recovery outcomes are bounded `evidence`/`decision` resources linked back to
//! package and activation records. Source-trust, health/integrity, activation
//! runtime cleanup, trust review, and scheduled audit code live in focused
//! submodules; this file owns the package lifecycle registration surface and
//! shared module substrate helpers.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::sync::Arc;

use super::{
    MODULE_WORKER_ID, PrimitiveFunctionRegistration, PrimitiveStores, handled_registration,
    optional_string, primitive_compensation, primitive_function, required_str,
    required_string_owned,
};
use crate::engine::discovery::{ActorContext, ActorKind, FunctionQuery};
use crate::engine::grants::{DeriveGrant, EngineGrant, EngineGrantLifecycle, ListGrants};
use crate::engine::ids::{AuthorityGrantId, FunctionId, InvocationId, WorkerId};
use crate::engine::invocation::InProcessFunctionHandler;
use crate::engine::resources::{
    ACTIVATION_RECORD_KIND, CreateResource, EngineResource, EngineResourceInspection,
    EngineResourceVersion, LinkResources, ListResources, MODULE_CONFIG_KIND, UpdateResource,
    WORKER_PACKAGE_KIND,
};
use crate::engine::types::{
    CompensationKind, DurableOutputContract, EffectClass, FunctionDefinition, IdempotencyContract,
    RiskLevel, VisibilityScope,
};
use crate::engine::{ActorId, EngineError, EngineResourceScope, Invocation, Result, schema};

mod actions;
mod activation_lifecycle;
mod activation_runtime;
mod evidence;
mod grants;
mod health_integrity;
mod manifest;
mod package_lifecycle;
mod payload;
mod registrations;
mod resources;
mod schemas;
mod source_trust;
mod store_access;
mod trust_audit;
mod trust_review;

use actions::{module_actions_for_package, module_actions_for_trust_target};
use activation_lifecycle::SpawnedLocalProcess;
use grants::{
    child_grant_from_payload, ensure_grant_ceiling_narrows_caller,
    ensure_grant_ceiling_within_ceiling, ensure_grant_request_narrows_caller,
    ensure_grant_request_within_ceiling, ensure_path_within_grant_roots, ensure_same_set,
    ensure_subset, risk_label,
};
use health_integrity::{
    check_health_schema, recover_activation_schema, run_conformance_schema, verify_integrity_schema,
};
use manifest::{
    LocalProcessRuntime, ResourceVersionRef, RuntimeEntryPoint, declared_capabilities,
    manifest_digest, normalize_package_manifest, package_has_signature, package_selector_matches,
    registered_capabilities_for_worker, resource_version_refs, source_kind, validate_manifest,
    validate_registered_capabilities, validate_runtime_entrypoint,
};
use payload::{
    append_string_array, append_value_array, bounded_json, collect_secret_refs, hash_json,
    parse_datetime, parse_risk, reject_raw_secrets, required_map_str, required_object,
    required_value_str, string_array_from, truncate_utf8_bytes,
};
pub(super) use registrations::registrations;
use resources::{
    UpsertResource, activation_resource_id, activation_trust_summary, config_resource_id,
    current_payload, current_payload_from_json_inspection, current_version, decision_summary,
    ensure_expected_current_version, ensure_version_is_current, filter_resources_by_package,
    link_if_possible, next_config_revision, package_resource_id, package_resource_id_from_payload,
    package_trust_summary, require_inspection, resource_ref_from_resource,
    resource_ref_from_version, resource_scope_and_token, trust_decision_metadata,
    trust_target_status, trust_warnings_for_status, upsert_resource, version_payload,
};
use schemas::{
    activate_schema, configure_schema, disable_schema, inspect_package_schema,
    module_resource_response_schema, quarantine_schema, register_package_schema, rollback_schema,
    upgrade_schema,
};
use source_trust::{
    approve_source_schema, audit_policy_schema, enforce_revocation_schema,
    expire_trust_decision_schema, inspect_trust_schema, policy_audit_response_schema,
    policy_decide_schema, reconcile_trust_schema, register_source_schema, renew_trust_root_schema,
    revoke_source_approval_schema, rotate_signature_key_schema, verify_signature_schema,
    verify_source_schema,
};
pub(crate) use trust_audit::{
    RECORD_TRUST_AUDIT_RETENTION_FUNCTION, RUN_SCHEDULED_TRUST_AUDIT_FUNCTION,
    SCHEDULE_TRUST_AUDIT_FUNCTION, TRUST_AUDIT_STATUS_FUNCTION,
};
use trust_audit::{
    record_trust_audit_retention_schema, run_scheduled_trust_audit_schema,
    schedule_trust_audit_schema, trust_audit_status_schema,
};
pub(in crate::engine) use trust_audit::{
    trust_audit_current_due_bucket, trust_audit_evidence_matches_due_bucket,
};
pub(crate) use trust_review::{
    RECORD_TRUST_REVIEW_FUNCTION, SIMULATE_TRUST_CHANGE_FUNCTION, TRUST_REVIEW_OPERATIONS,
};
use trust_review::{
    record_trust_review_schema, simulate_trust_change_schema, trust_review_response_schema,
};

pub(crate) const REGISTER_PACKAGE_FUNCTION: &str = "module::register_package";
pub(crate) const INSPECT_PACKAGE_FUNCTION: &str = "module::inspect_package";
pub(crate) const CONFIGURE_FUNCTION: &str = "module::configure";
pub(crate) const ACTIVATE_FUNCTION: &str = "module::activate";
pub(crate) const DISABLE_FUNCTION: &str = "module::disable";
pub(crate) const UPGRADE_FUNCTION: &str = "module::upgrade";
pub(crate) const ROLLBACK_FUNCTION: &str = "module::rollback";
pub(crate) const QUARANTINE_FUNCTION: &str = "module::quarantine";
pub(crate) const CHECK_HEALTH_FUNCTION: &str = "module::check_health";
pub(crate) const VERIFY_INTEGRITY_FUNCTION: &str = "module::verify_integrity";
pub(crate) const RECOVER_ACTIVATION_FUNCTION: &str = "module::recover_activation";
pub(crate) const VERIFY_SOURCE_FUNCTION: &str = "module::verify_source";
pub(crate) const APPROVE_SOURCE_FUNCTION: &str = "module::approve_source";
pub(crate) const REVOKE_SOURCE_APPROVAL_FUNCTION: &str = "module::revoke_source_approval";
pub(crate) const POLICY_DECIDE_FUNCTION: &str = "module::policy_decide";
pub(crate) const RUN_CONFORMANCE_FUNCTION: &str = "module::run_conformance";
pub(crate) const REGISTER_SOURCE_FUNCTION: &str = "module::register_source";
pub(crate) const VERIFY_SIGNATURE_FUNCTION: &str = "module::verify_signature";
pub(crate) const AUDIT_POLICY_FUNCTION: &str = "module::audit_policy";
pub(crate) const RECORD_POLICY_AUDIT_FUNCTION: &str = "module::record_policy_audit";
pub(crate) const RECONCILE_TRUST_FUNCTION: &str = "module::reconcile_trust";
pub(crate) const INSPECT_TRUST_FUNCTION: &str = "module::inspect_trust";
pub(crate) const RENEW_TRUST_ROOT_FUNCTION: &str = "module::renew_trust_root";
pub(crate) const ROTATE_SIGNATURE_KEY_FUNCTION: &str = "module::rotate_signature_key";
pub(crate) const EXPIRE_TRUST_DECISION_FUNCTION: &str = "module::expire_trust_decision";
pub(crate) const ENFORCE_REVOCATION_FUNCTION: &str = "module::enforce_revocation";
const MANIFEST_SCHEMA_ID: &str = "tron.module.package_manifest.v1";
const LOCAL_DIGEST_PINNED: &str = "local_digest_pinned";
const BUILTIN_PROVENANCE: &str = "builtin";
const SIGNED_LOCAL_TRUST: &str = "signed_local";
const TRUST_ROOT_PREFIX: &str = "trust-root:";
const SOURCE_STATUS_TRUSTED_BUILTIN: &str = "trusted_builtin";
const SOURCE_STATUS_UNVERIFIED: &str = "unverified";
const SOURCE_STATUS_VERIFIED: &str = "verified";
const SOURCE_STATUS_SIGNATURE_VERIFIED: &str = "signature_verified";

struct ModulePrimitiveHandler {
    stores: PrimitiveStores,
}

#[async_trait::async_trait]
impl InProcessFunctionHandler for ModulePrimitiveHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        match invocation.function_id.as_str() {
            REGISTER_PACKAGE_FUNCTION => self.register_package(&invocation),
            INSPECT_PACKAGE_FUNCTION => self.inspect_package(&invocation).await,
            CONFIGURE_FUNCTION => self.configure(&invocation),
            ACTIVATE_FUNCTION => self.activate(&invocation).await,
            DISABLE_FUNCTION => self.disable(&invocation).await,
            UPGRADE_FUNCTION => self.upgrade(&invocation).await,
            ROLLBACK_FUNCTION => self.rollback(&invocation).await,
            QUARANTINE_FUNCTION => self.quarantine(&invocation).await,
            CHECK_HEALTH_FUNCTION => self.check_health(&invocation).await,
            VERIFY_INTEGRITY_FUNCTION => self.verify_integrity(&invocation).await,
            RECOVER_ACTIVATION_FUNCTION => self.recover_activation(&invocation).await,
            VERIFY_SOURCE_FUNCTION => self.verify_source(&invocation),
            APPROVE_SOURCE_FUNCTION => self.approve_source(&invocation),
            REVOKE_SOURCE_APPROVAL_FUNCTION => self.revoke_source_approval(&invocation),
            POLICY_DECIDE_FUNCTION => self.policy_decide(&invocation),
            RUN_CONFORMANCE_FUNCTION => self.run_conformance(&invocation).await,
            REGISTER_SOURCE_FUNCTION => self.register_source(&invocation),
            VERIFY_SIGNATURE_FUNCTION => self.verify_signature(&invocation),
            AUDIT_POLICY_FUNCTION => self.audit_policy(&invocation),
            RECORD_POLICY_AUDIT_FUNCTION => self.record_policy_audit(&invocation),
            RECONCILE_TRUST_FUNCTION => self.reconcile_trust(&invocation),
            INSPECT_TRUST_FUNCTION => self.inspect_trust(&invocation),
            RENEW_TRUST_ROOT_FUNCTION => self.renew_trust_root(&invocation),
            ROTATE_SIGNATURE_KEY_FUNCTION => self.rotate_signature_key(&invocation),
            EXPIRE_TRUST_DECISION_FUNCTION => self.expire_trust_decision(&invocation),
            ENFORCE_REVOCATION_FUNCTION => self.enforce_revocation(&invocation).await,
            SIMULATE_TRUST_CHANGE_FUNCTION => self.simulate_trust_change(&invocation),
            RECORD_TRUST_REVIEW_FUNCTION => self.record_trust_review(&invocation),
            TRUST_AUDIT_STATUS_FUNCTION => self.trust_audit_status(&invocation),
            SCHEDULE_TRUST_AUDIT_FUNCTION => self.schedule_trust_audit(&invocation),
            RUN_SCHEDULED_TRUST_AUDIT_FUNCTION => self.run_scheduled_trust_audit(&invocation),
            RECORD_TRUST_AUDIT_RETENTION_FUNCTION => self.record_trust_audit_retention(&invocation),
            _ => Err(EngineError::NotFound {
                kind: "function",
                id: invocation.function_id.to_string(),
            }),
        }
    }
}
