//! Activation, upgrade, rollback, disable, and quarantine lifecycle operations.

use super::*;

#[derive(Clone, Copy, PartialEq, Eq)]
enum ActivationMode {
    Activate,
    Upgrade,
    Rollback,
}

struct ReplacementSource {
    resource_id: String,
    version_id: String,
    grant_id: String,
    worker_id: String,
    payload: Value,
}

pub(super) struct SpawnedLocalProcess {
    pub(super) invocation_id: InvocationId,
    pub(super) result: Value,
    pub(super) worker: crate::engine::WorkerDefinition,
    pub(super) grant: EngineGrant,
}

impl ModulePrimitiveHandler {
    pub(super) async fn activate(&self, invocation: &Invocation) -> Result<Value> {
        self.activate_inner(invocation, ActivationMode::Activate)
            .await
    }

    pub(super) async fn upgrade(&self, invocation: &Invocation) -> Result<Value> {
        self.activate_inner(invocation, ActivationMode::Upgrade)
            .await
    }

    pub(super) async fn rollback(&self, invocation: &Invocation) -> Result<Value> {
        let activation_resource_id =
            required_string_owned(&invocation.payload, "activationResourceId")?;
        let target_version_id = required_string_owned(&invocation.payload, "targetVersionId")?;
        let expected_current_version_id =
            required_string_owned(&invocation.payload, "expectedCurrentVersionId")?;
        let activation = require_inspection(self, &activation_resource_id, ACTIVATION_RECORD_KIND)?;
        ensure_expected_current_version(&activation, &expected_current_version_id)?;
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

    pub(super) async fn disable(&self, invocation: &Invocation) -> Result<Value> {
        let resource_id = required_string_owned(&invocation.payload, "activationResourceId")?;
        let inspection = require_inspection(self, &resource_id, ACTIVATION_RECORD_KIND)?;
        let current = current_version(&inspection).ok_or_else(|| {
            EngineError::PolicyViolation(format!("activation {resource_id} has no current version"))
        })?;
        if let Some(expected) = optional_string(invocation.payload.get("expectedCurrentVersionId"))?
        {
            ensure_expected_current_version(&inspection, &expected)?;
        }
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

    pub(super) async fn quarantine(&self, invocation: &Invocation) -> Result<Value> {
        let resource_id = required_string_owned(&invocation.payload, "resourceId")?;
        let inspection =
            self.inspect_resource(&resource_id)?
                .ok_or_else(|| EngineError::NotFound {
                    kind: "resource",
                    id: resource_id.clone(),
                })?;
        if let Some(expected) = optional_string(invocation.payload.get("expectedCurrentVersionId"))?
        {
            ensure_expected_current_version(&inspection, &expected)?;
        }
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
        let replacement_source =
            replacement_source(self, invocation, mode, &resource_id, &package_resource_id)?;
        if mode == ActivationMode::Upgrade
            && matches!(&runtime_entrypoint, RuntimeEntryPoint::LocalProcess(_))
            && replacement_source
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
        let mut pre_replaced_grant = None;
        let mut pre_disconnected_worker = None;
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
                    if let Some(source) = &replacement_source
                        && source.worker_id != local_process.worker_id.as_str()
                    {
                        pre_disconnected_worker = self
                            .disconnect_activation_worker(
                                invocation,
                                &source.payload,
                                "module activation superseded worker",
                            )
                            .await?;
                        pre_replaced_grant = Some(self.revoke_grant(
                            &AuthorityGrantId::new(source.grant_id.clone())?,
                            invocation.causal_context.trace_id.clone(),
                        )?);
                    }
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
                            record_activation_runtime_failure_and_mark_replacement(
                                self,
                                invocation,
                                &package_resource_id,
                                "worker_spawn",
                                None,
                                Some(local_process.worker_id.as_str()),
                                true,
                                replacement_source.as_ref(),
                                pre_disconnected_worker.as_ref(),
                                &error,
                            )
                            .await?;
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
            record_activation_runtime_failure_and_mark_replacement(
                self,
                invocation,
                &package_resource_id,
                "post_spawn_validation",
                Some(&grant.grant_id),
                Some(worker.id.as_str()),
                spawned_local_process,
                replacement_source.as_ref(),
                pre_disconnected_worker.as_ref(),
                &error,
            )
            .await?;
            return Err(error);
        }
        let registered =
            registered_capabilities_for_worker(self, invocation, &worker.id, namespace).await?;
        if let Err(error) = validate_registered_capabilities(&declared, &registered) {
            record_activation_runtime_failure_and_mark_replacement(
                self,
                invocation,
                &package_resource_id,
                "post_spawn_validation",
                Some(&grant.grant_id),
                Some(worker.id.as_str()),
                spawned_local_process,
                replacement_source.as_ref(),
                pre_disconnected_worker.as_ref(),
                &error,
            )
            .await?;
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
        let supersedes = replacement_source
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
                record_activation_runtime_failure_and_mark_replacement(
                    self,
                    invocation,
                    &package_resource_id,
                    "activation_record_persist",
                    Some(&cleanup_grant_id),
                    Some(worker.id.as_str()),
                    spawned_local_process,
                    replacement_source.as_ref(),
                    pre_disconnected_worker.as_ref(),
                    &error,
                )
                .await?;
                return Err(error);
            }
        };
        let mut replaced_grant = pre_replaced_grant;
        let mut disconnected_worker = pre_disconnected_worker;
        if let Some(source) = &replacement_source {
            if replaced_grant.is_none() && source.grant_id != grant.grant_id.as_str() {
                replaced_grant = Some(self.revoke_grant(
                    &AuthorityGrantId::new(source.grant_id.clone())?,
                    invocation.causal_context.trace_id.clone(),
                )?);
            }
            if disconnected_worker.is_none() && source.worker_id != worker.id.as_str() {
                disconnected_worker = self
                    .disconnect_activation_worker(
                        invocation,
                        &source.payload,
                        "module activation superseded worker",
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
}

fn replacement_source(
    host: &ModulePrimitiveHandler,
    invocation: &Invocation,
    mode: ActivationMode,
    expected_resource_id: &str,
    package_resource_id: &str,
) -> Result<Option<ReplacementSource>> {
    if !matches!(mode, ActivationMode::Upgrade | ActivationMode::Rollback) {
        return Ok(None);
    }
    let operation = match mode {
        ActivationMode::Upgrade => "module::upgrade",
        ActivationMode::Rollback => "module::rollback",
        ActivationMode::Activate => unreachable!(),
    };
    let resource_id = required_string_owned(&invocation.payload, "activationResourceId")?;
    if resource_id != expected_resource_id {
        return Err(EngineError::PolicyViolation(format!(
            "{operation} activationResourceId {resource_id} does not match package activation {expected_resource_id}"
        )));
    }
    let expected_current_version_id =
        required_string_owned(&invocation.payload, "expectedCurrentVersionId")?;
    let inspection = require_inspection(host, &resource_id, ACTIVATION_RECORD_KIND)?;
    ensure_expected_current_version(&inspection, &expected_current_version_id)?;
    if matches!(
        inspection.resource.lifecycle.as_str(),
        "disabled" | "failed" | "quarantined" | "damaged"
    ) {
        return Err(EngineError::PolicyViolation(format!(
            "{operation} requires an active activation, got {}",
            inspection.resource.lifecycle
        )));
    }
    let current = current_version(&inspection).ok_or_else(|| {
        EngineError::PolicyViolation(format!("activation {resource_id} has no current version"))
    })?;
    let payload = &current.payload;
    if payload.get("packageResourceId").and_then(Value::as_str) != Some(package_resource_id) {
        return Err(EngineError::PolicyViolation(format!(
            "{operation} package does not match activation being replaced"
        )));
    }
    let grant_id = required_value_str(payload, "derivedGrantId")?.to_owned();
    let grant = host
        .inspect_grant(&AuthorityGrantId::new(grant_id.clone())?)?
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "{operation} source grant {grant_id} is not inspectable"
            ))
        })?;
    if grant.lifecycle != EngineGrantLifecycle::Active {
        return Err(EngineError::PolicyViolation(format!(
            "{operation} source grant {grant_id} is not active"
        )));
    }
    let worker_id = required_value_str(payload, "workerId")?.to_owned();
    Ok(Some(ReplacementSource {
        resource_id,
        version_id: current.version_id.clone(),
        grant_id,
        worker_id,
        payload: payload.clone(),
    }))
}

