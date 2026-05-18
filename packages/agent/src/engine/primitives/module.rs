//! Module package lifecycle primitive.
//!
//! Modules are resource-backed packages plus canonical capability invocations.
//! This primitive owns package/config/activation resource wrappers and grant
//! derivation for activation; it does not introduce a package table or action
//! multiplexer.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::runtime::PrimitiveRuntimeHost;
use super::{
    MODULE_WORKER_ID, PrimitiveFunctionRegistration, host_dispatched_registration, optional_string,
    primitive_compensation, primitive_function, required_str, required_string_owned,
};
use crate::engine::discovery::{ActorContext, ActorKind, FunctionQuery};
use crate::engine::grants::{DeriveGrant, EngineGrantLifecycle};
use crate::engine::ids::{AuthorityGrantId, FunctionId, WorkerId};
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

pub(crate) const REGISTER_PACKAGE_FUNCTION: &str = "module::register_package";
pub(crate) const INSPECT_PACKAGE_FUNCTION: &str = "module::inspect_package";
pub(crate) const CONFIGURE_FUNCTION: &str = "module::configure";
pub(crate) const ACTIVATE_FUNCTION: &str = "module::activate";
pub(crate) const DISABLE_FUNCTION: &str = "module::disable";
pub(crate) const UPGRADE_FUNCTION: &str = "module::upgrade";
pub(crate) const ROLLBACK_FUNCTION: &str = "module::rollback";
pub(crate) const QUARANTINE_FUNCTION: &str = "module::quarantine";

const MANIFEST_SCHEMA_ID: &str = "tron.module.package_manifest.v1";
const LOCAL_DIGEST_PINNED: &str = "local_digest_pinned";
const BUILTIN_PROVENANCE: &str = "builtin";

