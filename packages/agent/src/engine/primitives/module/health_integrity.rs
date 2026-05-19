//! Module health, integrity, conformance, and recovery entrypoints.
//!
//! Health checks, integrity verification, conformance evidence, and activation
//! recovery are resource-backed module capabilities. This submodule keeps those
//! evidence-producing paths together while `module.rs` remains the public
//! dispatch and package lifecycle surface.

use super::*;

struct HealthOutcome {
    status: &'static str,
    diagnostics: Value,
    child_invocation_ids: Vec<String>,
    checked_at: String,
}
struct IntegrityOutcome {
    status: &'static str,
    findings: Value,
    checked_at: String,
}

impl ModulePrimitiveHandler {
    pub(super) async fn check_health(&self, invocation: &Invocation) -> Result<Value> {
        let resource_id = required_string_owned(&invocation.payload, "activationResourceId")?;
        let activation_version_id =
            required_string_owned(&invocation.payload, "activationVersionId")?;
        let expected_current_version_id =
            required_string_owned(&invocation.payload, "expectedCurrentVersionId")?;
        let mode = required_string_owned(&invocation.payload, "mode")?;
        if !matches!(mode.as_str(), "on_demand" | "scheduled") {
            return Err(EngineError::PolicyViolation(format!(
                "unsupported module health check mode {mode}"
            )));
        }
        let activation = require_inspection(self, &resource_id, ACTIVATION_RECORD_KIND)?;
        let current = current_version(&activation).ok_or_else(|| {
            EngineError::PolicyViolation(format!("activation {resource_id} has no current version"))
        })?;
        ensure_expected_current_version(&activation, &expected_current_version_id)?;
        if current.version_id != activation_version_id {
            return Err(EngineError::PolicyViolation(format!(
                "activationVersionId {activation_version_id} is not current activation version {}",
                current.version_id
            )));
        }
        let mut payload = current.payload.clone();
        let package = require_inspection(
            self,
            required_value_str(&payload, "packageResourceId")?,
            WORKER_PACKAGE_KIND,
        )?;
        let manifest =
            version_payload(&package, required_value_str(&payload, "packageVersionId")?)?;
        let health_policy = payload
            .get("healthPolicy")
            .or_else(|| manifest.get("healthPolicy"))
            .cloned()
            .unwrap_or_else(|| json!({"mode": "catalog_registered"}));
        let outcome = self
            .evaluate_health_policy(invocation, &payload, &manifest, &health_policy)
            .await?;
        let evidence = self.create_evidence_resource(
            invocation,
            &format!(
                "module activation {} health is {}",
                resource_id, outcome.status
            ),
            CHECK_HEALTH_FUNCTION,
            &resource_id,
            json!({
                "mode": mode,
                "healthPolicy": health_policy,
                "status": outcome.status,
                "diagnostics": outcome.diagnostics,
                "childInvocationIds": outcome.child_invocation_ids,
                "checkedAt": outcome.checked_at,
            }),
        )?;
        payload["healthResult"] = json!({
            "status": outcome.status,
            "mode": health_policy.get("mode").and_then(Value::as_str).unwrap_or("catalog_registered"),
            "checkedAt": outcome.checked_at,
            "diagnostics": outcome.diagnostics,
            "childInvocationIds": outcome.child_invocation_ids,
        });
        payload["healthEvidenceRef"] = evidence.reference.clone();
        payload["checkedAt"] = json!(outcome.checked_at);
        payload["healthInvocationIds"] = append_string_array(
            payload.get("healthInvocationIds"),
            std::iter::once(invocation.id.as_str().to_owned())
                .chain(outcome.child_invocation_ids.clone())
                .collect(),
        );
        let version = self.update_resource(UpdateResource {
            resource_id: resource_id.clone(),
            expected_current_version_id: Some(expected_current_version_id),
            lifecycle: Some(activation.resource.lifecycle.clone()),
            payload: payload.clone(),
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })?;
        let activation_ref =
            resource_ref_from_version(&version, ACTIVATION_RECORD_KIND, "health_checked");
        Ok(json!({
            "activation": {"resourceId": resource_id, "payload": payload, "version": version},
            "healthResult": payload["healthResult"],
            "evidence": evidence.resource,
            "resourceRefs": [evidence.reference, activation_ref],
        }))
    }
    pub(super) async fn verify_integrity(&self, invocation: &Invocation) -> Result<Value> {
        let target_type = required_string_owned(&invocation.payload, "targetType")?;
        let resource_id = required_string_owned(&invocation.payload, "resourceId")?;
        let resource_version_id = required_string_owned(&invocation.payload, "resourceVersionId")?;
        let inspection =
            self.inspect_resource(&resource_id)?
                .ok_or_else(|| EngineError::NotFound {
                    kind: "resource",
                    id: resource_id.clone(),
                })?;
        if inspection.resource.kind != target_type {
            return Err(EngineError::PolicyViolation(format!(
                "integrity target {resource_id} is {}, expected {target_type}",
                inspection.resource.kind
            )));
        }
        if let Some(expected) = optional_string(invocation.payload.get("expectedCurrentVersionId"))?
        {
            ensure_expected_current_version(&inspection, &expected)?;
        }
        let target_payload = version_payload(&inspection, &resource_version_id)?;
        let integrity = match target_type.as_str() {
            WORKER_PACKAGE_KIND => self.verify_package_payload(&target_payload),
            MODULE_CONFIG_KIND => self.verify_config_payload(&target_payload),
            ACTIVATION_RECORD_KIND => {
                self.verify_activation_payload(invocation, &target_payload)
                    .await
            }
            other => Err(EngineError::PolicyViolation(format!(
                "module::verify_integrity does not support resource kind {other}"
            ))),
        }?;
        let evidence = self.create_evidence_resource(
            invocation,
            &format!(
                "module integrity for {} is {}",
                resource_id, integrity.status
            ),
            VERIFY_INTEGRITY_FUNCTION,
            &resource_id,
            json!({
                "targetType": target_type,
                "resourceVersionId": resource_version_id,
                "status": integrity.status,
                "findings": integrity.findings,
                "checkedAt": integrity.checked_at,
            }),
        )?;
        let mut refs = vec![evidence.reference.clone()];
        let mut activation_value = Value::Null;
        if inspection.resource.kind == ACTIVATION_RECORD_KIND {
            let expected = required_string_owned(&invocation.payload, "expectedCurrentVersionId")?;
            let mut payload = target_payload.clone();
            payload["integrityDiagnostics"] = json!({
                "status": integrity.status,
                "checkedAt": integrity.checked_at,
                "findings": integrity.findings,
                "evidenceRef": evidence.reference,
            });
            let version = self.update_resource(UpdateResource {
                resource_id: resource_id.clone(),
                expected_current_version_id: Some(expected),
                lifecycle: Some(inspection.resource.lifecycle.clone()),
                payload: payload.clone(),
                state: None,
                locations: Vec::new(),
                trace_id: invocation.causal_context.trace_id.clone(),
                invocation_id: Some(invocation.id.clone()),
            })?;
            refs.push(resource_ref_from_version(
                &version,
                ACTIVATION_RECORD_KIND,
                "integrity_checked",
            ));
            activation_value = json!({
                "resourceId": resource_id,
                "payload": payload,
                "version": version,
            });
        }
        Ok(json!({
            "integrity": {"status": integrity.status, "findings": integrity.findings, "checkedAt": integrity.checked_at},
            "evidence": evidence.resource,
            "activation": activation_value,
            "resourceRefs": refs,
        }))
    }
    pub(super) async fn recover_activation(&self, invocation: &Invocation) -> Result<Value> {
        let reason = required_string_owned(&invocation.payload, "reason")?;
        let activation_invocation_id =
            optional_string(invocation.payload.get("activationInvocationId"))?;
        let activation_resource_id = if let Some(resource_id) =
            optional_string(invocation.payload.get("activationResourceId"))?
        {
            resource_id
        } else if let Some(invocation_id) = &activation_invocation_id {
            match self
                .activation_resource_id_from_invocation(invocation_id)
                .await
            {
                Some(resource_id) => resource_id,
                None => {
                    return self
                        .recover_partial_activation_invocation(invocation, invocation_id, &reason)
                        .await;
                }
            }
        } else {
            return Err(EngineError::PolicyViolation(
                    "module::recover_activation requires activationResourceId or activationInvocationId"
                        .to_owned(),
                ));
        };
        let inspection = require_inspection(self, &activation_resource_id, ACTIVATION_RECORD_KIND)?;
        if let Some(expected) = optional_string(invocation.payload.get("expectedCurrentVersionId"))?
        {
            ensure_expected_current_version(&inspection, &expected)?;
        }
        let current = current_version(&inspection).ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "activation {activation_resource_id} has no current version"
            ))
        })?;
        let mut payload = current.payload.clone();
        let integrity = self.verify_activation_payload(invocation, &payload).await?;
        let activation_status = payload
            .get("activationStatus")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let safe_active = activation_status == "active" && integrity.status == "valid";
        let mut revoked_grant = Value::Null;
        let mut worker_lifecycle = Value::Null;
        let mut cleanup_status = "not_needed".to_owned();
        let mut cleanup_errors = Vec::new();
        let recovery_status = if safe_active {
            "already_safe"
        } else {
            if let Some(grant_id) = payload.get("derivedGrantId").and_then(Value::as_str)
                && let Ok(grant_id) = AuthorityGrantId::new(grant_id.to_owned())
                && self
                    .inspect_grant(&grant_id)?
                    .is_some_and(|grant| grant.lifecycle == EngineGrantLifecycle::Active)
            {
                match self.revoke_grant(&grant_id, invocation.causal_context.trace_id.clone()) {
                    Ok(grant) => {
                        cleanup_status = "revoked_grant".to_owned();
                        revoked_grant = json!(grant);
                    }
                    Err(error) => {
                        cleanup_status = "manual_recovery_required".to_owned();
                        cleanup_errors.push(json!({
                            "operation": "grant_revoke",
                            "grantId": grant_id.as_str(),
                            "message": error.to_string(),
                        }));
                    }
                }
            }
            match self
                .disconnect_activation_worker(invocation, &payload, "module activation recovery")
                .await
            {
                Ok(Some(lifecycle)) => {
                    cleanup_status = if cleanup_status == "manual_recovery_required" {
                        "manual_recovery_required".to_owned()
                    } else {
                        lifecycle
                            .get("status")
                            .and_then(Value::as_str)
                            .unwrap_or("stopped_worker")
                            .to_owned()
                    };
                    worker_lifecycle = lifecycle;
                }
                Ok(None) => {}
                Err(error) => {
                    cleanup_status = "manual_recovery_required".to_owned();
                    cleanup_errors.push(json!({
                        "operation": "worker_stop",
                        "message": error.to_string(),
                    }));
                    worker_lifecycle = json!({
                        "status": "cleanup_failed",
                        "message": error.to_string(),
                    });
                }
            }
            payload["activationStatus"] = json!("quarantined");
            if cleanup_status == "manual_recovery_required" {
                "manual_recovery_required"
            } else {
                "cleaned"
            }
        };
        let evidence = self.create_evidence_resource(
            invocation,
            &format!(
                "module activation {} recovery {}",
                activation_resource_id, recovery_status
            ),
            RECOVER_ACTIVATION_FUNCTION,
            &activation_resource_id,
            json!({
                "reason": reason,
                "status": recovery_status,
                "integrity": {"status": integrity.status, "findings": integrity.findings},
                "cleanupStatus": cleanup_status.clone(),
                "cleanupErrors": cleanup_errors,
                "revokedGrant": revoked_grant.clone(),
                "workerLifecycle": worker_lifecycle.clone(),
            }),
        )?;
        payload["recovery"] = json!({
            "status": recovery_status,
            "cleanupStatus": cleanup_status.clone(),
            "reason": reason,
            "recoveredAt": Utc::now().to_rfc3339(),
            "evidenceRef": evidence.reference.clone(),
            "revokedGrant": revoked_grant.clone(),
            "workerLifecycle": worker_lifecycle.clone(),
        });
        payload["runtimeDiagnostics"] = json!({
            "lastFailureStage": if recovery_status == "already_safe" {
                Value::Null
            } else {
                json!("cleanup")
            },
            "cleanupStatus": cleanup_status,
            "recoveryStatus": recovery_status,
            "latestRecoveryEvidenceRefs": [evidence.reference.clone()],
        });
        let lifecycle = if safe_active {
            inspection.resource.lifecycle.clone()
        } else {
            "quarantined".to_owned()
        };
        let version = self.update_resource(UpdateResource {
            resource_id: activation_resource_id.clone(),
            expected_current_version_id: optional_string(
                invocation.payload.get("expectedCurrentVersionId"),
            )?
            .or_else(|| inspection.resource.current_version_id.clone()),
            lifecycle: Some(lifecycle),
            payload: payload.clone(),
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })?;
        let activation_ref =
            resource_ref_from_version(&version, ACTIVATION_RECORD_KIND, "recovered");
        Ok(json!({
            "activation": {"resourceId": activation_resource_id, "payload": payload, "version": version},
            "recovery": payload["recovery"],
            "evidence": evidence.resource,
            "resourceRefs": [evidence.reference, activation_ref],
        }))
    }
    pub(super) async fn run_conformance(&self, invocation: &Invocation) -> Result<Value> {
        let target_type = required_string_owned(&invocation.payload, "targetType")?;
        let resource_id = required_string_owned(&invocation.payload, "resourceId")?;
        let resource_version_id = required_string_owned(&invocation.payload, "resourceVersionId")?;
        let mode =
            optional_string(invocation.payload.get("mode"))?.unwrap_or_else(|| "static".to_owned());
        if !matches!(mode.as_str(), "static" | "activation" | "cleanup") {
            return Err(EngineError::PolicyViolation(format!(
                "unsupported module conformance mode {mode}"
            )));
        }
        let inspection = require_inspection(self, &resource_id, &target_type)?;
        if let Some(expected) = optional_string(invocation.payload.get("expectedCurrentVersionId"))?
        {
            ensure_expected_current_version(&inspection, &expected)?;
        }
        let target_payload = version_payload(&inspection, &resource_version_id)?;
        let conformance = match target_type.as_str() {
            WORKER_PACKAGE_KIND => self.conformance_for_package(invocation, &target_payload)?,
            MODULE_CONFIG_KIND => self.verify_config_payload(&target_payload)?,
            ACTIVATION_RECORD_KIND => {
                self.verify_activation_payload(invocation, &target_payload)
                    .await?
            }
            other => {
                return Err(EngineError::PolicyViolation(format!(
                    "module::run_conformance does not support resource kind {other}"
                )));
            }
        };
        let evidence = self.create_evidence_resource(
            invocation,
            &format!(
                "module conformance for {resource_id} is {}",
                conformance.status
            ),
            RUN_CONFORMANCE_FUNCTION,
            &resource_id,
            json!({
                "targetType": target_type,
                "resourceVersionId": resource_version_id,
                "mode": mode,
                "status": conformance.status,
                "findings": conformance.findings,
                "checkedAt": conformance.checked_at,
            }),
        )?;
        let mut refs = vec![evidence.reference.clone()];
        let mut updated = Value::Null;
        if matches!(
            target_type.as_str(),
            WORKER_PACKAGE_KIND | ACTIVATION_RECORD_KIND
        ) {
            let expected = optional_string(invocation.payload.get("expectedCurrentVersionId"))?
                .unwrap_or(resource_version_id.clone());
            ensure_expected_current_version(&inspection, &expected)?;
            let mut payload = target_payload.clone();
            if target_type == WORKER_PACKAGE_KIND {
                payload["conformanceEvidenceRefs"] = append_value_array(
                    payload.get("conformanceEvidenceRefs"),
                    evidence.reference.clone(),
                );
                payload["policyDiagnostics"]["conformance"] = json!({
                    "status": conformance.status,
                    "checkedAt": conformance.checked_at,
                    "evidenceRef": evidence.reference,
                });
            } else {
                payload["integrityDiagnostics"] = json!({
                    "status": conformance.status,
                    "checkedAt": conformance.checked_at,
                    "findings": conformance.findings,
                    "evidenceRef": evidence.reference,
                });
            }
            let version = self.update_resource(UpdateResource {
                resource_id: resource_id.clone(),
                expected_current_version_id: Some(expected),
                lifecycle: Some(inspection.resource.lifecycle.clone()),
                payload: payload.clone(),
                state: None,
                locations: Vec::new(),
                trace_id: invocation.causal_context.trace_id.clone(),
                invocation_id: Some(invocation.id.clone()),
            })?;
            refs.push(resource_ref_from_version(
                &version,
                &target_type,
                "conformance_checked",
            ));
            updated = json!({
                "resourceId": resource_id,
                "payload": payload,
                "version": version,
            });
        }
        Ok(json!({
            "conformance": {"status": conformance.status, "findings": conformance.findings, "checkedAt": conformance.checked_at},
            "evidence": evidence.resource,
            "updated": updated,
            "resourceRefs": refs,
        }))
    }
    pub(super) fn file_hash_status(&self, manifest: &Value) -> &'static str {
        let entry = match manifest.get("runtimeEntryPoint").and_then(Value::as_object) {
            Some(entry) if entry.get("kind").and_then(Value::as_str) == Some("local_process") => {
                entry
            }
            _ => return "not_applicable",
        };
        let refs = match resource_version_refs(entry.get("executableRefs"), "executableRefs") {
            Ok(refs) if !refs.is_empty() => refs,
            _ => return "invalid",
        };
        for reference in refs {
            let Ok(inspection) =
                require_inspection(self, &reference.resource_id, "materialized_file")
            else {
                return "invalid";
            };
            let Some(version) = inspection
                .versions
                .iter()
                .find(|version| version.version_id == reference.version_id)
            else {
                return "invalid";
            };
            if reference
                .content_hash
                .as_ref()
                .is_some_and(|expected| expected != &version.content_hash)
            {
                return "invalid";
            }
        }
        "valid"
    }
    async fn evaluate_health_policy(
        &self,
        invocation: &Invocation,
        activation_payload: &Value,
        manifest: &Value,
        policy: &Value,
    ) -> Result<HealthOutcome> {
        let checked_at = Utc::now().to_rfc3339();
        match policy
            .get("mode")
            .and_then(Value::as_str)
            .unwrap_or("catalog_registered")
        {
            "catalog_registered" => {
                let integrity = self
                    .verify_activation_payload(invocation, activation_payload)
                    .await?;
                Ok(HealthOutcome {
                    status: if integrity.status == "valid" {
                        "healthy"
                    } else {
                        "unhealthy"
                    },
                    diagnostics: integrity.findings,
                    child_invocation_ids: Vec::new(),
                    checked_at,
                })
            }
            "invoke_function" => {
                let function_id = FunctionId::new(required_value_str(policy, "functionId")?)?;
                let namespace = required_value_str(manifest, "namespace")?;
                if function_id.namespace() != namespace {
                    return Err(EngineError::PolicyViolation(format!(
                        "health function {function_id} exceeds package namespace {namespace}"
                    )));
                }
                let functions = self
                    .discover_functions(&FunctionQuery {
                        actor: Some(ActorContext {
                            actor_id: invocation.causal_context.actor_id.clone(),
                            actor_kind: ActorKind::System,
                            authority_grant_id: invocation
                                .causal_context
                                .authority_grant_id
                                .clone(),
                            authority_scopes: Vec::new(),
                            session_id: invocation.causal_context.session_id.clone(),
                            workspace_id: invocation.causal_context.workspace_id.clone(),
                        }),
                        include_internal: true,
                        ..FunctionQuery::default()
                    })
                    .await;
                let function = functions
                    .iter()
                    .find(|candidate| candidate.id == function_id)
                    .ok_or_else(|| EngineError::NotFound {
                        kind: "function",
                        id: function_id.to_string(),
                    })?;
                if !matches!(
                    function.effect_class,
                    EffectClass::PureRead | EffectClass::DeterministicCompute
                ) || function.risk_level > RiskLevel::Low
                    || function.required_authority.approval_required
                {
                    return Err(EngineError::PolicyViolation(format!(
                        "health function {function_id} must be read-only, low-risk, and approval-free"
                    )));
                }
                let health_payload = policy.get("payload").cloned().unwrap_or_else(|| json!({}));
                reject_raw_secrets(&health_payload)?;
                let grant_id = AuthorityGrantId::new(
                    required_value_str(activation_payload, "derivedGrantId")?.to_owned(),
                )?;
                let mut context = invocation.causal_context.clone();
                context.authority_grant_id = grant_id;
                context.parent_invocation_id = self
                    .inspect_grant(&context.authority_grant_id)?
                    .and_then(|grant| grant.subject_invocation_id)
                    .or_else(|| Some(invocation.id.clone()));
                context.idempotency_key = Some(format!(
                    "module.health.invoke:{}:{}",
                    required_value_str(activation_payload, "workerId")?,
                    invocation
                        .causal_context
                        .idempotency_key
                        .as_deref()
                        .unwrap_or(invocation.id.as_str())
                ));
                let child = Invocation::new_sync(function_id.clone(), health_payload, context);
                let result = self.stores.engine_host()?.invoke(child).await;
                let child_id = result.invocation_id.as_str().to_owned();
                if let Some(error) = result.error {
                    Ok(HealthOutcome {
                        status: "unhealthy",
                        diagnostics: json!({
                            "mode": "invoke_function",
                            "functionId": function_id.as_str(),
                            "error": error.to_string(),
                        }),
                        child_invocation_ids: vec![child_id],
                        checked_at,
                    })
                } else {
                    if let Some(value) = &result.value {
                        reject_raw_secrets(value)?;
                    }
                    Ok(HealthOutcome {
                        status: "healthy",
                        diagnostics: json!({
                            "mode": "invoke_function",
                            "functionId": function_id.as_str(),
                            "result": bounded_json(result.value.as_ref().unwrap_or(&Value::Null), 2048),
                        }),
                        child_invocation_ids: vec![child_id],
                        checked_at,
                    })
                }
            }
            other => Err(EngineError::PolicyViolation(format!(
                "unsupported module healthPolicy mode {other}"
            ))),
        }
    }
    fn verify_package_payload(&self, manifest: &Value) -> Result<IntegrityOutcome> {
        let mut findings = Vec::new();
        if let Err(error) = validate_manifest(manifest) {
            findings.push(json!({"code": "manifest_invalid", "message": error.to_string()}));
        }
        let file_hash_status = self.file_hash_status(manifest);
        if !matches!(file_hash_status, "valid" | "not_applicable") {
            findings.push(json!({"code": "file_hash_invalid", "status": file_hash_status}));
        }
        Ok(integrity_outcome(findings))
    }
    fn verify_config_payload(&self, config_payload: &Value) -> Result<IntegrityOutcome> {
        let mut findings = Vec::new();
        let package_resource_id = required_value_str(config_payload, "packageResourceId")?;
        let package_version_id = required_value_str(config_payload, "packageVersionId")?;
        match require_inspection(self, package_resource_id, WORKER_PACKAGE_KIND)
            .and_then(|package| version_payload(&package, package_version_id))
        {
            Ok(manifest) => {
                if let Some(config) = config_payload.get("config") {
                    if let Some(schema) = manifest.get("configSchema")
                        && let Err(error) = schema::validate_payload(
                            &FunctionId::new(CONFIGURE_FUNCTION)?,
                            "module_config",
                            schema,
                            config,
                        )
                    {
                        findings.push(
                            json!({"code": "config_schema_invalid", "message": error.to_string()}),
                        );
                    }
                    let computed = hash_json(config)?;
                    if config_payload.get("validationHash").and_then(Value::as_str)
                        != Some(computed.as_str())
                    {
                        findings.push(json!({"code": "config_hash_mismatch"}));
                    }
                    if let Err(error) = reject_raw_secrets(config) {
                        findings.push(json!({"code": "raw_secret", "message": error.to_string()}));
                    }
                }
            }
            Err(error) => {
                findings.push(json!({"code": "package_ref_invalid", "message": error.to_string()}));
            }
        }
        Ok(integrity_outcome(findings))
    }
    async fn verify_activation_payload(
        &self,
        invocation: &Invocation,
        payload: &Value,
    ) -> Result<IntegrityOutcome> {
        let mut findings = Vec::new();
        let package_resource_id = required_value_str(payload, "packageResourceId")?;
        let package_version_id = required_value_str(payload, "packageVersionId")?;
        let manifest = match require_inspection(self, package_resource_id, WORKER_PACKAGE_KIND)
            .and_then(|package| version_payload(&package, package_version_id))
        {
            Ok(manifest) => manifest,
            Err(error) => {
                findings.push(json!({"code": "package_ref_invalid", "message": error.to_string()}));
                Value::Null
            }
        };
        if manifest.is_object() {
            let package_integrity = self.verify_package_payload(&manifest)?;
            extend_findings(&mut findings, &package_integrity.findings);
        }
        let config_resource_id = required_value_str(payload, "moduleConfigResourceId")?;
        let config_version_id = required_value_str(payload, "configVersionId")?;
        match require_inspection(self, config_resource_id, MODULE_CONFIG_KIND)
            .and_then(|config| version_payload(&config, config_version_id))
        {
            Ok(config_payload) => {
                let config_integrity = self.verify_config_payload(&config_payload)?;
                extend_findings(&mut findings, &config_integrity.findings);
            }
            Err(error) => {
                findings.push(json!({"code": "config_ref_invalid", "message": error.to_string()}));
            }
        }
        let grant_id = required_value_str(payload, "derivedGrantId")?;
        match AuthorityGrantId::new(grant_id.to_owned())
            .ok()
            .and_then(|grant_id| self.inspect_grant(&grant_id).ok().flatten())
        {
            Some(grant) if grant.lifecycle == EngineGrantLifecycle::Active => {
                if let Ok(hash) = hash_json(&json!(grant))
                    && payload.get("derivedGrantHash").and_then(Value::as_str)
                        != Some(hash.as_str())
                {
                    findings.push(json!({"code": "grant_hash_mismatch"}));
                }
            }
            Some(_) => findings.push(json!({"code": "grant_revoked"})),
            None => findings.push(json!({"code": "grant_missing"})),
        }
        let worker_id = required_value_str(payload, "workerId")?;
        let worker_result = match WorkerId::new(worker_id.to_owned()) {
            Ok(id) => self.inspect_worker(&id).await.map(|worker| (id, worker)),
            Err(error) => Err(error),
        };
        let worker = match worker_result {
            Ok((id, worker)) => Some((id, worker)),
            Err(error) => {
                findings.push(json!({"code": "worker_missing", "message": error.to_string()}));
                None
            }
        };
        if let Some((worker_id, worker)) = worker
            && manifest.is_object()
        {
            let namespace = required_value_str(&manifest, "namespace")?;
            if !worker
                .namespace_claims
                .iter()
                .any(|claim| claim == namespace)
            {
                findings.push(json!({"code": "worker_namespace_mismatch"}));
            }
            match (
                declared_capabilities(&manifest),
                registered_capabilities_for_worker(self, invocation, &worker_id, namespace).await,
            ) {
                (Ok(declared), Ok(registered)) => {
                    if let Err(error) = validate_registered_capabilities(&declared, &registered) {
                        findings.push(json!({"code": "registered_capability_invalid", "message": error.to_string()}));
                    }
                    if registered
                        .iter()
                        .any(|function| !function.health.is_routable())
                    {
                        findings.push(json!({"code": "registered_capability_unhealthy"}));
                    }
                }
                (Err(error), _) | (_, Err(error)) => {
                    findings.push(json!({"code": "registered_capability_invalid", "message": error.to_string()}));
                }
            }
        }
        Ok(integrity_outcome(findings))
    }
    pub(super) fn verify_materialized_ref(&self, reference: &ResourceVersionRef) -> Result<()> {
        let inspection = require_inspection(self, &reference.resource_id, "materialized_file")?;
        let version = inspection
            .versions
            .iter()
            .find(|version| version.version_id == reference.version_id)
            .ok_or_else(|| EngineError::NotFound {
                kind: "resource_version",
                id: reference.version_id.clone(),
            })?;
        if let Some(expected) = &reference.content_hash
            && &version.content_hash != expected
        {
            return Err(EngineError::PolicyViolation(format!(
                "materialized file {} hash mismatch: expected {expected}, got {}",
                reference.resource_id, version.content_hash
            )));
        }
        Ok(())
    }
    fn conformance_for_package(
        &self,
        invocation: &Invocation,
        manifest: &Value,
    ) -> Result<IntegrityOutcome> {
        let mut findings = Vec::new();
        let package_integrity = self.verify_package_payload(manifest)?;
        extend_findings(&mut findings, &package_integrity.findings);
        if source_kind(manifest)? == LOCAL_DIGEST_PINNED {
            let signed_local = package_has_signature(manifest);
            let expected_status = if signed_local {
                SOURCE_STATUS_SIGNATURE_VERIFIED
            } else {
                SOURCE_STATUS_VERIFIED
            };
            if manifest.get("sourceTrustStatus").and_then(Value::as_str) != Some(expected_status) {
                findings.push(json!({"code": if signed_local { "signature_unverified" } else { "source_unverified" }}));
            }
            if manifest
                .get("sourceEvidenceRefs")
                .and_then(Value::as_array)
                .is_none_or(Vec::is_empty)
            {
                findings.push(json!({"code": "source_evidence_missing"}));
            }
        }
        if let Some(request) = invocation
            .payload
            .get("childGrantRequest")
            .and_then(Value::as_object)
        {
            let worker_id = manifest
                .get("runtimeEntryPoint")
                .and_then(|entry| entry.get("workerId"))
                .and_then(Value::as_str)
                .ok_or_else(|| {
                    EngineError::PolicyViolation(
                        "conformance grant simulation requires runtimeEntryPoint.workerId"
                            .to_owned(),
                    )
                })?;
            if let Err(error) = child_grant_from_payload(
                invocation,
                manifest,
                &WorkerId::new(worker_id.to_owned())?,
                request,
            )
            .and_then(|child| ensure_grant_request_narrows_caller(self, invocation, &child))
            {
                findings
                    .push(json!({"code": "grant_simulation_failed", "message": error.to_string()}));
            }
        }
        Ok(integrity_outcome(findings))
    }
    pub(super) async fn activation_resource_id_from_invocation(
        &self,
        invocation_id: &str,
    ) -> Option<String> {
        self.stores
            .engine_host()
            .ok()?
            .invocation_records()
            .await
            .into_iter()
            .find(|record| record.invocation_id.as_str() == invocation_id)
            .and_then(|record| {
                record
                    .produced_resource_refs
                    .iter()
                    .find(|reference| {
                        reference.get("kind").and_then(Value::as_str)
                            == Some(ACTIVATION_RECORD_KIND)
                    })
                    .and_then(|reference| reference.get("resourceId").and_then(Value::as_str))
                    .map(ToOwned::to_owned)
            })
    }
}

