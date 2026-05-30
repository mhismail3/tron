//! Package registration, configuration, inspection, and diagnostics.

use super::*;

impl ModulePrimitiveHandler {
    pub(super) fn register_package(&self, invocation: &Invocation) -> Result<Value> {
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

    pub(super) async fn inspect_package(&self, invocation: &Invocation) -> Result<Value> {
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

    pub(super) fn configure(&self, invocation: &Invocation) -> Result<Value> {
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
}