async fn record_activation_runtime_failure_and_mark_replacement(
    host: &ModulePrimitiveHandler,
    invocation: &Invocation,
    target_resource_id: &str,
    stage: &str,
    grant_id: Option<&AuthorityGrantId>,
    worker_id: Option<&str>,
    spawned_local_process: bool,
    replacement_source: Option<&ReplacementSource>,
    disconnected_worker: Option<&Value>,
    error: &EngineError,
) -> Result<()> {
    let diagnostics = host
        .record_activation_runtime_failure(
            invocation,
            target_resource_id,
            stage,
            grant_id,
            worker_id,
            spawned_local_process,
            error,
        )
        .await;
    if let Some(source) = replacement_source
        && disconnected_worker.is_some()
    {
        mark_replacement_source_failed(
            host,
            invocation,
            source,
            stage,
            &diagnostics,
            disconnected_worker,
            error,
        )?;
    }
    Ok(())
}

fn mark_replacement_source_failed(
    host: &ModulePrimitiveHandler,
    invocation: &Invocation,
    source: &ReplacementSource,
    stage: &str,
    diagnostics: &Value,
    disconnected_worker: Option<&Value>,
    error: &EngineError,
) -> Result<()> {
    let evidence_ref = diagnostics
        .get("evidenceRef")
        .cloned()
        .unwrap_or(Value::Null);
    let latest_recovery_evidence_refs = if evidence_ref.is_null() {
        json!([])
    } else {
        json!([evidence_ref.clone()])
    };
    let worker_lifecycle = disconnected_worker.cloned().unwrap_or(Value::Null);
    let mut payload = source.payload.clone();
    payload["activationStatus"] = json!("failed");
    payload["failedAt"] = json!(Utc::now().to_rfc3339());
    payload["workerLifecycle"] = worker_lifecycle.clone();
    payload["compensationState"] = json!({
        "status": "failed_closed",
        "stage": stage,
        "error": error.to_string(),
        "supersededGrantId": source.grant_id,
        "workerLifecycle": worker_lifecycle.clone(),
    });
    payload["runtimeDiagnostics"] = json!({
        "lastFailureStage": stage,
        "cleanupStatus": "failed_closed",
        "recoveryStatus": "failed_closed",
        "latestRecoveryEvidenceRefs": latest_recovery_evidence_refs,
        "replacementFailure": {
            "stage": stage,
            "error": error.to_string(),
            "evidenceRef": evidence_ref,
            "supersededGrantId": source.grant_id,
            "workerLifecycle": worker_lifecycle,
        },
    });
    host.update_resource(UpdateResource {
        resource_id: source.resource_id.clone(),
        expected_current_version_id: Some(source.version_id.clone()),
        lifecycle: Some("failed".to_owned()),
        payload,
        state: None,
        locations: Vec::new(),
        trace_id: invocation.causal_context.trace_id.clone(),
        invocation_id: Some(invocation.id.clone()),
    })?;
    Ok(())
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