fn integrity_outcome(findings: Vec<Value>) -> IntegrityOutcome {
    IntegrityOutcome {
        status: if findings.is_empty() {
            "valid"
        } else {
            "invalid"
        },
        findings: Value::Array(findings),
        checked_at: Utc::now().to_rfc3339(),
    }
}
fn extend_findings(target: &mut Vec<Value>, findings: &Value) {
    if let Some(items) = findings.as_array() {
        target.extend(items.iter().cloned());
    }
}
pub(super) fn check_health_schema() -> Value {
    json!({
        "type": "object",
        "required": ["activationResourceId", "activationVersionId", "expectedCurrentVersionId", "mode"],
        "additionalProperties": false,
        "properties": {
            "activationResourceId": {"type": "string"},
            "activationVersionId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"},
            "mode": {"type": "string", "enum": ["on_demand", "scheduled"]}
        }
    })
}
pub(super) fn verify_integrity_schema() -> Value {
    json!({
        "type": "object",
        "required": ["targetType", "resourceId", "resourceVersionId"],
        "additionalProperties": false,
        "properties": {
            "targetType": {"type": "string", "enum": ["worker_package", "module_config", "activation_record"]},
            "resourceId": {"type": "string"},
            "resourceVersionId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"}
        }
    })
}
pub(super) fn recover_activation_schema() -> Value {
    json!({
        "type": "object",
        "required": ["reason"],
        "additionalProperties": false,
        "properties": {
            "activationResourceId": {"type": "string"},
            "activationInvocationId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"},
            "reason": {"type": "string"}
        }
    })
}
pub(super) fn run_conformance_schema() -> Value {
    json!({
        "type": "object",
        "required": ["targetType", "resourceId", "resourceVersionId"],
        "additionalProperties": false,
        "properties": {
            "targetType": {"type": "string", "enum": ["worker_package", "module_config", "activation_record"]},
            "resourceId": {"type": "string"},
            "resourceVersionId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"},
            "mode": {"type": "string", "enum": ["static", "activation", "cleanup"]},
            "childGrantRequest": {"type": "object"}
        }
    })
}
