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
use std::path::PathBuf;
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

mod activation_runtime;
mod health_integrity;
mod source_trust;
mod trust_audit;
mod trust_review;

use health_integrity::{
    check_health_schema, recover_activation_schema, run_conformance_schema, verify_integrity_schema,
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

pub(super) fn registrations(
    stores: &PrimitiveStores,
) -> Result<Vec<PrimitiveFunctionRegistration>> {
    let handler = Arc::new(ModulePrimitiveHandler {
        stores: stores.clone(),
    });
    Ok(vec![
        module_write(
            REGISTER_PACKAGE_FUNCTION,
            "register and validate a worker package manifest",
            register_package_schema(),
            module_resource_response_schema("worker_package"),
            RiskLevel::Medium,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            WORKER_PACKAGE_KIND,
        ])),
        module_read(
            INSPECT_PACKAGE_FUNCTION,
            "inspect one registered worker package and its activation state",
            inspect_package_schema(),
            json!({
                "type": "object",
                "required": ["package", "configs", "activations", "diagnostics", "availableActions"],
                "additionalProperties": false,
                "properties": {
                    "package": {"type": ["object", "null"]},
                    "configs": {"type": "array"},
                    "activations": {"type": "array"},
                    "diagnostics": {"type": "object"},
                    "availableActions": {"type": "array"}
                }
            }),
        ),
        module_write(
            CONFIGURE_FUNCTION,
            "validate and persist module configuration",
            configure_schema(),
            module_resource_response_schema("module_config"),
            RiskLevel::Medium,
        )
        .with_output_contract(DurableOutputContract::resource_backed([MODULE_CONFIG_KIND])),
        module_write(
            ACTIVATE_FUNCTION,
            "derive an activation grant and bind a package to a worker",
            activate_schema(),
            module_resource_response_schema("activation_record"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            ACTIVATION_RECORD_KIND,
        ])),
        module_write(
            DISABLE_FUNCTION,
            "disable an active package activation and revoke its grant",
            disable_schema(),
            module_resource_response_schema("activation_record"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            ACTIVATION_RECORD_KIND,
        ])),
        module_write(
            UPGRADE_FUNCTION,
            "replace an activation with a validated package/config pair",
            upgrade_schema(),
            module_resource_response_schema("activation_record"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            ACTIVATION_RECORD_KIND,
        ])),
        module_write(
            ROLLBACK_FUNCTION,
            "create a new activation version from a prior valid activation version",
            rollback_schema(),
            module_resource_response_schema("activation_record"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            ACTIVATION_RECORD_KIND,
        ])),
        module_write(
            QUARANTINE_FUNCTION,
            "quarantine a package or activation and revoke live authority",
            quarantine_schema(),
            module_resource_response_schema("activation_record"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            WORKER_PACKAGE_KIND,
            ACTIVATION_RECORD_KIND,
        ])),
        module_write(
            CHECK_HEALTH_FUNCTION,
            "record resource-backed module activation health evidence",
            check_health_schema(),
            module_resource_response_schema("activation_record"),
            RiskLevel::Medium,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            "evidence",
            ACTIVATION_RECORD_KIND,
        ])),
        module_write(
            VERIFY_INTEGRITY_FUNCTION,
            "record resource-backed package, config, or activation integrity evidence",
            verify_integrity_schema(),
            module_resource_response_schema("evidence"),
            RiskLevel::Medium,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            "evidence",
            ACTIVATION_RECORD_KIND,
        ])),
        module_write(
            RECOVER_ACTIVATION_FUNCTION,
            "materialize recovery evidence and clean unsafe activation authority",
            recover_activation_schema(),
            module_resource_response_schema("activation_record"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            "evidence",
            ACTIVATION_RECORD_KIND,
        ])),
        module_write(
            VERIFY_SOURCE_FUNCTION,
            "verify package source refs, digest, signature metadata, and trust evidence",
            verify_source_schema(),
            module_resource_response_schema("evidence"),
            RiskLevel::Medium,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            "evidence",
            WORKER_PACKAGE_KIND,
        ])),
        module_write(
            APPROVE_SOURCE_FUNCTION,
            "record a scoped operator source approval decision",
            approve_source_schema(),
            module_resource_response_schema("decision"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed(["decision"])),
        module_write(
            REVOKE_SOURCE_APPROVAL_FUNCTION,
            "revoke a scoped operator source approval decision",
            revoke_source_approval_schema(),
            module_resource_response_schema("decision"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            "decision", "evidence",
        ])),
        module_read(
            POLICY_DECIDE_FUNCTION,
            "evaluate source and activation policy without mutating state",
            policy_decide_schema(),
            json!({
                "type": "object",
                "required": ["decision", "reasons", "missingPrerequisites", "sourceTrust", "approval", "conformance"],
                "additionalProperties": true,
                "properties": {
                    "decision": {"type": "string", "enum": ["allow", "deny", "quarantine_required"]},
                    "reasons": {"type": "array", "items": {"type": "string"}},
                    "missingPrerequisites": {"type": "array", "items": {"type": "string"}},
                    "sourceTrust": {"type": "object"},
                    "approval": {"type": "object"},
                    "conformance": {"type": "object"}
                }
            }),
        ),
        module_write(
            RUN_CONFORMANCE_FUNCTION,
            "record bounded package runtime conformance evidence",
            run_conformance_schema(),
            module_resource_response_schema("evidence"),
            RiskLevel::Medium,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            "evidence",
            WORKER_PACKAGE_KIND,
            ACTIVATION_RECORD_KIND,
        ])),
        module_write(
            REGISTER_SOURCE_FUNCTION,
            "register a local package source or trust root as resource-backed decisions and evidence",
            register_source_schema(),
            module_resource_response_schema("decision"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            "decision", "evidence",
        ])),
        module_write(
            VERIFY_SIGNATURE_FUNCTION,
            "verify a package Ed25519 signature against local trust-root decisions",
            verify_signature_schema(),
            module_resource_response_schema("evidence"),
            RiskLevel::Medium,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            "evidence",
            WORKER_PACKAGE_KIND,
        ])),
        module_read(
            AUDIT_POLICY_FUNCTION,
            "reconstruct package source policy from durable substrate truth",
            audit_policy_schema(),
            policy_audit_response_schema(),
        ),
        module_write(
            RECORD_POLICY_AUDIT_FUNCTION,
            "persist a bounded package source-policy audit evidence record",
            audit_policy_schema(),
            module_resource_response_schema("evidence"),
            RiskLevel::Medium,
        )
        .with_output_contract(DurableOutputContract::resource_backed(["evidence"])),
        module_write(
            RECONCILE_TRUST_FUNCTION,
            "record trust reconciliation evidence without mutating package runtime state",
            reconcile_trust_schema(),
            module_resource_response_schema("evidence"),
            RiskLevel::Medium,
        )
        .with_output_contract(DurableOutputContract::resource_backed(["evidence"])),
        module_read(
            INSPECT_TRUST_FUNCTION,
            "inspect package trust, source, approval, revocation, and activation dependencies",
            inspect_trust_schema(),
            json!({
                "type": "object",
                "required": ["target", "status", "dependencyGraph", "affectedPackages", "affectedActivations", "availableActions"],
                "additionalProperties": true,
                "properties": {
                    "target": {"type": "object"},
                    "status": {"type": "string"},
                    "dependencyGraph": {"type": "object"},
                    "affectedPackages": {"type": "array"},
                    "affectedActivations": {"type": "array"},
                    "availableActions": {"type": "array"}
                }
            }),
        ),
        module_write(
            RENEW_TRUST_ROOT_FUNCTION,
            "renew a same-key module trust-root decision with equal-or-narrower policy",
            renew_trust_root_schema(),
            module_resource_response_schema("decision"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            "decision", "evidence",
        ])),
        module_write(
            ROTATE_SIGNATURE_KEY_FUNCTION,
            "record signature-key rotation lineage between two active trust roots",
            rotate_signature_key_schema(),
            module_resource_response_schema("evidence"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed(["evidence"])),
        module_write(
            EXPIRE_TRUST_DECISION_FUNCTION,
            "expire a module source, trust-root, or approval decision without deleting bytes",
            expire_trust_decision_schema(),
            module_resource_response_schema("decision"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            "decision", "evidence",
        ])),
        module_write(
            ENFORCE_REVOCATION_FUNCTION,
            "enforce revoked trust by composing canonical module disable or quarantine invocations",
            enforce_revocation_schema(),
            module_resource_response_schema("evidence"),
            RiskLevel::High,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            "evidence",
            ACTIVATION_RECORD_KIND,
        ])),
        module_read(
            SIMULATE_TRUST_CHANGE_FUNCTION,
            "simulate module trust changes without mutating package or activation state",
            simulate_trust_change_schema(),
            trust_review_response_schema(),
        ),
        module_write(
            RECORD_TRUST_REVIEW_FUNCTION,
            "persist bounded evidence for a recomputed module trust review",
            record_trust_review_schema(),
            module_resource_response_schema("evidence"),
            RiskLevel::Medium,
        )
        .with_output_contract(DurableOutputContract::resource_backed(["evidence"])),
        module_read(
            TRUST_AUDIT_STATUS_FUNCTION,
            "project status for a decision-backed module trust audit schedule",
            trust_audit_status_schema(),
            json!({
                "type": "object",
                "required": ["schedule", "due", "warnings", "retentionWarnings", "availableActions"],
                "additionalProperties": true,
                "properties": {
                    "schedule": {"type": "object"},
                    "due": {"type": "object"},
                    "warnings": {"type": "array"},
                    "retentionWarnings": {"type": "array"},
                    "availableActions": {"type": "array"}
                }
            }),
        ),
        module_write(
            SCHEDULE_TRUST_AUDIT_FUNCTION,
            "create or CAS-update a decision-backed module trust audit schedule",
            schedule_trust_audit_schema(),
            module_resource_response_schema("decision"),
            RiskLevel::Medium,
        )
        .with_output_contract(DurableOutputContract::resource_backed([
            "decision", "evidence",
        ])),
        module_write(
            RUN_SCHEDULED_TRUST_AUDIT_FUNCTION,
            "run a decision-backed module trust audit and persist bounded evidence",
            run_scheduled_trust_audit_schema(),
            module_resource_response_schema("evidence"),
            RiskLevel::Medium,
        )
        .with_output_contract(DurableOutputContract::resource_backed(["evidence"])),
        module_write(
            RECORD_TRUST_AUDIT_RETENTION_FUNCTION,
            "persist bounded retention-review evidence for scheduled trust audits",
            record_trust_audit_retention_schema(),
            module_resource_response_schema("evidence"),
            RiskLevel::Medium,
        )
        .with_output_contract(DurableOutputContract::resource_backed(["evidence"])),
    ]
    .into_iter()
    .map(|definition| handled_registration(definition, handler.clone()))
    .collect())
}

fn module_read(
    id: &str,
    description: &str,
    request_schema: Value,
    response_schema: Value,
) -> FunctionDefinition {
    let mut definition = primitive_function(
        id,
        MODULE_WORKER_ID,
        description,
        EffectClass::PureRead,
        "module.read",
    )
    .with_request_schema(request_schema)
    .with_response_schema(response_schema);
    definition.visibility = VisibilityScope::System;
    definition
}

fn module_write(
    id: &str,
    description: &str,
    request_schema: Value,
    response_schema: Value,
    risk: RiskLevel,
) -> FunctionDefinition {
    let mut definition = primitive_function(
        id,
        MODULE_WORKER_ID,
        description,
        EffectClass::IdempotentWrite,
        "module.write",
    )
    .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
    .with_request_schema(request_schema)
    .with_response_schema(response_schema)
    .with_risk(risk);
    if risk >= RiskLevel::High {
        definition.required_authority = definition.required_authority.with_approval_required();
        definition.compensation = Some(primitive_compensation(
            CompensationKind::None,
            "module lifecycle writes are compensated by explicit disable, rollback, or quarantine capabilities",
        ));
    }
    definition.visibility = VisibilityScope::System;
    definition
}

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

impl ModulePrimitiveHandler {
    fn inspect_resource(&self, resource_id: &str) -> Result<Option<EngineResourceInspection>> {
        self.stores
            .resources
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .inspect(resource_id)
    }

    fn list_resources(&self, filter: ListResources) -> Result<Vec<EngineResource>> {
        self.stores
            .resources
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .list(filter)
    }

    fn create_resource(&self, request: CreateResource) -> Result<EngineResource> {
        self.stores
            .resources
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .create(request)
    }

    fn update_resource(&self, request: UpdateResource) -> Result<EngineResourceVersion> {
        self.stores
            .resources
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .update(request)
    }

    fn link_resources(&self, request: LinkResources) -> Result<()> {
        let _ = self
            .stores
            .resources
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .link(request)?;
        Ok(())
    }

