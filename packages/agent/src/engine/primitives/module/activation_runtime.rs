//! Activation runtime cleanup and recovery helpers.
//!
//! Module activation owns package policy and lifecycle orchestration, but local
//! process workers are always launched and stopped through canonical
//! `worker::spawn` / `sandbox::stop_spawned_worker` invocations. This submodule
//! keeps the failure-stage cleanup, leaked-authority recovery, and diagnostic
//! projection code in one place so `module.rs` remains the public dispatch and
//! package-lifecycle surface.

use std::path::Path;

use serde_json::{Value, json};

use super::*;

const ACTIVATION_RUNTIME_DIAGNOSTIC: &str = "module_activation_runtime_diagnostic";

impl ModulePrimitiveHandler {
    pub(super) async fn spawn_local_process_worker(
        &self,
        invocation: &Invocation,
        manifest: &Value,
        runtime: &LocalProcessRuntime,
        grant_request: DeriveGrant,
    ) -> Result<SpawnedLocalProcess> {
        let command = self.resolve_materialized_command(&runtime.command_ref, &grant_request)?;
        for executable_ref in &runtime.executable_refs {
            let _ = self.resolve_materialized_command(executable_ref, &grant_request)?;
        }
        let _environment_mode = runtime
            .environment_policy
            .get("mode")
            .and_then(Value::as_str)
            .unwrap_or("empty");
        let mut context = invocation.causal_context.clone();
        context.parent_invocation_id = Some(invocation.id.clone());
        context.idempotency_key = Some(format!(
            "module:{}:{}:{}:spawn",
            required_value_str(manifest, "packageId")?,
            runtime.worker_id,
            invocation
                .causal_context
                .idempotency_key
                .as_deref()
                .unwrap_or(invocation.id.as_str())
        ));
        context.authority_scopes.push("worker.write".to_owned());
        let working_directory = Path::new(&command)
            .parent()
            .map(|path| path.to_string_lossy().into_owned())
            .unwrap_or_else(|| ".".to_owned());
        let mut payload = json!({
            "workerId": runtime.worker_id,
            "grantId": format!("sandbox-worker:{}:{}", runtime.worker_id, invocation.id.as_str()),
            "command": command,
            "args": runtime.args,
            "workingDirectory": working_directory,
            "expectedFunctionIds": runtime.expected_function_ids,
            "allowedAuthorityScopes": grant_request.allowed_authority_scopes,
            "allowedResourceKinds": grant_request.allowed_resource_kinds,
            "resourceSelectors": grant_request.resource_selectors,
            "fileRoots": grant_request.file_roots,
            "networkPolicy": grant_request.network_policy,
            "maxRisk": risk_label(grant_request.max_risk),
            "budget": grant_request.budget,
            "approvalRequired": grant_request.approval_required,
            "visibility": runtime.visibility,
        });
        if let Some(timeout_ms) = runtime.timeout_ms {
            payload["timeoutMs"] = json!(timeout_ms);
        }
        if let Some(session_id) = &invocation.causal_context.session_id {
            payload["sessionId"] = json!(session_id);
        }
        if let Some(workspace_id) = &invocation.causal_context.workspace_id {
            payload["workspaceId"] = json!(workspace_id);
        }
        let child = Invocation::new_sync(FunctionId::new("worker::spawn")?, payload, context);
        let invocation_id = child.id.clone();
        let result = self.stores.engine_host()?.invoke(child).await;
        if let Some(error) = result.error {
            let _ = self.revoke_active_grants_for_invocation(
                &invocation_id,
                invocation.causal_context.trace_id.clone(),
            );
            return Err(error);
        }
        let value = result.value.ok_or_else(|| {
            EngineError::HandlerFailed("worker::spawn returned no result".to_owned())
        })?;
        let worker_id = required_value_str(&value, "workerId")?;
        let grant_id =
            AuthorityGrantId::new(required_value_str(&value, "authorityGrantId")?.to_owned())?;
        let grant = self.inspect_grant(&grant_id)?.ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "worker::spawn returned missing activation grant {grant_id}"
            ))
        })?;
        let worker_id = WorkerId::new(worker_id.to_owned())?;
        let worker = match self.inspect_worker(&worker_id).await {
            Ok(worker) => worker,
            Err(error) => {
                let _ = self.revoke_grant(&grant_id, invocation.causal_context.trace_id.clone());
                return Err(error);
            }
        };
        Ok(SpawnedLocalProcess {
            invocation_id,
            result: value,
            worker,
            grant,
        })
    }

    pub(super) fn resolve_materialized_command(
        &self,
        command_ref: &ResourceVersionRef,
        grant_request: &DeriveGrant,
    ) -> Result<String> {
        let inspection = require_inspection(self, &command_ref.resource_id, "materialized_file")?;
        let version = inspection
            .versions
            .iter()
            .find(|version| version.version_id == command_ref.version_id)
            .ok_or_else(|| EngineError::NotFound {
                kind: "resource_version",
                id: command_ref.version_id.clone(),
            })?;
        if let Some(expected) = &command_ref.content_hash
            && &version.content_hash != expected
        {
            return Err(EngineError::PolicyViolation(format!(
                "materialized executable {} hash mismatch: expected {expected}, got {}",
                command_ref.resource_id, version.content_hash
            )));
        }
        let canonical = version
            .payload
            .get("canonicalPath")
            .and_then(Value::as_str)
            .or_else(|| {
                version
                    .locations
                    .iter()
                    .find(|location| location.kind == "file")
                    .map(|location| location.uri.as_str())
            })
            .ok_or_else(|| {
                EngineError::PolicyViolation(format!(
                    "materialized executable {} has no canonical file location",
                    command_ref.resource_id
                ))
            })?;
        ensure_path_within_grant_roots(canonical, &grant_request.file_roots)?;
        Ok(canonical.to_owned())
    }

    pub(super) async fn disconnect_volatile_worker(
        &self,
        worker_id: &str,
        reason: &str,
    ) -> Result<Option<Value>> {
        let id = WorkerId::new(worker_id.to_owned())?;
        match self.worker_is_volatile(&id).await {
            Some(true) => {
                let worker = self.inspect_worker(&id).await?;
                self.unregister_worker(&id, worker.owner_actor.as_str())
                    .await?;
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

    pub(super) async fn disconnect_activation_worker(
        &self,
        invocation: &Invocation,
        activation_payload: &Value,
        reason: &str,
    ) -> Result<Option<Value>> {
        let Some(worker_id) = activation_payload.get("workerId").and_then(Value::as_str) else {
            return Ok(None);
        };
        if activation_payload
            .get("workerLifecycle")
            .and_then(|lifecycle| lifecycle.get("mode"))
            .and_then(Value::as_str)
            == Some("spawned_local_process")
        {
            return self
                .stop_spawned_worker(invocation, worker_id, reason)
                .await
                .map(Some);
        }
        self.disconnect_volatile_worker(worker_id, reason).await
    }

    pub(super) async fn stop_spawned_worker(
        &self,
        invocation: &Invocation,
        worker_id: &str,
        reason: &str,
    ) -> Result<Value> {
        let mut context = invocation.causal_context.clone();
        context.parent_invocation_id = Some(invocation.id.clone());
        context.idempotency_key = Some(format!(
            "module.worker.stop:{}:{}",
            worker_id,
            invocation
                .causal_context
                .idempotency_key
                .as_deref()
                .unwrap_or(invocation.id.as_str())
        ));
        context.authority_scopes.push("sandbox.write".to_owned());
        let mut payload = json!({
            "workerId": worker_id,
            "reason": reason,
        });
        if let Some(session_id) = &invocation.causal_context.session_id {
            payload["sessionId"] = json!(session_id);
        }
        if let Some(workspace_id) = &invocation.causal_context.workspace_id {
            payload["workspaceId"] = json!(workspace_id);
        }
        let child = Invocation::new_sync(
            FunctionId::new("sandbox::stop_spawned_worker")?,
            payload,
            context,
        );
        let result = self.stores.engine_host()?.invoke(child).await;
        if let Some(error) = result.error {
            return Err(error);
        }
        Ok(json!({
            "workerId": worker_id,
            "status": "stopped_spawned_worker",
            "reason": reason,
            "stopInvocationId": result.invocation_id.as_str(),
            "result": result.value.unwrap_or(Value::Null),
        }))
    }

    pub(super) async fn record_activation_runtime_failure(
        &self,
        invocation: &Invocation,
        target_resource_id: &str,
        stage: &str,
        grant_id: Option<&AuthorityGrantId>,
        worker_id: Option<&str>,
        spawned_local_process: bool,
        error: &EngineError,
    ) -> Value {
        let mut cleanup_errors = Vec::new();
        let mut cleanup_status = "not_needed".to_owned();
        let mut revoked_grant = Value::Null;
        if let Some(grant_id) = grant_id
            && self
                .inspect_grant(grant_id)
                .ok()
                .flatten()
                .is_some_and(|grant| grant.lifecycle == EngineGrantLifecycle::Active)
        {
            match self.revoke_grant(grant_id, invocation.causal_context.trace_id.clone()) {
                Ok(grant) => {
                    cleanup_status = "revoked_grant".to_owned();
                    revoked_grant = json!(grant);
                }
                Err(error) => {
                    cleanup_status = "cleanup_failed".to_owned();
                    cleanup_errors.push(json!({
                        "operation": "grant_revoke",
                        "grantId": grant_id.as_str(),
                        "message": error.to_string(),
                    }));
                }
            }
        }
        let mut worker_lifecycle = Value::Null;
        if let Some(worker_id) = worker_id {
            let result = if spawned_local_process {
                self.stop_spawned_worker(invocation, worker_id, "module activation cleanup")
                    .await
            } else {
                self.disconnect_volatile_worker(worker_id, "module activation cleanup")
                    .await
                    .map(|value| value.unwrap_or(Value::Null))
            };
            match result {
                Ok(lifecycle) => {
                    let status = lifecycle
                        .get("status")
                        .and_then(Value::as_str)
                        .unwrap_or("stopped_worker");
                    cleanup_status = match (cleanup_status.as_str(), status) {
                        ("cleanup_failed", _) => "cleanup_failed".to_owned(),
                        (_, "not_found") => "worker_not_found".to_owned(),
                        _ => "stopped_worker".to_owned(),
                    };
                    worker_lifecycle = lifecycle;
                }
                Err(error) => {
                    cleanup_status = "manual_recovery_required".to_owned();
                    cleanup_errors.push(json!({
                        "operation": "worker_stop",
                        "workerId": worker_id,
                        "message": error.to_string(),
                    }));
                    worker_lifecycle = json!({
                        "workerId": worker_id,
                        "status": "cleanup_failed",
                        "message": error.to_string(),
                    });
                }
            }
        }
        let metadata = json!({
            "evidenceType": ACTIVATION_RUNTIME_DIAGNOSTIC,
            "stage": stage,
            "cleanupStatus": cleanup_status.clone(),
            "error": error.to_string(),
            "revokedGrant": revoked_grant,
            "workerLifecycle": worker_lifecycle,
            "cleanupErrors": cleanup_errors,
        });
        let evidence_ref = match self.create_evidence_resource(
            invocation,
            &format!("module activation runtime failure at {stage}"),
            ACTIVATE_FUNCTION,
            target_resource_id,
            metadata.clone(),
        ) {
            Ok(evidence) => evidence.reference,
            Err(error) => json!({
                "status": "evidence_failed",
                "message": error.to_string(),
            }),
        };
        json!({
            "lastFailureStage": stage,
            "cleanupStatus": cleanup_status.clone(),
            "recoveryStatus": if cleanup_status == "manual_recovery_required" {
                "manual_recovery_required"
            } else {
                "failed_cleaned"
            },
            "evidenceRef": evidence_ref,
            "metadata": metadata,
        })
    }

    pub(super) fn revoke_active_grants_for_invocation(
        &self,
        invocation_id: &InvocationId,
        trace_id: crate::engine::TraceId,
    ) -> Vec<Value> {
        self.list_grants(ListGrants {
            parent_grant_id: None,
            lifecycle: Some(EngineGrantLifecycle::Active),
            limit: 500,
        })
        .unwrap_or_default()
        .into_iter()
        .filter(|grant| {
            grant
                .subject_invocation_id
                .as_ref()
                .is_some_and(|id| id == invocation_id)
                || grant
                    .provenance
                    .get("parentInvocationId")
                    .and_then(Value::as_str)
                    == Some(invocation_id.as_str())
                || grant.provenance.get("invocationId").and_then(Value::as_str)
                    == Some(invocation_id.as_str())
        })
        .filter_map(|grant| {
            self.revoke_grant(&grant.grant_id, trace_id.clone())
                .ok()
                .map(|grant| json!(grant))
        })
        .collect()
    }

    pub(super) fn activation_runtime_projection(
        &self,
        activation_payload: Option<&Value>,
        activation_status: &str,
        worker_id: Option<&str>,
        worker_status: &str,
    ) -> Value {
        let runtime_diagnostics = activation_payload
            .and_then(|payload| payload.get("runtimeDiagnostics"))
            .cloned()
            .unwrap_or_else(|| json!({}));
        let recovery = activation_payload
            .and_then(|payload| payload.get("recovery"))
            .cloned()
            .unwrap_or_else(|| json!({}));
        let latest_recovery_evidence_refs = runtime_diagnostics
            .get("latestRecoveryEvidenceRefs")
            .cloned()
            .or_else(|| {
                recovery
                    .get("evidenceRef")
                    .map(|reference| json!([reference]))
            })
            .unwrap_or_else(|| json!([]));
        let leaked_grant_refs = activation_payload
            .and_then(|payload| payload.get("derivedGrantId"))
            .and_then(Value::as_str)
            .and_then(|grant_id| AuthorityGrantId::new(grant_id.to_owned()).ok())
            .and_then(|grant_id| self.inspect_grant(&grant_id).ok().flatten())
            .filter(|grant| {
                grant.lifecycle == EngineGrantLifecycle::Active && activation_status != "active"
            })
            .map(|grant| {
                json!([{
                    "grantId": grant.grant_id.as_str(),
                    "lifecycle": "active",
                }])
            })
            .unwrap_or_else(|| json!([]));
        let leaked_worker_refs = match (activation_payload, worker_id) {
            (Some(payload), Some(worker_id))
                if payload.get("workerId").is_some()
                    && activation_status != "active"
                    && worker_status == "registered" =>
            {
                json!([{"workerId": worker_id, "status": "registered"}])
            }
            _ => json!([]),
        };
        let recovery_status = runtime_diagnostics
            .get("recoveryStatus")
            .and_then(Value::as_str)
            .or_else(|| recovery.get("status").and_then(Value::as_str))
            .unwrap_or("not_needed");
        let cleanup_status = runtime_diagnostics
            .get("cleanupStatus")
            .and_then(Value::as_str)
            .or_else(|| recovery.get("cleanupStatus").and_then(Value::as_str))
            .unwrap_or("not_needed");
        let recommended_actions = if recovery_status == "manual_recovery_required"
            || leaked_grant_refs
                .as_array()
                .is_some_and(|items| !items.is_empty())
            || leaked_worker_refs
                .as_array()
                .is_some_and(|items| !items.is_empty())
        {
            json!([
                {"targetFunctionId": RECOVER_ACTIVATION_FUNCTION},
                {"targetFunctionId": QUARANTINE_FUNCTION},
                {"targetFunctionId": VERIFY_INTEGRITY_FUNCTION}
            ])
        } else if activation_status == "active" {
            json!([
                {"targetFunctionId": CHECK_HEALTH_FUNCTION},
                {"targetFunctionId": VERIFY_INTEGRITY_FUNCTION}
            ])
        } else {
            json!([])
        };
        json!({
            "lastFailureStage": runtime_diagnostics
                .get("lastFailureStage")
                .cloned()
                .unwrap_or(Value::Null),
            "cleanupStatus": cleanup_status,
            "recoveryStatus": recovery_status,
            "leakedGrantRefs": leaked_grant_refs,
            "leakedWorkerRefs": leaked_worker_refs,
            "latestRecoveryEvidenceRefs": latest_recovery_evidence_refs,
            "recommendedCanonicalActions": recommended_actions,
        })
    }

    pub(super) async fn recover_partial_activation_invocation(
        &self,
        invocation: &Invocation,
        activation_invocation_id: &str,
        reason: &str,
    ) -> Result<Value> {
        let invocation_ids = self
            .activation_invocation_family(activation_invocation_id)
            .await;
        let active_grants = self.list_grants(ListGrants {
            parent_grant_id: None,
            lifecycle: Some(EngineGrantLifecycle::Active),
            limit: 500,
        })?;
        let mut revoked = Vec::new();
        let mut workers = Vec::new();
        for grant in active_grants {
            let matches_invocation = grant.subject_invocation_id.as_ref().is_some_and(|id| {
                invocation_ids
                    .iter()
                    .any(|candidate| candidate == id.as_str())
            }) || grant
                .provenance
                .get("invocationId")
                .and_then(Value::as_str)
                .is_some_and(|id| invocation_ids.iter().any(|candidate| candidate == id))
                || grant
                    .provenance
                    .get("parentInvocationId")
                    .and_then(Value::as_str)
                    .is_some_and(|id| invocation_ids.iter().any(|candidate| candidate == id));
            if !matches_invocation {
                continue;
            }
            let grant_id = grant.grant_id.clone();
            revoked.push(json!(self.revoke_grant(
                &grant_id,
                invocation.causal_context.trace_id.clone(),
            )?));
            if let Some(worker_id) = grant.subject_worker_id {
                if let Some(lifecycle) = self
                    .disconnect_volatile_worker(
                        worker_id.as_str(),
                        "module partial activation recovery",
                    )
                    .await?
                {
                    workers.push(lifecycle);
                }
            }
        }
        let evidence = self.create_evidence_resource(
            invocation,
            &format!("module partial activation invocation {activation_invocation_id} recovered"),
            RECOVER_ACTIVATION_FUNCTION,
            &format!("invocation:{activation_invocation_id}"),
            json!({
                "reason": reason,
                "status": "partial_cleaned",
                "activationInvocationId": activation_invocation_id,
                "revokedGrants": revoked.clone(),
                "workerLifecycle": workers.clone(),
            }),
        )?;
        Ok(json!({
            "activation": Value::Null,
            "recovery": {
                "status": "partial_cleaned",
                "reason": reason,
                "activationInvocationId": activation_invocation_id,
                "revokedGrants": revoked,
                "workerLifecycle": workers,
            },
            "evidence": evidence.resource,
            "resourceRefs": [evidence.reference],
        }))
    }

    pub(super) async fn activation_invocation_family(
        &self,
        activation_invocation_id: &str,
    ) -> Vec<String> {
        let mut ids = vec![activation_invocation_id.to_owned()];
        let Ok(host) = self.stores.engine_host() else {
            return ids;
        };
        let records = host.invocation_records().await;
        let mut changed = true;
        while changed {
            changed = false;
            for record in &records {
                if record
                    .parent_invocation_id
                    .as_ref()
                    .is_some_and(|parent| ids.iter().any(|id| id == parent.as_str()))
                    && !ids.iter().any(|id| id == record.invocation_id.as_str())
                {
                    ids.push(record.invocation_id.as_str().to_owned());
                    changed = true;
                }
            }
        }
        ids
    }
}