pub(super) fn registrations() -> Result<Vec<PrimitiveFunctionRegistration>> {
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
                "required": ["package", "configs", "activations", "availableActions"],
                "additionalProperties": false,
                "properties": {
                    "package": {"type": ["object", "null"]},
                    "configs": {"type": "array"},
                    "activations": {"type": "array"},
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
    ]
    .into_iter()
    .map(host_dispatched_registration)
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

pub(in crate::engine) fn dispatch(
    host: &mut dyn PrimitiveRuntimeHost,
    invocation: &Invocation,
) -> Result<Value> {
    match invocation.function_id.as_str() {
        REGISTER_PACKAGE_FUNCTION => register_package(host, invocation),
        INSPECT_PACKAGE_FUNCTION => inspect_package(host, invocation),
        CONFIGURE_FUNCTION => configure(host, invocation),
        ACTIVATE_FUNCTION => activate(host, invocation),
        DISABLE_FUNCTION => disable(host, invocation),
        UPGRADE_FUNCTION => upgrade(host, invocation),
        ROLLBACK_FUNCTION => rollback(host, invocation),
        QUARANTINE_FUNCTION => quarantine(host, invocation),
        _ => Err(EngineError::NotFound {
            kind: "function",
            id: invocation.function_id.to_string(),
        }),
    }
}

fn register_package(host: &mut dyn PrimitiveRuntimeHost, invocation: &Invocation) -> Result<Value> {
    let manifest = invocation.payload.get("manifest").cloned().ok_or_else(|| {
        EngineError::PolicyViolation("module::register_package requires manifest".to_owned())
    })?;
    validate_manifest(&manifest)?;
    let package_id = required_value_str(&manifest, "packageId")?;
    let resource_id = package_resource_id(package_id);
    let existing = host.inspect_resource(&resource_id)?;
    let resource = if existing.is_some() {
        let expected_current_version_id =
            optional_string(invocation.payload.get("expectedCurrentVersionId"))?.or_else(|| {
                existing
                    .as_ref()
                    .and_then(|item| item.resource.current_version_id.clone())
            });
        let version = host.update_resource(UpdateResource {
            resource_id: resource_id.clone(),
            expected_current_version_id,
            lifecycle: Some("available".to_owned()),
            payload: manifest.clone(),
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })?;
        let inspection = host
            .inspect_resource(&resource_id)?
            .expect("updated resource must exist");
        return Ok(json!({
            "resource": inspection.resource,
            "version": version,
            "package": {"payload": manifest},
            "resourceRefs": [resource_ref_from_version(&version, WORKER_PACKAGE_KIND, "updated")],
        }));
    } else {
        host.create_resource(CreateResource {
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

fn inspect_package(host: &dyn PrimitiveRuntimeHost, invocation: &Invocation) -> Result<Value> {
    let resource_id = package_resource_id_from_payload(&invocation.payload)?;
    let package = host.inspect_resource(&resource_id)?;
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
    let configs = host.list_resources(ListResources {
        kind: Some(MODULE_CONFIG_KIND.to_owned()),
        scope: None,
        lifecycle: None,
        limit: 100,
    })?;
    let activations = host.list_resources(ListResources {
        kind: Some(ACTIVATION_RECORD_KIND.to_owned()),
        scope: None,
        lifecycle: None,
        limit: 100,
    })?;
    let configs = filter_resources_by_package(host, configs, package_id.as_deref())?;
    let activations = filter_resources_by_package(host, activations, package_id.as_deref())?;
    Ok(json!({
        "package": package,
        "configs": configs,
        "activations": activations,
        "availableActions": module_actions_for_package(package_id.as_deref()),
    }))
}

fn configure(host: &mut dyn PrimitiveRuntimeHost, invocation: &Invocation) -> Result<Value> {
    let package_resource_id = required_string_owned(&invocation.payload, "packageResourceId")?;
    let package_version_id = required_string_owned(&invocation.payload, "packageVersionId")?;
    let package = require_inspection(host, &package_resource_id, WORKER_PACKAGE_KIND)?;
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
        "configRevision": next_config_revision(host, &config_resource_id(&scope_token, package_id))?,
        "config": config,
        "redactionPolicy": manifest.get("redactionPolicy").cloned().unwrap_or_else(|| json!({"mode": "redacted"})),
        "secretRefs": collect_secret_refs(invocation.payload.get("config").unwrap_or(&Value::Null)),
        "validationHash": hash_json(invocation.payload.get("config").unwrap_or(&Value::Null))?,
    });
    let resource_id = config_resource_id(&scope_token, package_id);
    let existing = host.inspect_resource(&resource_id)?;
    let (resource, version, role) = upsert_resource(
        host,
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
        host,
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

fn activate(host: &mut dyn PrimitiveRuntimeHost, invocation: &Invocation) -> Result<Value> {
    activate_inner(host, invocation, ActivationMode::Activate)
}

fn upgrade(host: &mut dyn PrimitiveRuntimeHost, invocation: &Invocation) -> Result<Value> {
    activate_inner(host, invocation, ActivationMode::Upgrade)
}

fn rollback(host: &mut dyn PrimitiveRuntimeHost, invocation: &Invocation) -> Result<Value> {
    let activation_resource_id =
        required_string_owned(&invocation.payload, "activationResourceId")?;
    let target_version_id = required_string_owned(&invocation.payload, "targetVersionId")?;
    let activation = require_inspection(host, &activation_resource_id, ACTIVATION_RECORD_KIND)?;
    let target = version_payload(&activation, &target_version_id)?;
    for (field, kind) in [
        ("packageResourceId", WORKER_PACKAGE_KIND),
        ("moduleConfigResourceId", MODULE_CONFIG_KIND),
    ] {
        let id = target.get(field).and_then(Value::as_str).ok_or_else(|| {
            EngineError::PolicyViolation(format!("rollback target missing {field}"))
        })?;
        let _ = require_inspection(host, id, kind)?;
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
    activate_inner(host, &rollback_invocation, ActivationMode::Rollback)
}

fn disable(host: &mut dyn PrimitiveRuntimeHost, invocation: &Invocation) -> Result<Value> {
    let resource_id = required_string_owned(&invocation.payload, "activationResourceId")?;
    let inspection = require_inspection(host, &resource_id, ACTIVATION_RECORD_KIND)?;
    let current = current_version(&inspection).ok_or_else(|| {
        EngineError::PolicyViolation(format!("activation {resource_id} has no current version"))
    })?;
    let mut payload = current.payload.clone();
    let grant_id = required_value_str(&payload, "derivedGrantId")?;
    let revoked_grant = host.revoke_grant(
        &AuthorityGrantId::new(grant_id.to_owned())?,
        invocation.causal_context.trace_id.clone(),
    )?;
    let worker_lifecycle = payload
        .get("workerId")
        .and_then(Value::as_str)
        .map(|worker_id| disconnect_volatile_worker(host, worker_id, "module disabled"))
        .transpose()?
        .flatten();
    payload["activationStatus"] = json!("disabled");
    payload["disabledAt"] = json!(Utc::now().to_rfc3339());
    payload["workerLifecycle"] = worker_lifecycle.clone().unwrap_or(Value::Null);
    payload["compensationState"] = json!({
        "status": "grant_revoked",
        "workerLifecycle": worker_lifecycle,
    });
    let version = host.update_resource(UpdateResource {
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

fn quarantine(host: &mut dyn PrimitiveRuntimeHost, invocation: &Invocation) -> Result<Value> {
    let resource_id = required_string_owned(&invocation.payload, "resourceId")?;
    let inspection = host
        .inspect_resource(&resource_id)?
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
                host.revoke_grant(
                    &AuthorityGrantId::new(grant_id.to_owned())?,
                    invocation.causal_context.trace_id.clone(),
                )
            })
            .transpose()?
    } else {
        None
    };
    let worker_lifecycle = if inspection.resource.kind == ACTIVATION_RECORD_KIND {
        payload
            .get("workerId")
            .and_then(Value::as_str)
            .map(|worker_id| disconnect_volatile_worker(host, worker_id, "module quarantined"))
            .transpose()?
            .flatten()
    } else {
        None
    };
    if let Some(worker_lifecycle) = &worker_lifecycle {
        payload["workerLifecycle"] = worker_lifecycle.clone();
    }
    let version = host.update_resource(UpdateResource {
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

fn activate_inner(
    host: &mut dyn PrimitiveRuntimeHost,
    invocation: &Invocation,
    mode: ActivationMode,
) -> Result<Value> {
    let package_resource_id = required_string_owned(&invocation.payload, "packageResourceId")?;
    let package_version_id = required_string_owned(&invocation.payload, "packageVersionId")?;
    let config_resource_id_value =
        required_string_owned(&invocation.payload, "moduleConfigResourceId")?;
    let config_version_id = required_string_owned(&invocation.payload, "configVersionId")?;
    let package = require_inspection(host, &package_resource_id, WORKER_PACKAGE_KIND)?;
    let config = require_inspection(host, &config_resource_id_value, MODULE_CONFIG_KIND)?;
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
    validate_runtime_entrypoint(&manifest, &worker_id)?;
    let worker = host.inspect_worker(&WorkerId::new(worker_id.clone())?)?;
    if !worker
        .namespace_claims
        .iter()
        .any(|claim| claim == namespace)
    {
        return Err(EngineError::PolicyViolation(format!(
            "worker {worker_id} does not claim package namespace {namespace}"
        )));
    }
    let declared = declared_capabilities(&manifest)?;
    let registered = registered_capabilities_for_worker(host, invocation, &worker.id, namespace)?;
    validate_registered_capabilities(&declared, &registered)?;
    let (scope, scope_token) = resource_scope_and_token(invocation)?;
    let resource_id = activation_resource_id(&scope_token, package_id);
    let upgrade_source =
        upgrade_source(host, invocation, mode, &resource_id, &package_resource_id)?;
    let child_request = child_grant_from_payload(
        invocation,
        &manifest,
        &worker.id,
        required_object(
            invocation.payload.get("childGrantRequest"),
            "childGrantRequest",
        )?,
    )?;
    let grant = host.derive_grant(child_request)?;
    let grant_hash = hash_json(&json!(grant))?;
    let rollback_target = invocation
        .payload
        .get("rollbackTarget")
        .cloned()
        .unwrap_or(Value::Null);
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
        "activationStatus": status,
        "rollbackTarget": rollback_target,
        "supersedes": supersedes,
        "compensationState": {"status": "none"},
        "scope": scope_token,
    });
    let existing = host.inspect_resource(&resource_id)?;
    let lifecycle = match mode {
        ActivationMode::Rollback => "rolled_back",
        _ => "active",
    };
    let cleanup_grant_id = grant.grant_id.clone();
    let upserted = upsert_resource(
        host,
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
            let _ = host.revoke_grant(
                &cleanup_grant_id,
                invocation.causal_context.trace_id.clone(),
            );
            return Err(error);
        }
    };
    let mut replaced_grant = None;
    let mut disconnected_worker = None;
    if let Some(source) = &upgrade_source {
        if source.grant_id != grant.grant_id.as_str() {
            replaced_grant = Some(host.revoke_grant(
                &AuthorityGrantId::new(source.grant_id.clone())?,
                invocation.causal_context.trace_id.clone(),
            )?);
        }
        if source.worker_id != worker.id.as_str() {
            disconnected_worker = disconnect_volatile_worker(
                host,
                &source.worker_id,
                "module upgrade superseded worker",
            )?;
        }
    }
    link_if_possible(
        host,
        &package.resource.resource_id,
        &resource.resource_id,
        "activates",
        invocation,
    );
    link_if_possible(
        host,
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
    let _ = declared_capabilities(manifest)?;
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
    reject_raw_secrets(manifest.get("redactionPolicy").unwrap())?;
    Ok(())
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

fn registered_capabilities_for_worker(
    host: &dyn PrimitiveRuntimeHost,
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

fn validate_runtime_entrypoint(manifest: &Value, worker_id: &str) -> Result<()> {
    let entry = required_object(manifest.get("runtimeEntryPoint"), "runtimeEntryPoint")?;
    let kind = entry.get("kind").and_then(Value::as_str).ok_or_else(|| {
        EngineError::PolicyViolation("runtimeEntryPoint requires kind".to_owned())
    })?;
    if !matches!(kind, "existing_worker" | "builtin") {
        return Err(EngineError::PolicyViolation(format!(
            "runtimeEntryPoint kind {kind} must be activated through canonical worker::spawn before module::activate"
        )));
    }
    if entry
        .get("workerId")
        .and_then(Value::as_str)
        .is_some_and(|declared| declared != worker_id)
    {
        return Err(EngineError::PolicyViolation(format!(
            "activation workerId {worker_id} does not match manifest runtimeEntryPoint"
        )));
    }
    Ok(())
}

fn upgrade_source(
    host: &dyn PrimitiveRuntimeHost,
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

fn disconnect_volatile_worker(
    host: &mut dyn PrimitiveRuntimeHost,
    worker_id: &str,
    reason: &str,
) -> Result<Option<Value>> {
    let id = WorkerId::new(worker_id.to_owned())?;
    match host.worker_is_volatile(&id) {
        Some(true) => {
            let worker = host.inspect_worker(&id)?;
            host.unregister_worker(&id, worker.owner_actor.as_str())?;
            Ok(Some(json!({
                "workerId": id.as_str(),
                "status": "disconnected",
                "reason": reason,
            })))
        }
        Some(false) => Ok(Some(json!({
            "workerId": id.as_str(),
            "status": "grant_revoked_only",
            "reason": "non_volatile_worker",
        }))),
        None => Ok(Some(json!({
            "workerId": id.as_str(),
            "status": "not_found",
        }))),
    }
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
    host: &mut dyn PrimitiveRuntimeHost,
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
        object.remove("packageDigest");
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
            let secret_key = ["secret", "token", "password", "apikey", "api_key", "key"]
                .iter()
                .any(|marker| key.contains(marker));
            let secret_value = text.starts_with("sk-")
                || text.starts_with("pk-")
                || text.to_ascii_lowercase().contains("secret=");
            let allowed_ref = text.starts_with("secret_ref:") || text.starts_with("vault:");
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

fn next_config_revision(host: &dyn PrimitiveRuntimeHost, resource_id: &str) -> Result<u64> {
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
    host: &dyn PrimitiveRuntimeHost,
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
    host: &dyn PrimitiveRuntimeHost,
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

fn link_if_possible(
    host: &mut dyn PrimitiveRuntimeHost,
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