    fn link_required(
        &self,
        source: &str,
        target: &str,
        relation: &str,
        invocation: &Invocation,
    ) -> Result<()> {
        if self.inspect_resource(source)?.is_some_and(|inspection| {
            inspection
                .outgoing_links
                .iter()
                .any(|link| link.target_resource_id == target && link.relation == relation)
        }) {
            return Ok(());
        }
        self.link_resources(LinkResources {
            source_resource_id: source.to_owned(),
            target_resource_id: target.to_owned(),
            relation: relation.to_owned(),
            metadata: json!({"source": "module", "required": true}),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
    }

    fn derive_grant(&self, request: DeriveGrant) -> Result<crate::engine::grants::EngineGrant> {
        self.stores
            .grants
            .lock()
            .map_err(|_| EngineError::HandlerFailed("grant store lock poisoned".to_owned()))?
            .derive(request)
    }

    fn revoke_grant(
        &self,
        grant_id: &AuthorityGrantId,
        trace_id: crate::engine::ids::TraceId,
    ) -> Result<crate::engine::grants::EngineGrant> {
        self.stores
            .grants
            .lock()
            .map_err(|_| EngineError::HandlerFailed("grant store lock poisoned".to_owned()))?
            .revoke(grant_id, trace_id)
    }

    fn inspect_grant(
        &self,
        grant_id: &AuthorityGrantId,
    ) -> Result<Option<crate::engine::grants::EngineGrant>> {
        self.stores
            .grants
            .lock()
            .map_err(|_| EngineError::HandlerFailed("grant store lock poisoned".to_owned()))?
            .inspect(grant_id)
    }

    fn list_grants(&self, filter: ListGrants) -> Result<Vec<EngineGrant>> {
        self.stores
            .grants
            .lock()
            .map_err(|_| EngineError::HandlerFailed("grant store lock poisoned".to_owned()))?
            .list(filter)
    }

    async fn inspect_worker(
        &self,
        worker_id: &WorkerId,
    ) -> Result<crate::engine::WorkerDefinition> {
        self.stores.engine_host()?.inspect_worker(worker_id).await
    }

    async fn discover_functions(&self, query: &FunctionQuery) -> Vec<FunctionDefinition> {
        match self.stores.engine_host() {
            Ok(host) => host.discover(query).await,
            Err(_) => Vec::new(),
        }
    }

    async fn worker_is_volatile(&self, worker_id: &WorkerId) -> Option<bool> {
        self.stores
            .engine_host()
            .ok()?
            .worker_is_volatile(worker_id)
            .await
    }

    async fn unregister_worker(&self, worker_id: &WorkerId, owner_actor: &str) -> Result<()> {
        self.stores
            .engine_host()?
            .unregister_worker(worker_id, owner_actor)
            .await
    }

    fn register_package(&self, invocation: &Invocation) -> Result<Value> {
        let manifest = invocation.payload.get("manifest").cloned().ok_or_else(|| {
            EngineError::PolicyViolation("module::register_package requires manifest".to_owned())
        })?;
        validate_manifest(&manifest)?;
        let manifest = normalize_package_manifest(manifest)?;
        let package_id = required_value_str(&manifest, "packageId")?;
        let resource_id = package_resource_id(package_id);
        let existing = self.inspect_resource(&resource_id)?;
        let resource = if existing.is_some() {
            let expected_current_version_id = optional_string(
                invocation.payload.get("expectedCurrentVersionId"),
            )?
            .or_else(|| {
                existing
                    .as_ref()
                    .and_then(|item| item.resource.current_version_id.clone())
            });
            let version = self.update_resource(UpdateResource {
                resource_id: resource_id.clone(),
                expected_current_version_id,
                lifecycle: Some("available".to_owned()),
                payload: manifest.clone(),
                state: None,
                locations: Vec::new(),
                trace_id: invocation.causal_context.trace_id.clone(),
                invocation_id: Some(invocation.id.clone()),
            })?;
            let inspection = self
                .inspect_resource(&resource_id)?
                .expect("updated resource must exist");
            return Ok(json!({
                "resource": inspection.resource,
                "version": version,
                "package": {"payload": manifest},
                "resourceRefs": [resource_ref_from_version(&version, WORKER_PACKAGE_KIND, "updated")],
            }));
        } else {
            self.create_resource(CreateResource {
                resource_id: Some(resource_id),
                kind: WORKER_PACKAGE_KIND.to_owned(),
                schema_id: None,
                scope: EngineResourceScope::System,
                owner_worker_id: WorkerId::new(MODULE_WORKER_ID)?,
                owner_actor_id: invocation.causal_context.actor_id.clone(),
                lifecycle: Some("available".to_owned()),
                policy: json!({"managedBy": "module"}),
                initial_payload: Some(manifest.clone()),
                locations: Vec::new(),
                trace_id: invocation.causal_context.trace_id.clone(),
                invocation_id: Some(invocation.id.clone()),
            })?
        };
        Ok(json!({
            "resource": resource,
            "package": {"payload": manifest},
            "resourceRefs": [resource_ref_from_resource(&resource, "created")],
        }))
    }

    async fn inspect_package(&self, invocation: &Invocation) -> Result<Value> {
        let resource_id = package_resource_id_from_payload(&invocation.payload)?;
        let package = self.inspect_resource(&resource_id)?;
        let package_id = package
            .as_ref()
            .and_then(current_payload)
            .and_then(|payload| {
                payload
                    .get("packageId")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned)
            })
            .or_else(|| {
                resource_id
                    .strip_prefix("worker-package:")
                    .map(ToOwned::to_owned)
            });
        let configs = self.list_resources(ListResources {
            kind: Some(MODULE_CONFIG_KIND.to_owned()),
            scope: None,
            lifecycle: None,
            limit: 100,
        })?;
        let activations = self.list_resources(ListResources {
            kind: Some(ACTIVATION_RECORD_KIND.to_owned()),
            scope: None,
            lifecycle: None,
            limit: 100,
        })?;
        let configs = filter_resources_by_package(self, configs, package_id.as_deref())?;
        let activations = filter_resources_by_package(self, activations, package_id.as_deref())?;
        let diagnostics = self
            .package_diagnostics(invocation, package.as_ref(), &configs, &activations)
            .await;
        Ok(json!({
            "package": package,
            "configs": configs,
            "activations": activations,
            "diagnostics": diagnostics,
            "availableActions": module_actions_for_package(package_id.as_deref()),
        }))
    }

    fn configure(&self, invocation: &Invocation) -> Result<Value> {
        let package_resource_id = required_string_owned(&invocation.payload, "packageResourceId")?;
        let package_version_id = required_string_owned(&invocation.payload, "packageVersionId")?;
        let package = require_inspection(self, &package_resource_id, WORKER_PACKAGE_KIND)?;
        let manifest = version_payload(&package, &package_version_id)?;
        let config = invocation.payload.get("config").cloned().ok_or_else(|| {
            EngineError::PolicyViolation("module::configure requires config".to_owned())
        })?;
        let config_schema = manifest.get("configSchema").ok_or_else(|| {
            EngineError::PolicyViolation("worker_package manifest requires configSchema".to_owned())
        })?;
        schema::validate_payload(
            &FunctionId::new(CONFIGURE_FUNCTION)?,
            "module_config",
            config_schema,
            &config,
        )?;
        reject_raw_secrets(&config)?;
        let package_id = required_value_str(&manifest, "packageId")?;
        let (scope, scope_token) = resource_scope_and_token(invocation)?;
        let payload = json!({
            "packageResourceId": package_resource_id,
            "packageVersionId": package_version_id,
            "packageId": package_id,
            "scope": scope_token,
            "configRevision": next_config_revision(self, &config_resource_id(&scope_token, package_id))?,
            "config": config,
            "redactionPolicy": manifest.get("redactionPolicy").cloned().unwrap_or_else(|| json!({"mode": "redacted"})),
            "secretRefs": collect_secret_refs(invocation.payload.get("config").unwrap_or(&Value::Null)),
            "validationHash": hash_json(invocation.payload.get("config").unwrap_or(&Value::Null))?,
        });
        let resource_id = config_resource_id(&scope_token, package_id);
        let existing = self.inspect_resource(&resource_id)?;
        let (resource, version, role) = upsert_resource(
            self,
            UpsertResource {
                resource_id,
                kind: MODULE_CONFIG_KIND,
                lifecycle: "active",
                scope,
                payload,
                expected_current_version_id: optional_string(
                    invocation.payload.get("expectedCurrentVersionId"),
                )?
                .or_else(|| {
                    existing
                        .as_ref()
                        .and_then(|item| item.resource.current_version_id.clone())
                }),
                trace_id: invocation.causal_context.trace_id.clone(),
                invocation_id: Some(invocation.id.clone()),
                actor_id: invocation.causal_context.actor_id.clone(),
            },
        )?;
        link_if_possible(
            self,
            &package.resource.resource_id,
            &resource.resource_id,
            "configured_by",
            invocation,
        );
        Ok(json!({
            "resource": resource,
            "version": version,
            "config": {"payload": version.payload},
            "resourceRefs": [resource_ref_from_version(&version, MODULE_CONFIG_KIND, role)],
        }))
    }

    async fn activate(&self, invocation: &Invocation) -> Result<Value> {
        self.activate_inner(invocation, ActivationMode::Activate)
            .await
    }

    async fn upgrade(&self, invocation: &Invocation) -> Result<Value> {
        self.activate_inner(invocation, ActivationMode::Upgrade)
            .await
    }

    async fn rollback(&self, invocation: &Invocation) -> Result<Value> {
        let activation_resource_id =
            required_string_owned(&invocation.payload, "activationResourceId")?;
        let target_version_id = required_string_owned(&invocation.payload, "targetVersionId")?;
        let activation = require_inspection(self, &activation_resource_id, ACTIVATION_RECORD_KIND)?;
        let target = version_payload(&activation, &target_version_id)?;
        for (field, kind) in [
            ("packageResourceId", WORKER_PACKAGE_KIND),
            ("moduleConfigResourceId", MODULE_CONFIG_KIND),
        ] {
            let id = target.get(field).and_then(Value::as_str).ok_or_else(|| {
                EngineError::PolicyViolation(format!("rollback target missing {field}"))
            })?;
            let _ = require_inspection(self, id, kind)?;
        }
        let package_resource_id = required_value_str(&target, "packageResourceId")?;
        let package_version_id = required_value_str(&target, "packageVersionId")?;
        let config_resource_id_value = required_value_str(&target, "moduleConfigResourceId")?;
        let config_version_id = required_value_str(&target, "configVersionId")?;
        let worker_id = required_value_str(&target, "workerId")?;
        let mut payload = invocation.payload.clone();
        payload["packageResourceId"] = json!(package_resource_id);
        payload["packageVersionId"] = json!(package_version_id);
        payload["moduleConfigResourceId"] = json!(config_resource_id_value);
        payload["configVersionId"] = json!(config_version_id);
        payload["workerId"] = json!(worker_id);
        payload["rollbackTarget"] = json!({
            "activationResourceId": activation_resource_id,
            "targetVersionId": target_version_id,
        });
        let mut rollback_invocation = invocation.clone();
        rollback_invocation.payload = payload;
        self.activate_inner(&rollback_invocation, ActivationMode::Rollback)
            .await
    }

    async fn disable(&self, invocation: &Invocation) -> Result<Value> {
        let resource_id = required_string_owned(&invocation.payload, "activationResourceId")?;
        let inspection = require_inspection(self, &resource_id, ACTIVATION_RECORD_KIND)?;
        let current = current_version(&inspection).ok_or_else(|| {
            EngineError::PolicyViolation(format!("activation {resource_id} has no current version"))
        })?;
        let mut payload = current.payload.clone();
        let grant_id = required_value_str(&payload, "derivedGrantId")?;
        let revoked_grant = self.revoke_grant(
            &AuthorityGrantId::new(grant_id.to_owned())?,
            invocation.causal_context.trace_id.clone(),
        )?;
        let worker_lifecycle = self
            .disconnect_activation_worker(invocation, &payload, "module disabled")
            .await?;
        payload["activationStatus"] = json!("disabled");
        payload["disabledAt"] = json!(Utc::now().to_rfc3339());
        payload["workerLifecycle"] = worker_lifecycle.clone().unwrap_or(Value::Null);
        payload["compensationState"] = json!({
            "status": "grant_revoked",
            "workerLifecycle": worker_lifecycle,
        });
        let version = self.update_resource(UpdateResource {
            resource_id: resource_id.clone(),
            expected_current_version_id: optional_string(
                invocation.payload.get("expectedCurrentVersionId"),
            )?
            .or_else(|| inspection.resource.current_version_id.clone()),
            lifecycle: Some("disabled".to_owned()),
            payload: payload.clone(),
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })?;
        Ok(json!({
            "activation": {"resourceId": resource_id, "payload": payload},
            "version": version,
            "revokedGrant": revoked_grant,
            "workerLifecycle": worker_lifecycle,
            "resourceRefs": [resource_ref_from_version(&version, ACTIVATION_RECORD_KIND, "disabled")],
        }))
    }

    async fn quarantine(&self, invocation: &Invocation) -> Result<Value> {
        let resource_id = required_string_owned(&invocation.payload, "resourceId")?;
        let inspection =
            self.inspect_resource(&resource_id)?
                .ok_or_else(|| EngineError::NotFound {
                    kind: "resource",
                    id: resource_id.clone(),
                })?;
        if !matches!(
            inspection.resource.kind.as_str(),
            WORKER_PACKAGE_KIND | ACTIVATION_RECORD_KIND
        ) {
            return Err(EngineError::PolicyViolation(format!(
                "module::quarantine only accepts worker_package or activation_record resources, got {}",
                inspection.resource.kind
            )));
        }
        let mut payload = current_payload(&inspection).unwrap_or_else(|| json!({}));
        payload["quarantinedAt"] = json!(Utc::now().to_rfc3339());
        payload["activationStatus"] = if inspection.resource.kind == ACTIVATION_RECORD_KIND {
            json!("quarantined")
        } else {
            payload
                .get("activationStatus")
                .cloned()
                .unwrap_or(Value::Null)
        };
        payload["quarantineEvidence"] = invocation
            .payload
            .get("evidenceResourceIds")
            .cloned()
            .unwrap_or_else(|| json!([]));
        let revoked_grant = if inspection.resource.kind == ACTIVATION_RECORD_KIND {
            payload
                .get("derivedGrantId")
                .and_then(Value::as_str)
                .map(|grant_id| {
                    self.revoke_grant(
                        &AuthorityGrantId::new(grant_id.to_owned())?,
                        invocation.causal_context.trace_id.clone(),
                    )
                })
                .transpose()?
        } else {
            None
        };
        let worker_lifecycle = if inspection.resource.kind == ACTIVATION_RECORD_KIND {
            self.disconnect_activation_worker(invocation, &payload, "module quarantined")
                .await?
        } else {
            None
        };
        if let Some(worker_lifecycle) = &worker_lifecycle {
            payload["workerLifecycle"] = worker_lifecycle.clone();
        }
        let version = self.update_resource(UpdateResource {
            resource_id: resource_id.clone(),
            expected_current_version_id: optional_string(
                invocation.payload.get("expectedCurrentVersionId"),
            )?
            .or_else(|| inspection.resource.current_version_id.clone()),
            lifecycle: Some("quarantined".to_owned()),
            payload: payload.clone(),
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })?;
        Ok(json!({
            "resourceId": resource_id,
            "payload": payload,
            "version": version,
            "revokedGrant": revoked_grant,
            "workerLifecycle": worker_lifecycle,
            "resourceRefs": [resource_ref_from_version(&version, &inspection.resource.kind, "quarantined")],
        }))
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ActivationMode {
    Activate,
    Upgrade,
    Rollback,
}

struct UpgradeSource {
    resource_id: String,
    version_id: String,
    grant_id: String,
    worker_id: String,
}

enum RuntimeEntryPoint {
    ExistingOrBuiltin,
    LocalProcess(Box<LocalProcessRuntime>),
}

struct LocalProcessRuntime {
    worker_id: String,
    command_ref: ResourceVersionRef,
    executable_refs: Vec<ResourceVersionRef>,
    expected_function_ids: Vec<String>,
    args: Vec<String>,
    visibility: String,
    timeout_ms: Option<u64>,
    environment_policy: Value,
}

#[derive(Clone)]
struct ResourceVersionRef {
    resource_id: String,
    version_id: String,
    content_hash: Option<String>,
}

struct SpawnedLocalProcess {
    invocation_id: InvocationId,
    result: Value,
    worker: crate::engine::WorkerDefinition,
    grant: EngineGrant,
}

struct EvidenceCreation {
    resource: EngineResource,
    reference: Value,
}

impl ModulePrimitiveHandler {
    async fn activate_inner(&self, invocation: &Invocation, mode: ActivationMode) -> Result<Value> {
        let package_resource_id = required_string_owned(&invocation.payload, "packageResourceId")?;
        let package_version_id = required_string_owned(&invocation.payload, "packageVersionId")?;
        let config_resource_id_value =
            required_string_owned(&invocation.payload, "moduleConfigResourceId")?;
        let config_version_id = required_string_owned(&invocation.payload, "configVersionId")?;
        let package = require_inspection(self, &package_resource_id, WORKER_PACKAGE_KIND)?;
        let config = require_inspection(self, &config_resource_id_value, MODULE_CONFIG_KIND)?;
        let manifest = version_payload(&package, &package_version_id)?;
        let config_payload = version_payload(&config, &config_version_id)?;
        ensure_config_matches_package(&config_payload, &package_resource_id, &package_version_id)?;
        let package_id = required_value_str(&manifest, "packageId")?;
        let namespace = required_value_str(&manifest, "namespace")?;
        let worker_id = optional_string(invocation.payload.get("workerId"))?
            .or_else(|| {
                manifest
                    .get("runtimeEntryPoint")
                    .and_then(|entry| entry.get("workerId"))
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned)
            })
            .ok_or_else(|| {
                EngineError::PolicyViolation(
                    "module::activate requires workerId or runtimeEntryPoint.workerId".to_owned(),
                )
            })?;
        let runtime_entrypoint = validate_runtime_entrypoint(&manifest, &worker_id)?;
        let declared = declared_capabilities(&manifest)?;
        let (scope, scope_token) = resource_scope_and_token(invocation)?;
        let resource_id = activation_resource_id(&scope_token, package_id);
        let upgrade_source =
            upgrade_source(self, invocation, mode, &resource_id, &package_resource_id)?;
        if mode == ActivationMode::Upgrade
            && matches!(&runtime_entrypoint, RuntimeEntryPoint::LocalProcess(_))
            && upgrade_source
                .as_ref()
                .is_some_and(|source| source.worker_id == worker_id)
        {
            return Err(EngineError::PolicyViolation(
                "local_process upgrade requires a replacement workerId; in-place process mutation is not supported"
                    .to_owned(),
            ));
        }
        let child_request = child_grant_from_payload(
            invocation,
            &manifest,
            &WorkerId::new(worker_id.clone())?,
            required_object(
                invocation.payload.get("childGrantRequest"),
                "childGrantRequest",
            )?,
        )?;
        self.ensure_activation_source_policy(
            &manifest,
            &package_resource_id,
            &package_version_id,
            &scope_token,
            &child_request,
        )?;
        let mut spawned_local_process = false;
        let (worker, grant, spawn_invocation_id, spawn_result, worker_lifecycle) =
            match runtime_entrypoint {
                RuntimeEntryPoint::ExistingOrBuiltin => {
                    let worker = self
                        .inspect_worker(&WorkerId::new(worker_id.clone())?)
                        .await?;
                    if !worker
                        .namespace_claims
                        .iter()
                        .any(|claim| claim == namespace)
                    {
                        return Err(EngineError::PolicyViolation(format!(
                            "worker {worker_id} does not claim package namespace {namespace}"
                        )));
                    }
                    let grant = self.derive_grant(child_request)?;
                    (
                        worker,
                        grant,
                        Value::Null,
                        Value::Null,
                        json!({"mode": "bound_existing"}),
                    )
                }
                RuntimeEntryPoint::LocalProcess(local_process) => {
                    spawned_local_process = true;
                    let spawn = match self
                        .spawn_local_process_worker(
                            invocation,
                            &manifest,
                            &local_process,
                            child_request,
                        )
                        .await
                    {
                        Ok(spawn) => spawn,
                        Err(error) => {
                            self.record_activation_runtime_failure(
                                invocation,
                                &package_resource_id,
                                "worker_spawn",
                                None,
                                Some(local_process.worker_id.as_str()),
                                true,
                                &error,
                            )
                            .await;
                            return Err(error);
                        }
                    };
                    (
                        spawn.worker,
                        spawn.grant,
                        json!(spawn.invocation_id.as_str()),
                        spawn.result,
                        json!({"mode": "spawned_local_process", "status": "running"}),
                    )
                }
            };
        if !worker
            .namespace_claims
            .iter()
            .any(|claim| claim == namespace)
        {
            let error = EngineError::PolicyViolation(format!(
                "worker {worker_id} does not claim package namespace {namespace}"
            ));
            self.record_activation_runtime_failure(
                invocation,
                &package_resource_id,
                "post_spawn_validation",
                Some(&grant.grant_id),
                Some(worker.id.as_str()),
                spawned_local_process,
                &error,
            )
            .await;
            return Err(error);
        }
        let registered =
            registered_capabilities_for_worker(self, invocation, &worker.id, namespace).await?;
        if let Err(error) = validate_registered_capabilities(&declared, &registered) {
            self.record_activation_runtime_failure(
                invocation,
                &package_resource_id,
                "post_spawn_validation",
                Some(&grant.grant_id),
                Some(worker.id.as_str()),
                spawned_local_process,
                &error,
            )
            .await;
            return Err(error);
        }
        let grant_hash = hash_json(&json!(grant))?;
        let rollback_target = invocation
            .payload
            .get("rollbackTarget")
            .cloned()
            .unwrap_or(Value::Null);
        let health_policy = invocation
            .payload
            .get("healthPolicy")
            .cloned()
            .or_else(|| manifest.get("healthPolicy").cloned())
            .unwrap_or_else(|| json!({"mode": "catalog_registered"}));
        let supersedes = upgrade_source
            .as_ref()
            .map(|source| {
                json!({
                    "activationResourceId": source.resource_id,
                    "versionId": source.version_id,
                    "grantId": source.grant_id,
                    "workerId": source.worker_id,
                })
            })
            .unwrap_or(Value::Null);
        let status = match mode {
            ActivationMode::Activate | ActivationMode::Upgrade => "active",
            ActivationMode::Rollback => "rolled_back",
        };
        let payload = json!({
            "packageResourceId": package_resource_id,
            "packageVersionId": package_version_id,
            "moduleConfigResourceId": config_resource_id_value,
            "configVersionId": config_version_id,
            "derivedGrantId": grant.grant_id.as_str(),
            "derivedGrantRevision": grant.revision,
            "derivedGrantHash": grant_hash,
            "workerId": worker.id.as_str(),
            "declaredCapabilities": declared.iter().map(|capability| capability.raw.clone()).collect::<Vec<_>>(),
            "registeredCapabilities": registered.iter().map(|function| json!(function)).collect::<Vec<_>>(),
            "healthResult": {"status": "healthy", "mode": "catalog_registered"},
            "spawnInvocationId": spawn_invocation_id,
            "spawnResult": spawn_result,
            "healthPolicy": health_policy,
            "healthInvocationIds": [],
            "integrityDiagnostics": {"status": "valid"},
            "workerLifecycle": worker_lifecycle,
            "activationStatus": status,
            "rollbackTarget": rollback_target,
            "supersedes": supersedes,
            "compensationState": {"status": "none"},
            "runtimeDiagnostics": {
                "lastFailureStage": Value::Null,
                "cleanupStatus": "not_needed",
                "recoveryStatus": "not_needed",
                "latestRecoveryEvidenceRefs": [],
            },
            "scope": scope_token,
        });
        let existing = self.inspect_resource(&resource_id)?;
        let lifecycle = match mode {
            ActivationMode::Rollback => "rolled_back",
            _ => "active",
        };
        let cleanup_grant_id = grant.grant_id.clone();
        let upserted = upsert_resource(
            self,
            UpsertResource {
                resource_id,
                kind: ACTIVATION_RECORD_KIND,
                lifecycle,
                scope,
                payload,
                expected_current_version_id: optional_string(
                    invocation.payload.get("expectedCurrentVersionId"),
                )?
                .or_else(|| {
                    existing
                        .as_ref()
                        .and_then(|item| item.resource.current_version_id.clone())
                }),
                trace_id: invocation.causal_context.trace_id.clone(),
                invocation_id: Some(invocation.id.clone()),
                actor_id: invocation.causal_context.actor_id.clone(),
            },
        );
        let (resource, version, role) = match upserted {
            Ok(value) => value,
            Err(error) => {
                self.record_activation_runtime_failure(
                    invocation,
                    &package_resource_id,
                    "activation_record_persist",
                    Some(&cleanup_grant_id),
                    Some(worker.id.as_str()),
                    spawned_local_process,
                    &error,
                )
                .await;
                return Err(error);
            }
        };
        let mut replaced_grant = None;
        let mut disconnected_worker = None;
        if let Some(source) = &upgrade_source {
            if source.grant_id != grant.grant_id.as_str() {
                replaced_grant = Some(self.revoke_grant(
                    &AuthorityGrantId::new(source.grant_id.clone())?,
                    invocation.causal_context.trace_id.clone(),
                )?);
            }
            if source.worker_id != worker.id.as_str() {
                disconnected_worker = self
                    .disconnect_volatile_worker(
                        &source.worker_id,
                        "module upgrade superseded worker",
                    )
                    .await?;
            }
        }
        link_if_possible(
            self,
            &package.resource.resource_id,
            &resource.resource_id,
            "activates",
            invocation,
        );
        link_if_possible(
            self,
            &resource.resource_id,
            &config.resource.resource_id,
            "configured_by",
            invocation,
        );
        Ok(json!({
            "activation": {"resourceId": resource.resource_id, "payload": version.payload},
            "resource": resource,
            "version": version,
            "grant": grant,
            "replacedGrant": replaced_grant,
            "disconnectedWorker": disconnected_worker,
            "worker": worker,
            "resourceRefs": [resource_ref_from_version(&version, ACTIVATION_RECORD_KIND, role)],
        }))
    }

    async fn package_diagnostics(
        &self,
        invocation: &Invocation,
        package: Option<&EngineResourceInspection>,
        configs: &[Value],
        activations: &[Value],
    ) -> Value {
        let Some(package) = package else {
            return json!({
                "digestStatus": "missing",
                "fileHashStatus": "missing",
                "configStatus": "missing",
                "activationStatus": "inactive",
                "grantStatus": "missing",
                "workerStatus": "missing",
                "registeredCapabilityStatus": "missing",
                "healthStatus": "unknown",
                "sourceTrustStatus": "missing",
                "sourceApprovalStatus": "missing",
                "conformanceStatus": "missing",
                "lastFailureStage": Value::Null,
                "cleanupStatus": "not_needed",
                "recoveryStatus": "not_needed",
                "leakedGrantRefs": [],
                "leakedWorkerRefs": [],
                "latestRecoveryEvidenceRefs": [],
                "recommendedCanonicalActions": []
            });
        };
        let manifest = current_payload(package).unwrap_or(Value::Null);
        let digest_status =
            match required_value_str(&manifest, "packageDigest").and_then(|declared| {
                manifest_digest(&manifest).map(|computed| (declared.to_owned(), computed))
            }) {
                Ok((declared, computed)) if declared == computed => "valid",
                Ok(_) => "invalid",
                Err(_) => "missing",
            };
        let file_hash_status = self.file_hash_status(&manifest);
        let config_status = if configs.is_empty() {
            "missing"
        } else {
            "configured"
        };
        let activation_payload = activations
            .first()
            .and_then(current_payload_from_json_inspection);
        let activation_status = activation_payload
            .and_then(|payload| payload.get("activationStatus"))
            .and_then(Value::as_str)
            .unwrap_or("inactive");
        let grant_status = activation_payload
            .and_then(|payload| payload.get("derivedGrantId"))
            .and_then(Value::as_str)
            .and_then(|grant_id| AuthorityGrantId::new(grant_id.to_owned()).ok())
            .and_then(|grant_id| self.inspect_grant(&grant_id).ok().flatten())
            .map(|grant| match grant.lifecycle {
                EngineGrantLifecycle::Active => "active",
                EngineGrantLifecycle::Revoked => "revoked",
            })
            .unwrap_or("missing");
        let worker_id = activation_payload
            .and_then(|payload| payload.get("workerId"))
            .and_then(Value::as_str)
            .or_else(|| {
                manifest
                    .get("runtimeEntryPoint")
                    .and_then(|entry| entry.get("workerId"))
                    .and_then(Value::as_str)
            });
        let worker_status = if let Some(worker_id) = worker_id {
            match WorkerId::new(worker_id.to_owned()) {
                Ok(worker_id) if self.inspect_worker(&worker_id).await.is_ok() => "registered",
                Ok(_) => "missing",
                Err(_) => "invalid",
            }
        } else {
            "missing"
        };
        let registered_capability_status = match (
            worker_id,
            required_value_str(&manifest, "namespace"),
            declared_capabilities(&manifest),
        ) {
            (Some(worker_id), Ok(namespace), Ok(declared)) => {
                match WorkerId::new(worker_id.to_owned()) {
                    Ok(worker_id) => {
                        match registered_capabilities_for_worker(
                            self, invocation, &worker_id, namespace,
                        )
                        .await
                        {
                            Ok(registered) => {
                                match validate_registered_capabilities(&declared, &registered) {
                                    Ok(()) => "valid",
                                    Err(_) => "invalid",
                                }
                            }
                            Err(_) => "invalid",
                        }
                    }
                    Err(_) => "invalid",
                }
            }
            _ => "missing",
        };
        let health_status = activation_payload
            .and_then(|payload| payload.get("healthResult"))
            .and_then(|health| health.get("status"))
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let source_trust_status = manifest
            .get("sourceTrustStatus")
            .and_then(Value::as_str)
            .unwrap_or("missing");
        let package_version_id = package.resource.current_version_id.as_deref().unwrap_or("");
        let source_approval_status = self
            .source_approval_status_for_package(
                &manifest,
                &package.resource.resource_id,
                package_version_id,
            )
            .unwrap_or("invalid");
        let conformance_status = manifest
            .get("policyDiagnostics")
            .and_then(|diagnostics| diagnostics.get("conformance"))
            .and_then(|conformance| conformance.get("status"))
            .and_then(Value::as_str)
            .or_else(|| {
                manifest
                    .get("conformanceEvidenceRefs")
                    .and_then(Value::as_array)
                    .filter(|refs| !refs.is_empty())
                    .map(|_| "recorded")
            })
            .unwrap_or("missing");
        let runtime_projection = self.activation_runtime_projection(
            activation_payload,
            activation_status,
            worker_id,
            worker_status,
        );
        json!({
            "digestStatus": digest_status,
            "fileHashStatus": file_hash_status,
            "configStatus": config_status,
            "activationStatus": activation_status,
            "grantStatus": grant_status,
            "workerStatus": worker_status,
            "registeredCapabilityStatus": registered_capability_status,
            "healthStatus": health_status,
            "sourceTrustStatus": source_trust_status,
            "sourceApprovalStatus": source_approval_status,
            "conformanceStatus": conformance_status,
            "lastFailureStage": runtime_projection
                .get("lastFailureStage")
                .cloned()
                .unwrap_or(Value::Null),
            "cleanupStatus": runtime_projection
                .get("cleanupStatus")
                .cloned()
                .unwrap_or_else(|| json!("not_needed")),
            "recoveryStatus": runtime_projection
                .get("recoveryStatus")
                .cloned()
                .unwrap_or_else(|| json!("not_needed")),
            "leakedGrantRefs": runtime_projection
                .get("leakedGrantRefs")
                .cloned()
                .unwrap_or_else(|| json!([])),
            "leakedWorkerRefs": runtime_projection
                .get("leakedWorkerRefs")
                .cloned()
                .unwrap_or_else(|| json!([])),
            "latestRecoveryEvidenceRefs": runtime_projection
                .get("latestRecoveryEvidenceRefs")
                .cloned()
                .unwrap_or_else(|| json!([])),
            "recommendedCanonicalActions": runtime_projection
                .get("recommendedCanonicalActions")
                .cloned()
                .unwrap_or_else(|| json!([])),
        })
    }

    fn create_decision_resource(
        &self,
        invocation: &Invocation,
        payload: Value,
        scope: Option<EngineResourceScope>,
        target_resource_id: &str,
        relation: &str,
    ) -> Result<EvidenceCreation> {
        reject_raw_secrets(&payload)?;
        let resource = self.create_resource(CreateResource {
            resource_id: None,
            kind: "decision".to_owned(),
            schema_id: None,
            scope: scope.unwrap_or(EngineResourceScope::System),
            owner_worker_id: WorkerId::new(MODULE_WORKER_ID)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("final".to_owned()),
            policy: json!({"managedBy": "module"}),
            initial_payload: Some(payload),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })?;
        link_if_possible(
            self,
            &resource.resource_id,
            target_resource_id,
            relation,
            invocation,
        );
        Ok(EvidenceCreation {
            reference: resource_ref_from_resource(&resource, "decision"),
            resource,
        })
    }

    fn create_evidence_resource(
        &self,
        invocation: &Invocation,
        summary: &str,
        source: &str,
        target_resource_id: &str,
        metadata: Value,
    ) -> Result<EvidenceCreation> {
        let payload = json!({
            "summary": summary,
            "source": source,
            "resourceRef": target_resource_id,
            "metadata": metadata,
        });
        reject_raw_secrets(&payload)?;
        let resource = self.create_resource(CreateResource {
            resource_id: None,
            kind: "evidence".to_owned(),
            schema_id: None,
            scope: EngineResourceScope::System,
            owner_worker_id: WorkerId::new(MODULE_WORKER_ID)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("accepted".to_owned()),
            policy: json!({"managedBy": "module"}),
            initial_payload: Some(payload),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })?;
        link_if_possible(
            self,
            &resource.resource_id,
            target_resource_id,
            "evidence_for",
            invocation,
        );
        Ok(EvidenceCreation {
            reference: resource_ref_from_resource(&resource, "evidence"),
            resource,
        })
    }
}

struct DeclaredCapability {
    raw: Value,
    function_id: FunctionId,
    effect: EffectClass,
    risk: RiskLevel,
    required_authority: Vec<String>,
    output_resource_kinds: Vec<String>,
}

fn validate_manifest(manifest: &Value) -> Result<()> {
    for field in [
        "packageId",
        "version",
        "manifestSchemaId",
        "sourceProvenance",
        "packageDigest",
        "trustTier",
        "signatureStatus",
        "declaredWorkerKind",
        "namespace",
        "declaredCapabilities",
        "requiredGrants",
        "configSchema",
        "runtimeEntryPoint",
        "healthPolicy",
        "sandboxProcessPolicy",
        "redactionPolicy",
    ] {
        if manifest.get(field).is_none() {
            return Err(EngineError::PolicyViolation(format!(
                "worker_package manifest missing {field}"
            )));
        }
    }
    if required_value_str(manifest, "manifestSchemaId")? != MANIFEST_SCHEMA_ID {
        return Err(EngineError::PolicyViolation(format!(
            "worker_package manifestSchemaId must be {MANIFEST_SCHEMA_ID}"
        )));
    }
    let provenance = required_object(manifest.get("sourceProvenance"), "sourceProvenance")?;
    match provenance.get("kind").and_then(Value::as_str) {
        Some(BUILTIN_PROVENANCE) => {}
        Some(LOCAL_DIGEST_PINNED) => {
            let files = manifest
                .get("declaredFiles")
                .and_then(Value::as_array)
                .ok_or_else(|| {
                    EngineError::PolicyViolation(
                        "local_digest_pinned packages require declaredFiles resource refs"
                            .to_owned(),
                    )
                })?;
            if files.is_empty() {
                return Err(EngineError::PolicyViolation(
                    "local_digest_pinned packages require at least one declared file ref"
                        .to_owned(),
                ));
            }
            for file in files {
                for field in ["resourceId", "versionId", "contentHash"] {
                    let _ = file.get(field).and_then(Value::as_str).ok_or_else(|| {
                        EngineError::PolicyViolation(format!(
                            "declaredFiles entries require {field}"
                        ))
                    })?;
                }
            }
        }
        Some(other) => {
            return Err(EngineError::PolicyViolation(format!(
                "unsupported package provenance {other}"
            )));
        }
        None => {
            return Err(EngineError::PolicyViolation(
                "package sourceProvenance requires kind".to_owned(),
            ));
        }
    }
    let digest = required_value_str(manifest, "packageDigest")?;
    let computed = manifest_digest(manifest)?;
    if digest != computed {
        return Err(EngineError::PolicyViolation(format!(
            "packageDigest mismatch: expected {computed}, got {digest}"
        )));
    }
    let namespace = required_value_str(manifest, "namespace")?;
    validate_namespace(namespace)?;
    let declared = declared_capabilities(manifest)?;
    validate_manifest_runtime(manifest, &declared)?;
    let grants = required_object(manifest.get("requiredGrants"), "requiredGrants")?;
    for field in [
        "allowedCapabilities",
        "allowedNamespaces",
        "allowedAuthorityScopes",
        "allowedResourceKinds",
        "resourceSelectors",
        "fileRoots",
    ] {
        let values = string_array_from(grants.get(field), field)?;
        if values.is_empty() {
            return Err(EngineError::PolicyViolation(format!(
                "requiredGrants.{field} must not be empty"
            )));
        }
    }
    let _ = parse_risk(required_map_str(grants, "maxRisk")?)?;
    let _ = required_map_str(grants, "networkPolicy")?;
    schema::validate_schema_definition(
        &FunctionId::new(CONFIGURE_FUNCTION)?,
        "module_config_schema",
        manifest.get("configSchema").unwrap(),
    )?;
    reject_raw_secrets(manifest)?;
    reject_raw_secrets(manifest.get("redactionPolicy").unwrap())?;
    Ok(())
}

fn normalize_package_manifest(mut manifest: Value) -> Result<Value> {
    let digest = required_value_str(&manifest, "packageDigest")?.to_owned();
    let provenance = manifest
        .get("sourceProvenance")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let kind = source_kind(&manifest)?;
    let (source_status, effective_trust, signature_verification) = match kind.as_str() {
        BUILTIN_PROVENANCE => (
            SOURCE_STATUS_TRUSTED_BUILTIN,
            BUILTIN_PROVENANCE,
            json!({"status": SOURCE_STATUS_TRUSTED_BUILTIN}),
        ),
        LOCAL_DIGEST_PINNED => (
            SOURCE_STATUS_UNVERIFIED,
            "untrusted",
            json!({"status": "not_verified"}),
        ),
        _ => unreachable!("validate_manifest rejects unsupported provenance"),
    };
    manifest["sourceRef"] = json!({"provenance": provenance});
    manifest["sourceDigest"] = json!(digest);
    manifest["sourceTrustStatus"] = json!(source_status);
    manifest["effectiveTrustTier"] = json!(effective_trust);
    if manifest.get("signature").is_none() {
        manifest["signature"] = Value::Null;
    }
    if manifest.get("signatureKeyRef").is_none() {
        manifest["signatureKeyRef"] = Value::Null;
    }
    manifest["signatureVerification"] = signature_verification;
    manifest["sourceEvidenceRefs"] = json!([]);
    manifest["sourceApprovalRefs"] = json!([]);
    manifest["conformanceEvidenceRefs"] = json!([]);
    manifest["policyDiagnostics"] = json!({
        "source": {"status": source_status},
        "conformance": {"status": "not_required"},
    });
    Ok(manifest)
}

fn source_kind(manifest: &Value) -> Result<String> {
    required_object(manifest.get("sourceProvenance"), "sourceProvenance")?
        .get("kind")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .ok_or_else(|| {
            EngineError::PolicyViolation("package sourceProvenance requires kind".to_owned())
        })
}

fn package_has_signature(manifest: &Value) -> bool {
    manifest
        .get("signature")
        .is_some_and(|value| !value.is_null())
        || manifest
            .get("signatureKeyRef")
            .is_some_and(|value| !value.is_null())
}

fn package_selector_matches(
    selectors: &[String],
    manifest: &Value,
    package_resource_id: &str,
) -> Result<bool> {
    let package_id = required_value_str(manifest, "packageId")?;
    let namespace = required_value_str(manifest, "namespace")?;
    Ok(selectors.iter().any(|selector| {
        selector == "*"
            || selector == package_id
            || selector == package_resource_id
            || selector == &format!("namespace:{namespace}")
            || selector == &format!("{namespace}/*")
    }))
}

fn declared_capabilities(manifest: &Value) -> Result<Vec<DeclaredCapability>> {
    let namespace = required_value_str(manifest, "namespace")?;
    let capabilities = manifest
        .get("declaredCapabilities")
        .and_then(Value::as_array)
        .ok_or_else(|| {
            EngineError::PolicyViolation(
                "worker_package declaredCapabilities must be an array".to_owned(),
            )
        })?;
    if capabilities.is_empty() {
        return Err(EngineError::PolicyViolation(
            "worker_package must declare at least one capability".to_owned(),
        ));
    }
    capabilities
        .iter()
        .map(|capability| {
            let function_id = FunctionId::new(required_value_str(capability, "functionId")?)?;
            if function_id.namespace() != namespace {
                return Err(EngineError::PolicyViolation(format!(
                    "declared capability {} exceeds package namespace {namespace}",
                    function_id
                )));
            }
            let effect = parse_effect(required_value_str(capability, "effectClass")?)?;
            let risk = parse_risk(required_value_str(capability, "risk")?)?;
            let required_authority =
                string_array_from(capability.get("requiredAuthority"), "requiredAuthority")?;
            let output_resource_kinds =
                string_array_from(capability.get("outputResourceKinds"), "outputResourceKinds")?;
            if effect.requires_idempotency()
                && !capability
                    .get("idempotent")
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
            {
                return Err(EngineError::PolicyViolation(format!(
                    "declared mutating capability {} requires idempotency",
                    function_id
                )));
            }
            if effect.requires_idempotency() && output_resource_kinds.is_empty() {
                return Err(EngineError::PolicyViolation(format!(
                    "declared mutating capability {} requires an output resource contract",
                    function_id
                )));
            }
            Ok(DeclaredCapability {
                raw: capability.clone(),
                function_id,
                effect,
                risk,
                required_authority,
                output_resource_kinds,
            })
        })
        .collect()
}

async fn registered_capabilities_for_worker(
    host: &ModulePrimitiveHandler,
    invocation: &Invocation,
    worker_id: &WorkerId,
    namespace: &str,
) -> Result<Vec<FunctionDefinition>> {
    let actor = ActorContext {
        actor_id: invocation.causal_context.actor_id.clone(),
        actor_kind: ActorKind::System,
        authority_grant_id: invocation.causal_context.authority_grant_id.clone(),
        authority_scopes: Vec::new(),
        session_id: invocation.causal_context.session_id.clone(),
        workspace_id: invocation.causal_context.workspace_id.clone(),
    };
    Ok(host
        .discover_functions(&FunctionQuery {
            actor: Some(actor),
            include_internal: true,
            ..FunctionQuery::default()
        })
        .await
        .into_iter()
        .filter(|function| {
            &function.owner_worker == worker_id && function.id.namespace() == namespace
        })
        .collect())
}

fn validate_registered_capabilities(
    declared: &[DeclaredCapability],
    registered: &[FunctionDefinition],
) -> Result<()> {
    for function in registered {
        let Some(declared) = declared
            .iter()
            .find(|declared| declared.function_id == function.id)
        else {
            return Err(EngineError::PolicyViolation(format!(
                "registered capability {} is not declared by package",
                function.id
            )));
        };
        if function.effect_class != declared.effect {
            return Err(EngineError::PolicyViolation(format!(
                "registered capability {} effect exceeds package manifest",
                function.id
            )));
        }
        if function.risk_level > declared.risk {
            return Err(EngineError::PolicyViolation(format!(
                "registered capability {} risk exceeds package manifest",
                function.id
            )));
        }
        for scope in &function.required_authority.scopes {
            if !declared
                .required_authority
                .iter()
                .any(|allowed| allowed == scope)
            {
                return Err(EngineError::PolicyViolation(format!(
                    "registered capability {} authority exceeds package manifest",
                    function.id
                )));
            }
        }
        if function.effect_class.requires_idempotency() && function.idempotency.is_none() {
            return Err(EngineError::PolicyViolation(format!(
                "registered capability {} is mutating without idempotency",
                function.id
            )));
        }
        if !declared.output_resource_kinds.is_empty() {
            let DurableOutputContract::ResourceBacked {
                produced_resource_kinds,
                ..
            } = &function.output_contract
            else {
                return Err(EngineError::PolicyViolation(format!(
                    "registered capability {} lacks resource-backed output contract",
                    function.id
                )));
            };
            for kind in &declared.output_resource_kinds {
                if !produced_resource_kinds
                    .iter()
                    .any(|candidate| candidate == kind)
                {
                    return Err(EngineError::PolicyViolation(format!(
                        "registered capability {} output kinds exceed package manifest",
                        function.id
                    )));
                }
            }
        }
    }
    for declared in declared {
        if !registered
            .iter()
            .any(|function| function.id == declared.function_id)
        {
            return Err(EngineError::PolicyViolation(format!(
                "declared capability {} was not registered by worker",
                declared.function_id
            )));
        }
    }
    Ok(())
}

fn child_grant_from_payload(
    invocation: &Invocation,
    manifest: &Value,
    worker_id: &WorkerId,
    request: &serde_json::Map<String, Value>,
) -> Result<DeriveGrant> {
    let manifest_grants = required_object(manifest.get("requiredGrants"), "requiredGrants")?;
    let allowed_capabilities = child_string_array(request, manifest_grants, "allowedCapabilities")?;
    let allowed_namespaces = child_string_array(request, manifest_grants, "allowedNamespaces")?;
    let allowed_authority_scopes =
        child_string_array(request, manifest_grants, "allowedAuthorityScopes")?;
    let allowed_resource_kinds =
        child_string_array(request, manifest_grants, "allowedResourceKinds")?;
    let resource_selectors = child_string_array(request, manifest_grants, "resourceSelectors")?;
    let file_roots = child_string_array(request, manifest_grants, "fileRoots")?;
    ensure_subset(
        &allowed_capabilities,
        &string_array_from(
            manifest_grants.get("allowedCapabilities"),
            "allowedCapabilities",
        )?,
        "declared capabilities",
    )?;
    ensure_subset(
        &allowed_namespaces,
        &string_array_from(
            manifest_grants.get("allowedNamespaces"),
            "allowedNamespaces",
        )?,
        "declared namespaces",
    )?;
    ensure_subset(
        &allowed_authority_scopes,
        &string_array_from(
            manifest_grants.get("allowedAuthorityScopes"),
            "allowedAuthorityScopes",
        )?,
        "declared authority scopes",
    )?;
    ensure_subset(
        &allowed_resource_kinds,
        &string_array_from(
            manifest_grants.get("allowedResourceKinds"),
            "allowedResourceKinds",
        )?,
        "declared resource kinds",
    )?;
    ensure_subset(
        &resource_selectors,
        &string_array_from(
            manifest_grants.get("resourceSelectors"),
            "resourceSelectors",
        )?,
        "declared resource selectors",
    )?;
    ensure_subset(
        &file_roots,
        &string_array_from(manifest_grants.get("fileRoots"), "fileRoots")?,
        "declared file roots",
    )?;
    let network_policy = request
        .get("networkPolicy")
        .and_then(Value::as_str)
        .unwrap_or_else(|| {
            manifest_grants
                .get("networkPolicy")
                .and_then(Value::as_str)
                .unwrap_or("none")
        })
        .to_owned();
    if network_rank(&network_policy)?
        > network_rank(required_map_str(manifest_grants, "networkPolicy")?)?
    {
        return Err(EngineError::PolicyViolation(
            "requested network policy exceeds package manifest".to_owned(),
        ));
    }
    let max_risk = parse_risk(
        request
            .get("maxRisk")
            .and_then(Value::as_str)
            .unwrap_or(required_map_str(manifest_grants, "maxRisk")?),
    )?;
    if max_risk > parse_risk(required_map_str(manifest_grants, "maxRisk")?)? {
        return Err(EngineError::PolicyViolation(
            "requested risk exceeds package manifest".to_owned(),
        ));
    }
    let can_delegate = request
        .get("canDelegate")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if can_delegate
        && !manifest_grants
            .get("canDelegate")
            .and_then(Value::as_bool)
            .unwrap_or(false)
    {
        return Err(EngineError::PolicyViolation(
            "requested delegation exceeds package manifest".to_owned(),
        ));
    }
    let approval_required = request
        .get("approvalRequired")
        .and_then(Value::as_bool)
        .unwrap_or_else(|| {
            manifest_grants
                .get("approvalRequired")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        });
    Ok(DeriveGrant {
        grant_id: request
            .get("grantId")
            .and_then(Value::as_str)
            .map(|value| AuthorityGrantId::new(value.to_owned()))
            .transpose()?,
        parent_grant_id: invocation.causal_context.authority_grant_id.clone(),
        subject_actor_id: None,
        subject_worker_id: Some(worker_id.clone()),
        subject_invocation_id: Some(invocation.id.clone()),
        allowed_capabilities,
        allowed_namespaces,
        allowed_authority_scopes,
        allowed_resource_kinds,
        resource_selectors,
        file_roots,
        network_policy,
        max_risk,
        budget: request
            .get("budget")
            .cloned()
            .unwrap_or_else(|| json!({"class": "module_activation"})),
        expires_at: request
            .get("expiresAt")
            .and_then(Value::as_str)
            .map(parse_datetime)
            .transpose()?,
        can_delegate,
        approval_required,
        provenance: json!({
            "source": "module.activate",
            "invocationId": invocation.id.as_str(),
        }),
        trace_id: invocation.causal_context.trace_id.clone(),
    })
}

fn validate_manifest_runtime(manifest: &Value, declared: &[DeclaredCapability]) -> Result<()> {
    let entry = required_object(manifest.get("runtimeEntryPoint"), "runtimeEntryPoint")?;
    let worker_id = required_map_str(entry, "workerId")?;
    let _ = validate_runtime_entrypoint_with_declared(manifest, worker_id, declared)?;
    Ok(())
}

fn validate_runtime_entrypoint(manifest: &Value, worker_id: &str) -> Result<RuntimeEntryPoint> {
    let declared = declared_capabilities(manifest)?;
    validate_runtime_entrypoint_with_declared(manifest, worker_id, &declared)
}

fn validate_runtime_entrypoint_with_declared(
    manifest: &Value,
    worker_id: &str,
    declared: &[DeclaredCapability],
) -> Result<RuntimeEntryPoint> {
    let entry = required_object(manifest.get("runtimeEntryPoint"), "runtimeEntryPoint")?;
    let kind = entry.get("kind").and_then(Value::as_str).ok_or_else(|| {
        EngineError::PolicyViolation("runtimeEntryPoint requires kind".to_owned())
    })?;
    if entry
        .get("workerId")
        .and_then(Value::as_str)
        .is_some_and(|declared| declared != worker_id)
    {
        return Err(EngineError::PolicyViolation(format!(
            "activation workerId {worker_id} does not match manifest runtimeEntryPoint"
        )));
    }
    match kind {
        "existing_worker" | "builtin" => Ok(RuntimeEntryPoint::ExistingOrBuiltin),
        "local_process" => parse_local_process_runtime(manifest, entry, declared),
        other => Err(EngineError::PolicyViolation(format!(
            "unsupported runtimeEntryPoint kind {other}"
        ))),
    }
}

fn parse_local_process_runtime(
    manifest: &Value,
    entry: &serde_json::Map<String, Value>,
    declared: &[DeclaredCapability],
) -> Result<RuntimeEntryPoint> {
    if manifest
        .get("sourceProvenance")
        .and_then(|source| source.get("kind"))
        .and_then(Value::as_str)
        != Some(LOCAL_DIGEST_PINNED)
    {
        return Err(EngineError::PolicyViolation(
            "local_process packages must use local_digest_pinned provenance".to_owned(),
        ));
    }
    reject_raw_secrets(&Value::Object(entry.clone()))?;
    let worker_id = required_map_str(entry, "workerId")?.to_owned();
    let declared_files = resource_version_refs(manifest.get("declaredFiles"), "declaredFiles")?;
    let executable_refs = resource_version_refs(entry.get("executableRefs"), "executableRefs")?;
    if executable_refs.is_empty() {
        return Err(EngineError::PolicyViolation(
            "local_process runtimeEntryPoint.executableRefs must not be empty".to_owned(),
        ));
    }
    for executable_ref in &executable_refs {
        if !declared_files.iter().any(|declared_file| {
            declared_file.resource_id == executable_ref.resource_id
                && declared_file.version_id == executable_ref.version_id
                && declared_file.content_hash == executable_ref.content_hash
        }) {
            return Err(EngineError::PolicyViolation(
                "local_process executableRefs must be declaredFiles refs".to_owned(),
            ));
        }
    }
    let command = required_object(entry.get("commandTemplate"), "commandTemplate")?;
    if required_map_str(command, "kind")? != "materialized_file" {
        return Err(EngineError::PolicyViolation(
            "local_process commandTemplate must target a materialized_file ref".to_owned(),
        ));
    }
    let command_ref = ResourceVersionRef {
        resource_id: required_map_str(command, "resourceId")?.to_owned(),
        version_id: required_map_str(command, "versionId")?.to_owned(),
        content_hash: command
            .get("contentHash")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned),
    };
    if !executable_refs.iter().any(|reference| {
        reference.resource_id == command_ref.resource_id
            && reference.version_id == command_ref.version_id
    }) {
        return Err(EngineError::PolicyViolation(
            "local_process commandTemplate must reference one runtimeEntryPoint.executableRefs entry"
                .to_owned(),
        ));
    }
    let expected_function_ids =
        string_array_from(entry.get("expectedFunctionIds"), "expectedFunctionIds")?;
    if expected_function_ids.is_empty() {
        return Err(EngineError::PolicyViolation(
            "local_process runtimeEntryPoint.expectedFunctionIds must not be empty".to_owned(),
        ));
    }
    let declared_function_ids = declared
        .iter()
        .map(|capability| capability.function_id.as_str().to_owned())
        .collect::<Vec<_>>();
    ensure_same_set(
        &expected_function_ids,
        &declared_function_ids,
        "local_process expectedFunctionIds",
    )?;
    let working_directory = required_object(entry.get("workingDirectory"), "workingDirectory")?;
    if required_map_str(working_directory, "kind")? != "package_file_parent" {
        return Err(EngineError::PolicyViolation(
            "local_process workingDirectory must be package_file_parent".to_owned(),
        ));
    }
    let environment_policy = entry.get("environmentPolicy").cloned().ok_or_else(|| {
        EngineError::PolicyViolation(
            "local_process runtimeEntryPoint requires environmentPolicy".to_owned(),
        )
    })?;
    if environment_policy.get("mode").and_then(Value::as_str) != Some("empty") {
        return Err(EngineError::PolicyViolation(
            "local_process environmentPolicy.mode must be empty".to_owned(),
        ));
    }
    let args = literal_args(entry.get("argsTemplate"))?;
    let visibility = entry
        .get("visibility")
        .and_then(Value::as_str)
        .unwrap_or("session")
        .to_owned();
    if !matches!(visibility.as_str(), "session" | "workspace" | "system") {
        return Err(EngineError::PolicyViolation(format!(
            "unsupported local_process visibility {visibility}"
        )));
    }
    let timeout_ms = entry.get("timeoutMs").and_then(Value::as_u64);
    if timeout_ms.is_some_and(|value| !(100..=60_000).contains(&value)) {
        return Err(EngineError::PolicyViolation(
            "local_process timeoutMs must be between 100 and 60000".to_owned(),
        ));
    }
    Ok(RuntimeEntryPoint::LocalProcess(Box::new(
        LocalProcessRuntime {
            worker_id,
            command_ref,
            executable_refs,
            expected_function_ids,
            args,
            visibility,
            timeout_ms,
            environment_policy,
        },
    )))
}

fn upgrade_source(
    host: &ModulePrimitiveHandler,
    invocation: &Invocation,
    mode: ActivationMode,
    expected_resource_id: &str,
    package_resource_id: &str,
) -> Result<Option<UpgradeSource>> {
    if mode != ActivationMode::Upgrade {
        return Ok(None);
    }
    let resource_id = required_string_owned(&invocation.payload, "activationResourceId")?;
    if resource_id != expected_resource_id {
        return Err(EngineError::PolicyViolation(format!(
            "module::upgrade activationResourceId {resource_id} does not match package activation {expected_resource_id}"
        )));
    }
    let inspection = require_inspection(host, &resource_id, ACTIVATION_RECORD_KIND)?;
    if matches!(
        inspection.resource.lifecycle.as_str(),
        "disabled" | "failed" | "quarantined" | "damaged"
    ) {
        return Err(EngineError::PolicyViolation(format!(
            "module::upgrade requires an active activation, got {}",
            inspection.resource.lifecycle
        )));
    }
    let current = current_version(&inspection).ok_or_else(|| {
        EngineError::PolicyViolation(format!("activation {resource_id} has no current version"))
    })?;
    let payload = &current.payload;
    if payload.get("packageResourceId").and_then(Value::as_str) != Some(package_resource_id) {
        return Err(EngineError::PolicyViolation(
            "module::upgrade package does not match activation being replaced".to_owned(),
        ));
    }
    let grant_id = required_value_str(payload, "derivedGrantId")?.to_owned();
    let grant = host
        .inspect_grant(&AuthorityGrantId::new(grant_id.clone())?)?
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "module::upgrade source grant {grant_id} is not inspectable"
            ))
        })?;
    if grant.lifecycle != EngineGrantLifecycle::Active {
        return Err(EngineError::PolicyViolation(format!(
            "module::upgrade source grant {grant_id} is not active"
        )));
    }
    let worker_id = required_value_str(payload, "workerId")?.to_owned();
    Ok(Some(UpgradeSource {
        resource_id,
        version_id: current.version_id.clone(),
        grant_id,
        worker_id,
    }))
}

fn ensure_config_matches_package(
    config_payload: &Value,
    package_resource_id: &str,
    package_version_id: &str,
) -> Result<()> {
    if config_payload
        .get("packageResourceId")
        .and_then(Value::as_str)
        != Some(package_resource_id)
        || config_payload
            .get("packageVersionId")
            .and_then(Value::as_str)
            != Some(package_version_id)
    {
        return Err(EngineError::PolicyViolation(
            "module_config does not match requested package version".to_owned(),
        ));
    }
    Ok(())
}

struct UpsertResource {
    resource_id: String,
    kind: &'static str,
    lifecycle: &'static str,
    scope: EngineResourceScope,
    payload: Value,
    expected_current_version_id: Option<String>,
    trace_id: crate::engine::TraceId,
    invocation_id: Option<crate::engine::InvocationId>,
    actor_id: ActorId,
}

fn upsert_resource(
    host: &ModulePrimitiveHandler,
    request: UpsertResource,
) -> Result<(EngineResource, EngineResourceVersion, &'static str)> {
    if let Some(existing) = host.inspect_resource(&request.resource_id)? {
        let version = host.update_resource(UpdateResource {
            resource_id: request.resource_id,
            expected_current_version_id: request
                .expected_current_version_id
                .or(existing.resource.current_version_id.clone()),
            lifecycle: Some(request.lifecycle.to_owned()),
            payload: request.payload,
            state: None,
            locations: Vec::new(),
            trace_id: request.trace_id,
            invocation_id: request.invocation_id,
        })?;
        let resource = host
            .inspect_resource(&version.resource_id)?
            .expect("updated resource must exist")
            .resource;
        Ok((resource, version, "updated"))
    } else {
        let resource = host.create_resource(CreateResource {
            resource_id: Some(request.resource_id),
            kind: request.kind.to_owned(),
            schema_id: None,
            scope: request.scope,
            owner_worker_id: WorkerId::new(MODULE_WORKER_ID)?,
            owner_actor_id: request.actor_id,
            lifecycle: Some(request.lifecycle.to_owned()),
            policy: json!({"managedBy": "module"}),
            initial_payload: Some(request.payload),
            locations: Vec::new(),
            trace_id: request.trace_id,
            invocation_id: request.invocation_id,
        })?;
        let inspection = host
            .inspect_resource(&resource.resource_id)?
            .expect("created resource must be inspectable");
        let version =
            current_version(&inspection)
                .cloned()
                .ok_or_else(|| EngineError::LedgerFailure {
                    operation: "module.upsert",
                    message: "created resource missing initial version".to_owned(),
                })?;
        Ok((resource, version, "created"))
    }
}

fn required_object<'a>(
    value: Option<&'a Value>,
    field: &str,
) -> Result<&'a serde_json::Map<String, Value>> {
    value.and_then(Value::as_object).ok_or_else(|| {
        EngineError::PolicyViolation(format!("required field {field} must be an object"))
    })
}

fn required_value_str<'a>(value: &'a Value, field: &str) -> Result<&'a str> {
    value.get(field).and_then(Value::as_str).ok_or_else(|| {
        EngineError::PolicyViolation(format!("required field {field} must be a string"))
    })
}

fn required_map_str<'a>(value: &'a serde_json::Map<String, Value>, field: &str) -> Result<&'a str> {
    value.get(field).and_then(Value::as_str).ok_or_else(|| {
        EngineError::PolicyViolation(format!("required field {field} must be a string"))
    })
}

fn string_array_from(value: Option<&Value>, field: &str) -> Result<Vec<String>> {
    let items = value.and_then(Value::as_array).ok_or_else(|| {
        EngineError::PolicyViolation(format!("required field {field} must be an array"))
    })?;
    items
        .iter()
        .map(|item| {
            item.as_str().map(ToOwned::to_owned).ok_or_else(|| {
                EngineError::PolicyViolation(format!("{field} entries must be strings"))
            })
        })
        .collect()
}

fn resource_version_refs(value: Option<&Value>, field: &str) -> Result<Vec<ResourceVersionRef>> {
    let items = value.and_then(Value::as_array).ok_or_else(|| {
        EngineError::PolicyViolation(format!("required field {field} must be an array"))
    })?;
    items
        .iter()
        .map(|item| {
            let object = item.as_object().ok_or_else(|| {
                EngineError::PolicyViolation(format!("{field} entries must be objects"))
            })?;
            Ok(ResourceVersionRef {
                resource_id: required_map_str(object, "resourceId")?.to_owned(),
                version_id: required_map_str(object, "versionId")?.to_owned(),
                content_hash: object
                    .get("contentHash")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
            })
        })
        .collect()
}

fn literal_args(value: Option<&Value>) -> Result<Vec<String>> {
    let Some(value) = value else {
        return Ok(Vec::new());
    };
    let items = value
        .as_array()
        .ok_or_else(|| EngineError::PolicyViolation("argsTemplate must be an array".to_owned()))?;
    if items.len() > 64 {
        return Err(EngineError::PolicyViolation(
            "argsTemplate may contain at most 64 entries".to_owned(),
        ));
    }
    items
        .iter()
        .map(|item| {
            let object = item.as_object().ok_or_else(|| {
                EngineError::PolicyViolation("argsTemplate entries must be objects".to_owned())
            })?;
            if object.len() != 1 || !object.contains_key("literal") {
                return Err(EngineError::PolicyViolation(
                    "argsTemplate entries must be literal-only in this phase".to_owned(),
                ));
            }
            required_map_str(object, "literal").map(ToOwned::to_owned)
        })
        .collect()
}

fn child_string_array(
    request: &serde_json::Map<String, Value>,
    manifest: &serde_json::Map<String, Value>,
    field: &str,
) -> Result<Vec<String>> {
    if let Some(value) = request.get(field) {
        string_array_from(Some(value), field)
    } else {
        string_array_from(manifest.get(field), field)
    }
}

fn ensure_subset(child: &[String], parent: &[String], label: &str) -> Result<()> {
    if parent.iter().any(|value| value == "*") {
        return Ok(());
    }
    for value in child {
        if !parent.iter().any(|allowed| allowed == value) {
            return Err(EngineError::PolicyViolation(format!(
                "requested {label} include unauthorized value {value}"
            )));
        }
    }
    Ok(())
}

fn ensure_grant_request_narrows_caller(
    host: &ModulePrimitiveHandler,
    invocation: &Invocation,
    request: &DeriveGrant,
) -> Result<()> {
    let parent = host
        .inspect_grant(&invocation.causal_context.authority_grant_id)?
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "caller grant {} is not inspectable",
                invocation.causal_context.authority_grant_id
            ))
        })?;
    if parent.lifecycle != EngineGrantLifecycle::Active {
        return Err(EngineError::PolicyViolation(format!(
            "caller grant {} is not active",
            parent.grant_id
        )));
    }
    ensure_subset(
        &request.allowed_capabilities,
        &parent.allowed_capabilities,
        "caller grant capabilities",
    )?;
    ensure_subset(
        &request.allowed_namespaces,
        &parent.allowed_namespaces,
        "caller grant namespaces",
    )?;
    ensure_subset(
        &request.allowed_authority_scopes,
        &parent.allowed_authority_scopes,
        "caller grant authority scopes",
    )?;
    ensure_subset(
        &request.allowed_resource_kinds,
        &parent.allowed_resource_kinds,
        "caller grant resource kinds",
    )?;
    ensure_subset(
        &request.resource_selectors,
        &parent.resource_selectors,
        "caller grant resource selectors",
    )?;
    ensure_subset(
        &request.file_roots,
        &parent.file_roots,
        "caller grant file roots",
    )?;
    if network_rank(&request.network_policy)? > network_rank(&parent.network_policy)? {
        return Err(EngineError::PolicyViolation(
            "requested network policy exceeds caller grant".to_owned(),
        ));
    }
    if request.max_risk > parent.max_risk {
        return Err(EngineError::PolicyViolation(
            "requested maxRisk exceeds caller grant".to_owned(),
        ));
    }
    if let (Some(child), Some(parent)) = (request.expires_at, parent.expires_at)
        && child > parent
    {
        return Err(EngineError::PolicyViolation(
            "requested expiry exceeds caller grant".to_owned(),
        ));
    }
    if request.can_delegate && !parent.can_delegate {
        return Err(EngineError::PolicyViolation(
            "requested delegation exceeds caller grant".to_owned(),
        ));
    }
    if parent.approval_required && !request.approval_required {
        return Err(EngineError::PolicyViolation(
            "caller grant requires child approval".to_owned(),
        ));
    }
    Ok(())
}

fn ensure_grant_ceiling_narrows_caller(
    host: &ModulePrimitiveHandler,
    invocation: &Invocation,
    ceiling: &serde_json::Map<String, Value>,
) -> Result<()> {
    let parent = host
        .inspect_grant(&invocation.causal_context.authority_grant_id)?
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "caller grant {} is not inspectable",
                invocation.causal_context.authority_grant_id
            ))
        })?;
    if parent.lifecycle != EngineGrantLifecycle::Active {
        return Err(EngineError::PolicyViolation(format!(
            "caller grant {} is not active",
            parent.grant_id
        )));
    }
    ensure_subset(
        &string_array_from(ceiling.get("allowedCapabilities"), "allowedCapabilities")?,
        &parent.allowed_capabilities,
        "caller grant capabilities",
    )?;
    ensure_subset(
        &string_array_from(ceiling.get("allowedNamespaces"), "allowedNamespaces")?,
        &parent.allowed_namespaces,
        "caller grant namespaces",
    )?;
    ensure_subset(
        &string_array_from(
            ceiling.get("allowedAuthorityScopes"),
            "allowedAuthorityScopes",
        )?,
        &parent.allowed_authority_scopes,
        "caller grant authority scopes",
    )?;
    ensure_subset(
        &string_array_from(ceiling.get("allowedResourceKinds"), "allowedResourceKinds")?,
        &parent.allowed_resource_kinds,
        "caller grant resource kinds",
    )?;
    ensure_subset(
        &string_array_from(ceiling.get("resourceSelectors"), "resourceSelectors")?,
        &parent.resource_selectors,
        "caller grant resource selectors",
    )?;
    ensure_subset(
        &string_array_from(ceiling.get("fileRoots"), "fileRoots")?,
        &parent.file_roots,
        "caller grant file roots",
    )?;
    if network_rank(required_map_str(ceiling, "networkPolicy")?)?
        > network_rank(&parent.network_policy)?
    {
        return Err(EngineError::PolicyViolation(
            "trust grant ceiling exceeds caller network policy".to_owned(),
        ));
    }
    if parse_risk(required_map_str(ceiling, "maxRisk")?)? > parent.max_risk {
        return Err(EngineError::PolicyViolation(
            "trust grant ceiling exceeds caller maxRisk".to_owned(),
        ));
    }
    if ceiling
        .get("canDelegate")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        && !parent.can_delegate
    {
        return Err(EngineError::PolicyViolation(
            "trust grant ceiling exceeds caller delegation".to_owned(),
        ));
    }
    if parent.approval_required
        && !ceiling
            .get("approvalRequired")
            .and_then(Value::as_bool)
            .unwrap_or(false)
    {
        return Err(EngineError::PolicyViolation(
            "caller grant requires trust ceiling approval".to_owned(),
        ));
    }
    Ok(())
}

fn ensure_grant_request_within_ceiling(
    request: &DeriveGrant,
    ceiling: &serde_json::Map<String, Value>,
) -> Result<()> {
    ensure_subset(
        &request.allowed_capabilities,
        &string_array_from(ceiling.get("allowedCapabilities"), "allowedCapabilities")?,
        "approval grant capabilities",
    )?;
    ensure_subset(
        &request.allowed_namespaces,
        &string_array_from(ceiling.get("allowedNamespaces"), "allowedNamespaces")?,
        "approval grant namespaces",
    )?;
    ensure_subset(
        &request.allowed_authority_scopes,
        &string_array_from(
            ceiling.get("allowedAuthorityScopes"),
            "allowedAuthorityScopes",
        )?,
        "approval grant authority scopes",
    )?;
    ensure_subset(
        &request.allowed_resource_kinds,
        &string_array_from(ceiling.get("allowedResourceKinds"), "allowedResourceKinds")?,
        "approval grant resource kinds",
    )?;
    ensure_subset(
        &request.resource_selectors,
        &string_array_from(ceiling.get("resourceSelectors"), "resourceSelectors")?,
        "approval grant resource selectors",
    )?;
    ensure_subset(
        &request.file_roots,
        &string_array_from(ceiling.get("fileRoots"), "fileRoots")?,
        "approval grant file roots",
    )?;
    if network_rank(&request.network_policy)?
        > network_rank(required_map_str(ceiling, "networkPolicy")?)?
    {
        return Err(EngineError::PolicyViolation(
            "requested network policy exceeds source approval".to_owned(),
        ));
    }
    if request.max_risk > parse_risk(required_map_str(ceiling, "maxRisk")?)? {
        return Err(EngineError::PolicyViolation(
            "requested maxRisk exceeds source approval".to_owned(),
        ));
    }
    if request.can_delegate
        && !ceiling
            .get("canDelegate")
            .and_then(Value::as_bool)
            .unwrap_or(false)
    {
        return Err(EngineError::PolicyViolation(
            "requested delegation exceeds source approval".to_owned(),
        ));
    }
    Ok(())
}

fn ensure_same_set(child: &[String], parent: &[String], label: &str) -> Result<()> {
    ensure_subset(child, parent, label)?;
    ensure_subset(parent, child, label)?;
    Ok(())
}

fn risk_label(risk: RiskLevel) -> &'static str {
    match risk {
        RiskLevel::Low => "low",
        RiskLevel::Medium => "medium",
        RiskLevel::High => "high",
        RiskLevel::Critical => "critical",
    }
}

fn ensure_path_within_grant_roots(path: &str, roots: &[String]) -> Result<()> {
    if roots.iter().any(|root| root == "*") {
        return Ok(());
    }
    let path = canonical_path_lossy(path)?;
    for root in roots {
        let root = canonical_path_lossy(root)?;
        if path.starts_with(&root) {
            return Ok(());
        }
    }
    Err(EngineError::PolicyViolation(format!(
        "materialized executable {} is outside activation fileRoots",
        path.display()
    )))
}

fn canonical_path_lossy(path: &str) -> Result<PathBuf> {
    let path = PathBuf::from(path);
    if path.exists() {
        path.canonicalize().map_err(|error| {
            EngineError::PolicyViolation(format!(
                "failed to canonicalize materialized path {}: {error}",
                path.display()
            ))
        })
    } else if path.is_absolute() {
        Ok(path)
    } else {
        std::env::current_dir()
            .map(|cwd| cwd.join(path))
            .map_err(|error| {
                EngineError::PolicyViolation(format!(
                    "failed to resolve relative materialized path: {error}"
                ))
            })
    }
}

fn parse_effect(value: &str) -> Result<EffectClass> {
    match value {
        "PureRead" | "pure_read" => Ok(EffectClass::PureRead),
        "DeterministicCompute" | "deterministic_compute" => Ok(EffectClass::DeterministicCompute),
        "IdempotentWrite" | "idempotent_write" => Ok(EffectClass::IdempotentWrite),
        "AppendOnlyEvent" | "append_only_event" => Ok(EffectClass::AppendOnlyEvent),
        "ReversibleSideEffect" | "reversible_side_effect" => Ok(EffectClass::ReversibleSideEffect),
        "ExternalSideEffect" | "external_side_effect" => Ok(EffectClass::ExternalSideEffect),
        "IrreversibleSideEffect" | "irreversible_side_effect" => {
            Ok(EffectClass::IrreversibleSideEffect)
        }
        other => Err(EngineError::PolicyViolation(format!(
            "unsupported capability effectClass {other}"
        ))),
    }
}

fn parse_risk(value: &str) -> Result<RiskLevel> {
    match value.to_ascii_lowercase().as_str() {
        "low" => Ok(RiskLevel::Low),
        "medium" => Ok(RiskLevel::Medium),
        "high" => Ok(RiskLevel::High),
        "critical" => Ok(RiskLevel::Critical),
        other => Err(EngineError::PolicyViolation(format!(
            "unsupported risk {other}"
        ))),
    }
}

fn network_rank(value: &str) -> Result<u8> {
    match value {
        "none" => Ok(0),
        "loopback" => Ok(1),
        "declared" => Ok(2),
        "unrestricted" => Ok(3),
        other => Err(EngineError::PolicyViolation(format!(
            "unsupported network policy {other}"
        ))),
    }
}

fn parse_datetime(value: &str) -> Result<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| EngineError::PolicyViolation(format!("invalid grant expiresAt: {error}")))
}

fn validate_namespace(namespace: &str) -> Result<()> {
    if namespace.trim().is_empty()
        || namespace.contains("::")
        || !namespace
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-'))
    {
        return Err(EngineError::PolicyViolation(format!(
            "invalid package namespace {namespace}"
        )));
    }
    Ok(())
}

fn manifest_digest(manifest: &Value) -> Result<String> {
    let mut canonical = manifest.clone();
    if let Some(object) = canonical.as_object_mut() {
        for field in [
            "packageDigest",
            "sourceRef",
            "sourceDigest",
            "sourceTrustStatus",
            "effectiveTrustTier",
            "signature",
            "signatureKeyRef",
            "signatureVerification",
            "sourceEvidenceRefs",
            "sourceApprovalRefs",
            "conformanceEvidenceRefs",
            "policyDiagnostics",
        ] {
            object.remove(field);
        }
    }
    let bytes = serde_json::to_vec(&canonical).map_err(|error| EngineError::LedgerFailure {
        operation: "module.manifest_digest",
        message: error.to_string(),
    })?;
    Ok(format!("sha256:{:x}", Sha256::digest(bytes)))
}

fn hash_json(value: &Value) -> Result<String> {
    let bytes = serde_json::to_vec(value).map_err(|error| EngineError::LedgerFailure {
        operation: "module.hash_json",
        message: error.to_string(),
    })?;
    Ok(format!("sha256:{:x}", Sha256::digest(bytes)))
}

fn ensure_expected_current_version(
    inspection: &EngineResourceInspection,
    expected: &str,
) -> Result<()> {
    if inspection.resource.current_version_id.as_deref() == Some(expected) {
        Ok(())
    } else {
        Err(EngineError::PolicyViolation(format!(
            "expectedCurrentVersionId {expected} does not match current version {:?}",
            inspection.resource.current_version_id
        )))
    }
}

fn ensure_version_is_current(
    inspection: &EngineResourceInspection,
    version_id: &str,
) -> Result<()> {
    if inspection.resource.current_version_id.as_deref() == Some(version_id) {
        Ok(())
    } else {
        Err(EngineError::PolicyViolation(format!(
            "versionId {version_id} is not current version {:?}",
            inspection.resource.current_version_id
        )))
    }
}

fn append_string_array(existing: Option<&Value>, additions: Vec<String>) -> Value {
    let mut values = existing
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(ToOwned::to_owned)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    for addition in additions {
        if !values.iter().any(|value| value == &addition) {
            values.push(addition);
        }
    }
    json!(values)
}

fn append_value_array(existing: Option<&Value>, addition: Value) -> Value {
    let mut values = existing
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if !values.iter().any(|value| value == &addition) {
        values.push(addition);
    }
    Value::Array(values)
}

fn bounded_json(value: &Value, max_bytes: usize) -> Value {
    let text = value.to_string();
    if text.len() <= max_bytes {
        return value.clone();
    }
    json!({
        "truncated": true,
        "preview": truncate_utf8_bytes(text, max_bytes),
    })
}

fn truncate_utf8_bytes(mut text: String, max_bytes: usize) -> String {
    if text.len() <= max_bytes {
        return text;
    }
    let mut end = max_bytes;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    text.truncate(end);
    text
}

fn reject_raw_secrets(value: &Value) -> Result<()> {
    reject_raw_secrets_at(value, "$", None)
}

fn reject_raw_secrets_at(value: &Value, path: &str, key_hint: Option<&str>) -> Result<()> {
    match value {
        Value::Object(object) => {
            for (key, child) in object {
                reject_raw_secrets_at(child, &format!("{path}.{key}"), Some(key))?;
            }
        }
        Value::Array(items) => {
            for (index, child) in items.iter().enumerate() {
                reject_raw_secrets_at(child, &format!("{path}[{index}]"), key_hint)?;
            }
        }
        Value::String(text) => {
            let key = key_hint.unwrap_or_default().to_ascii_lowercase();
            let normalized_key = key.replace(['-', '_'], "");
            let public_key_identifier = matches!(
                normalized_key.as_str(),
                "publickey" | "signaturekeyref" | "keyid"
            );
            let secret_key = !public_key_identifier
                && [
                    "secret",
                    "token",
                    "password",
                    "apikey",
                    "privatekey",
                    "credential",
                ]
                .iter()
                .any(|marker| normalized_key.contains(marker));
            let secret_value = text.starts_with("sk-")
                || text.starts_with("pk-")
                || text.to_ascii_lowercase().contains("secret=");
            let allowed_ref = text.starts_with("secret_ref:")
                || text.starts_with("vault:")
                || text.starts_with(TRUST_ROOT_PREFIX);
            if (secret_key || secret_value) && !allowed_ref {
                return Err(EngineError::PolicyViolation(format!(
                    "{path} contains secret-like value; store only secret_ref or vault handles"
                )));
            }
        }
        _ => {}
    }
    Ok(())
}

fn collect_secret_refs(value: &Value) -> Vec<String> {
    let mut refs = Vec::new();
    collect_secret_refs_inner(value, &mut refs);
    refs
}

fn collect_secret_refs_inner(value: &Value, refs: &mut Vec<String>) {
    match value {
        Value::String(text) if text.starts_with("secret_ref:") || text.starts_with("vault:") => {
            refs.push(text.clone());
        }
        Value::Array(items) => {
            for item in items {
                collect_secret_refs_inner(item, refs);
            }
        }
        Value::Object(object) => {
            for child in object.values() {
                collect_secret_refs_inner(child, refs);
            }
        }
        _ => {}
    }
}

fn resource_scope_and_token(invocation: &Invocation) -> Result<(EngineResourceScope, String)> {
    match optional_string(invocation.payload.get("scope"))?
        .unwrap_or_else(|| "workspace".to_owned())
        .as_str()
    {
        "system" => Ok((EngineResourceScope::System, "system".to_owned())),
        "workspace" => {
            let workspace_id = optional_string(invocation.payload.get("workspaceId"))?
                .or(invocation.causal_context.workspace_id.clone())
                .ok_or_else(|| {
                    EngineError::PolicyViolation(
                        "workspace-scoped module resource requires workspaceId".to_owned(),
                    )
                })?;
            if workspace_id.trim().is_empty() {
                return Err(EngineError::PolicyViolation(
                    "workspaceId must not be empty".to_owned(),
                ));
            }
            Ok((
                EngineResourceScope::Workspace(workspace_id.clone()),
                workspace_id,
            ))
        }
        "session" => {
            let session_id = optional_string(invocation.payload.get("sessionId"))?
                .or(invocation.causal_context.session_id.clone())
                .ok_or_else(|| {
                    EngineError::PolicyViolation(
                        "session-scoped module resource requires sessionId".to_owned(),
                    )
                })?;
            if session_id.trim().is_empty() {
                return Err(EngineError::PolicyViolation(
                    "sessionId must not be empty".to_owned(),
                ));
            }
            Ok((EngineResourceScope::Session(session_id.clone()), session_id))
        }
        other => Err(EngineError::PolicyViolation(format!(
            "unsupported module resource scope {other}"
        ))),
    }
}

fn next_config_revision(host: &ModulePrimitiveHandler, resource_id: &str) -> Result<u64> {
    Ok(host
        .inspect_resource(resource_id)?
        .and_then(|inspection| current_payload(&inspection))
        .and_then(|payload| payload.get("configRevision").and_then(Value::as_u64))
        .unwrap_or(0)
        .saturating_add(1))
}

fn package_resource_id_from_payload(payload: &Value) -> Result<String> {
    if let Some(resource_id) = optional_string(payload.get("packageResourceId"))? {
        return Ok(resource_id);
    }
    let package_id = required_str(payload, "packageId")?;
    Ok(package_resource_id(package_id))
}

pub(in crate::engine) fn package_resource_id(package_id: &str) -> String {
    format!("worker-package:{package_id}")
}

fn config_resource_id(scope: &str, package_id: &str) -> String {
    format!("module-config:{scope}:{package_id}")
}

fn activation_resource_id(scope: &str, package_id: &str) -> String {
    format!("activation:{scope}:{package_id}")
}

fn require_inspection(
    host: &ModulePrimitiveHandler,
    resource_id: &str,
    expected_kind: &str,
) -> Result<EngineResourceInspection> {
    let inspection = host
        .inspect_resource(resource_id)?
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource",
            id: resource_id.to_owned(),
        })?;
    if inspection.resource.kind != expected_kind {
        return Err(EngineError::PolicyViolation(format!(
            "resource {resource_id} is {}, expected {expected_kind}",
            inspection.resource.kind
        )));
    }
    Ok(inspection)
}

fn current_payload(inspection: &EngineResourceInspection) -> Option<Value> {
    current_version(inspection).map(|version| version.payload.clone())
}

fn current_payload_from_json_inspection(inspection: &Value) -> Option<&Value> {
    let current = inspection
        .get("resource")?
        .get("currentVersionId")?
        .as_str()?;
    inspection
        .get("versions")?
        .as_array()?
        .iter()
        .find(|version| version.get("versionId").and_then(Value::as_str) == Some(current))?
        .get("payload")
}

fn current_version(inspection: &EngineResourceInspection) -> Option<&EngineResourceVersion> {
    let current = inspection.resource.current_version_id.as_ref()?;
    inspection
        .versions
        .iter()
        .find(|version| &version.version_id == current)
}

fn version_payload(inspection: &EngineResourceInspection, version_id: &str) -> Result<Value> {
    inspection
        .versions
        .iter()
        .find(|version| version.version_id == version_id)
        .map(|version| version.payload.clone())
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource_version",
            id: version_id.to_owned(),
        })
}

fn resource_ref_from_resource(resource: &EngineResource, role: &str) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "versionId": resource.current_version_id,
        "role": role,
        "contentHash": Value::Null,
    })
}

fn resource_ref_from_version(version: &EngineResourceVersion, kind: &str, role: &str) -> Value {
    json!({
        "resourceId": version.resource_id,
        "kind": kind,
        "versionId": version.version_id,
        "role": role,
        "contentHash": version.content_hash,
    })
}

fn filter_resources_by_package(
    host: &ModulePrimitiveHandler,
    resources: Vec<EngineResource>,
    package_id: Option<&str>,
) -> Result<Vec<Value>> {
    let Some(package_id) = package_id else {
        return Ok(Vec::new());
    };
    let mut filtered = Vec::new();
    for resource in resources {
        let Some(inspection) = host.inspect_resource(&resource.resource_id)? else {
            continue;
        };
        let Some(payload) = current_payload(&inspection) else {
            continue;
        };
        if payload.get("packageId").and_then(Value::as_str) == Some(package_id)
            || payload
                .get("packageResourceId")
                .and_then(Value::as_str)
                .is_some_and(|id| id == package_resource_id(package_id))
        {
            filtered.push(json!(inspection));
        }
    }
    Ok(filtered)
}

fn trust_decision_metadata<'a>(
    payload: &'a Value,
    expected_type: &str,
) -> Result<&'a serde_json::Map<String, Value>> {
    let metadata = payload
        .get("metadata")
        .and_then(Value::as_object)
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!("{expected_type} decision is missing metadata"))
        })?;
    if metadata.get("decisionType").and_then(Value::as_str) != Some(expected_type) {
        return Err(EngineError::PolicyViolation(format!(
            "expected decisionType {expected_type}"
        )));
    }
    Ok(metadata)
}

fn package_trust_summary(inspection: &EngineResourceInspection) -> Result<Value> {
    let payload = current_payload(inspection).ok_or_else(|| {
        EngineError::PolicyViolation(format!(
            "package {} has no current payload",
            inspection.resource.resource_id
        ))
    })?;
    Ok(json!({
        "packageResourceId": inspection.resource.resource_id,
        "packageVersionId": inspection.resource.current_version_id,
        "packageId": payload.get("packageId").cloned().unwrap_or(Value::Null),
        "packageDigest": payload.get("packageDigest").cloned().unwrap_or(Value::Null),
        "sourceTrustStatus": payload.get("sourceTrustStatus").cloned().unwrap_or(Value::Null),
        "signatureKeyRef": payload.get("signatureKeyRef").cloned().unwrap_or(Value::Null),
    }))
}

fn activation_trust_summary(inspection: &EngineResourceInspection) -> Result<Value> {
    let payload = current_payload(inspection).ok_or_else(|| {
        EngineError::PolicyViolation(format!(
            "activation {} has no current payload",
            inspection.resource.resource_id
        ))
    })?;
    Ok(json!({
        "activationResourceId": inspection.resource.resource_id,
        "activationVersionId": inspection.resource.current_version_id,
        "lifecycle": inspection.resource.lifecycle,
        "packageId": payload.get("packageId").cloned().unwrap_or(Value::Null),
        "packageResourceId": payload.get("packageResourceId").cloned().unwrap_or(Value::Null),
        "activationStatus": payload.get("activationStatus").cloned().unwrap_or(Value::Null),
        "derivedGrantId": payload.get("derivedGrantId").cloned().unwrap_or(Value::Null),
        "workerId": payload.get("workerId").cloned().unwrap_or(Value::Null),
    }))
}

fn decision_summary(inspection: &EngineResourceInspection) -> Result<Value> {
    let payload = current_payload(inspection).ok_or_else(|| {
        EngineError::PolicyViolation(format!(
            "decision {} has no current payload",
            inspection.resource.resource_id
        ))
    })?;
    Ok(json!({
        "resourceId": inspection.resource.resource_id,
        "versionId": inspection.resource.current_version_id,
        "lifecycle": inspection.resource.lifecycle,
        "status": payload.get("status").cloned().unwrap_or(Value::Null),
        "decisionType": payload
            .get("metadata")
            .and_then(|metadata| metadata.get("decisionType"))
            .cloned()
            .unwrap_or(Value::Null),
    }))
}

fn trust_target_status(payload: &Value) -> &'static str {
    match payload.get("status").and_then(Value::as_str) {
        Some("active") | Some("approved") => "active",
        Some("expired") | Some("revoked") => "stale",
        Some("rejected") => "denied",
        _ => "inspectable",
    }
}

fn trust_warnings_for_status(status: &str) -> Vec<Value> {
    if matches!(status, "stale" | "denied") {
        vec![json!({
            "code": "trust_not_current",
            "message": "target trust decision is not active"
        })]
    } else {
        Vec::new()
    }
}

fn module_actions_for_trust_target(target_type: &str, target_resource_id: &str) -> Vec<Value> {
    let mut actions = vec![
        json!({
            "functionId": INSPECT_TRUST_FUNCTION,
            "targetType": target_type,
            "targetField": "targetResourceId",
            "target": target_resource_id,
            "requiredRisk": "low",
            "approvalRequired": false,
        }),
        json!({
            "functionId": SIMULATE_TRUST_CHANGE_FUNCTION,
            "targetType": target_type,
            "targetField": "targetResourceId",
            "target": target_resource_id,
            "requiredRisk": "low",
            "approvalRequired": false,
        }),
        json!({
            "functionId": RECORD_TRUST_REVIEW_FUNCTION,
            "targetType": target_type,
            "targetField": "targetResourceId",
            "target": target_resource_id,
            "requiredRisk": "medium",
            "approvalRequired": false,
        }),
    ];
    if matches!(target_type, "trust_root" | "decision") {
        actions.extend([
            json!({
                "functionId": RENEW_TRUST_ROOT_FUNCTION,
                "targetType": "trust_root",
                "targetField": "trustRootDecisionResourceId",
                "target": target_resource_id,
                "requiredRisk": "high",
                "approvalRequired": true,
            }),
            json!({
                "functionId": ROTATE_SIGNATURE_KEY_FUNCTION,
                "targetType": "trust_root",
                "targetField": "oldTrustRootDecisionResourceId",
                "target": target_resource_id,
                "requiredRisk": "high",
                "approvalRequired": true,
            }),
            json!({
                "functionId": EXPIRE_TRUST_DECISION_FUNCTION,
                "targetType": "decision",
                "targetField": "decisionResourceId",
                "target": target_resource_id,
                "requiredRisk": "high",
                "approvalRequired": true,
            }),
            json!({
                "functionId": ENFORCE_REVOCATION_FUNCTION,
                "targetType": "decision",
                "targetField": "trustDecisionResourceId",
                "target": target_resource_id,
                "requiredRisk": "high",
                "approvalRequired": true,
            }),
        ]);
    }
    actions
}

fn ensure_grant_ceiling_within_ceiling(
    child: &serde_json::Map<String, Value>,
    parent: &serde_json::Map<String, Value>,
    label: &str,
) -> Result<()> {
    ensure_subset(
        &string_array_from(child.get("allowedCapabilities"), "allowedCapabilities")?,
        &string_array_from(parent.get("allowedCapabilities"), "allowedCapabilities")?,
        &format!("{label} capabilities"),
    )?;
    ensure_subset(
        &string_array_from(child.get("allowedNamespaces"), "allowedNamespaces")?,
        &string_array_from(parent.get("allowedNamespaces"), "allowedNamespaces")?,
        &format!("{label} namespaces"),
    )?;
    ensure_subset(
        &string_array_from(
            child.get("allowedAuthorityScopes"),
            "allowedAuthorityScopes",
        )?,
        &string_array_from(
            parent.get("allowedAuthorityScopes"),
            "allowedAuthorityScopes",
        )?,
        &format!("{label} authority scopes"),
    )?;
    ensure_subset(
        &string_array_from(child.get("allowedResourceKinds"), "allowedResourceKinds")?,
        &string_array_from(parent.get("allowedResourceKinds"), "allowedResourceKinds")?,
        &format!("{label} resource kinds"),
    )?;
    ensure_subset(
        &string_array_from(child.get("resourceSelectors"), "resourceSelectors")?,
        &string_array_from(parent.get("resourceSelectors"), "resourceSelectors")?,
        &format!("{label} resource selectors"),
    )?;
    ensure_subset(
        &string_array_from(child.get("fileRoots"), "fileRoots")?,
        &string_array_from(parent.get("fileRoots"), "fileRoots")?,
        &format!("{label} file roots"),
    )?;
    if network_rank(required_map_str(child, "networkPolicy")?)?
        > network_rank(required_map_str(parent, "networkPolicy")?)?
    {
        return Err(EngineError::PolicyViolation(format!(
            "{label} network policy exceeds parent"
        )));
    }
    if parse_risk(required_map_str(child, "maxRisk")?)?
        > parse_risk(required_map_str(parent, "maxRisk")?)?
    {
        return Err(EngineError::PolicyViolation(format!(
            "{label} maxRisk exceeds parent"
        )));
    }
    if child
        .get("canDelegate")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        && !parent
            .get("canDelegate")
            .and_then(Value::as_bool)
            .unwrap_or(false)
    {
        return Err(EngineError::PolicyViolation(format!(
            "{label} delegation exceeds parent"
        )));
    }
    if parent
        .get("approvalRequired")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        && !child
            .get("approvalRequired")
            .and_then(Value::as_bool)
            .unwrap_or(false)
    {
        return Err(EngineError::PolicyViolation(format!(
            "{label} approval policy exceeds parent"
        )));
    }
    Ok(())
}

fn link_if_possible(
    host: &ModulePrimitiveHandler,
    source: &str,
    target: &str,
    relation: &str,
    invocation: &Invocation,
) {
    let _ = host.link_resources(LinkResources {
        source_resource_id: source.to_owned(),
        target_resource_id: target.to_owned(),
        relation: relation.to_owned(),
        metadata: json!({"source": "module"}),
        trace_id: invocation.causal_context.trace_id.clone(),
        invocation_id: Some(invocation.id.clone()),
    });
}

fn module_actions_for_package(package_id: Option<&str>) -> Vec<Value> {
    let target = package_id.map(package_resource_id);
    vec![
        json!({
            "functionId": VERIFY_SOURCE_FUNCTION,
            "targetType": "package",
            "targetField": "packageResourceId",
            "target": target,
            "requiredRisk": "medium",
            "approvalRequired": false,
        }),
        json!({
            "functionId": APPROVE_SOURCE_FUNCTION,
            "targetType": "package",
            "targetField": "packageResourceId",
            "target": target,
            "requiredRisk": "high",
            "approvalRequired": true,
        }),
        json!({
            "functionId": REVOKE_SOURCE_APPROVAL_FUNCTION,
            "targetType": "package",
            "targetField": "decisionResourceId",
            "target": Value::Null,
            "requiredRisk": "high",
            "approvalRequired": true,
        }),
        json!({
            "functionId": POLICY_DECIDE_FUNCTION,
            "targetType": "package",
            "targetField": "packageResourceId",
            "target": target,
            "requiredRisk": "low",
            "approvalRequired": false,
        }),
        json!({
            "functionId": INSPECT_TRUST_FUNCTION,
            "targetType": "package",
            "targetField": "targetResourceId",
            "target": target,
            "requiredRisk": "low",
            "approvalRequired": false,
        }),
        json!({
            "functionId": SIMULATE_TRUST_CHANGE_FUNCTION,
            "targetType": "package",
            "targetField": "targetResourceId",
            "target": target,
            "requiredRisk": "low",
            "approvalRequired": false,
        }),
        json!({
            "functionId": RECORD_TRUST_REVIEW_FUNCTION,
            "targetType": "package",
            "targetField": "targetResourceId",
            "target": target,
            "requiredRisk": "medium",
            "approvalRequired": false,
        }),
        json!({
            "functionId": SCHEDULE_TRUST_AUDIT_FUNCTION,
            "targetType": "package",
            "targetField": "selectors",
            "target": target,
            "requiredRisk": "medium",
            "approvalRequired": false,
        }),
        json!({
            "functionId": RUN_SCHEDULED_TRUST_AUDIT_FUNCTION,
            "targetType": "decision",
            "targetField": "scheduleDecisionResourceId",
            "target": Value::Null,
            "requiredRisk": "medium",
            "approvalRequired": false,
        }),
        json!({
            "functionId": ENFORCE_REVOCATION_FUNCTION,
            "targetType": "decision",
            "targetField": "trustDecisionResourceId",
            "target": Value::Null,
            "requiredRisk": "high",
            "approvalRequired": true,
        }),
        json!({
            "functionId": RUN_CONFORMANCE_FUNCTION,
            "targetType": "package",
            "targetField": "resourceId",
            "target": target,
            "requiredRisk": "medium",
            "approvalRequired": false,
        }),
        json!({
            "functionId": CONFIGURE_FUNCTION,
            "targetType": "package",
            "targetField": "packageResourceId",
            "target": target,
            "requiredRisk": "medium",
            "approvalRequired": false,
        }),
        json!({
            "functionId": ACTIVATE_FUNCTION,
            "targetType": "package",
            "targetField": "packageResourceId",
            "target": target,
            "requiredRisk": "high",
            "approvalRequired": true,
        }),
    ]
}

fn register_package_schema() -> Value {
    json!({
        "type": "object",
        "required": ["manifest"],
        "additionalProperties": false,
        "properties": {
            "manifest": {"type": "object"},
            "expectedCurrentVersionId": {"type": "string"}
        }
    })
}

fn inspect_package_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "packageId": {"type": "string"},
            "packageResourceId": {"type": "string"}
        }
    })
}

fn configure_schema() -> Value {
    json!({
        "type": "object",
        "required": ["packageResourceId", "packageVersionId", "scope", "config"],
        "additionalProperties": false,
        "properties": {
            "packageResourceId": {"type": "string"},
            "packageVersionId": {"type": "string"},
            "scope": {"type": "string"},
            "workspaceId": {"type": "string"},
            "sessionId": {"type": "string"},
            "config": {"type": "object"},
            "expectedCurrentVersionId": {"type": "string"}
        }
    })
}

fn activate_schema() -> Value {
    json!({
        "type": "object",
        "required": [
            "packageResourceId",
            "packageVersionId",
            "moduleConfigResourceId",
            "configVersionId",
            "scope",
            "childGrantRequest"
        ],
        "additionalProperties": false,
        "properties": {
            "packageResourceId": {"type": "string"},
            "packageVersionId": {"type": "string"},
            "moduleConfigResourceId": {"type": "string"},
            "configVersionId": {"type": "string"},
            "scope": {"type": "string"},
            "workspaceId": {"type": "string"},
            "sessionId": {"type": "string"},
            "workerId": {"type": "string"},
            "childGrantRequest": {"type": "object"},
            "lifecyclePolicy": {"type": "object"},
            "healthPolicy": {"type": "object"},
            "rollbackPolicy": {"type": "object"},
            "rollbackTarget": {},
            "expectedCurrentVersionId": {"type": "string"}
        }
    })
}

fn disable_schema() -> Value {
    json!({
        "type": "object",
        "required": ["activationResourceId"],
        "additionalProperties": false,
        "properties": {
            "activationResourceId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"}
        }
    })
}

fn upgrade_schema() -> Value {
    let mut schema = activate_schema();
    if let Some(required) = schema.get_mut("required").and_then(Value::as_array_mut) {
        required.push(json!("activationResourceId"));
    }
    schema["properties"]["activationResourceId"] = json!({"type": "string"});
    schema
}

fn rollback_schema() -> Value {
    json!({
        "type": "object",
        "required": ["activationResourceId", "targetVersionId", "childGrantRequest"],
        "additionalProperties": false,
        "properties": {
            "activationResourceId": {"type": "string"},
            "targetVersionId": {"type": "string"},
            "scope": {"type": "string"},
            "workspaceId": {"type": "string"},
            "sessionId": {"type": "string"},
            "childGrantRequest": {"type": "object"},
            "expectedCurrentVersionId": {"type": "string"}
        }
    })
}

fn quarantine_schema() -> Value {
    json!({
        "type": "object",
        "required": ["resourceId"],
        "additionalProperties": false,
        "properties": {
            "resourceId": {"type": "string"},
            "evidenceResourceIds": {"type": "array", "items": {"type": "string"}},
            "expectedCurrentVersionId": {"type": "string"}
        }
    })
}

fn module_resource_response_schema(kind: &str) -> Value {
    json!({
        "type": "object",
        "required": ["resourceRefs"],
        "additionalProperties": true,
        "properties": {
            "resource": {"type": "object"},
            "version": {"type": "object"},
            "activation": {"type": "object"},
            "resourceRefs": {
                "type": "array",
                "items": {
                    "type": "object",
                    "required": ["resourceId", "kind", "versionId", "role", "contentHash"],
                    "additionalProperties": false,
                    "properties": {
                        "resourceId": {"type": "string"},
                        "kind": {"type": "string"},
                        "versionId": {"type": ["string", "null"]},
                        "role": {"type": "string"},
                        "contentHash": {"type": ["string", "null"]}
                    }
                }
            },
            "expectedKind": {"type": "string", "enum": [kind]}
        }
    })
}
