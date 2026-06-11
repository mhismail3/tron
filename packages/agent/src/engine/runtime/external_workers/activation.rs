//! Activation-resource binding for governed loopback workers.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::*;
use crate::engine::EngineGrantLifecycle;
use crate::engine::authority::grants::grant_policy_hash;
use crate::engine::durability::resources::{
    EngineResourceInspection, EngineResourceVersion, UpdateResource,
};

const WORKER_ACTIVATION_KIND: &str = "worker_activation";

impl EngineExternalWorkerRuntime {
    pub(super) async fn validate_activation_hello(&self, hello: &WorkerHello) -> Result<()> {
        let Some(activation_resource_id) = hello.worker_token.activation_resource_id.as_deref()
        else {
            return Ok(());
        };
        let inspection = self.activation_inspection(activation_resource_id).await?;
        let payload = activation_payload(&inspection)?;
        if matches!(
            inspection.resource.lifecycle.as_str(),
            "expired" | "revoked" | "failed" | "archived"
        ) {
            return Err(EngineError::PolicyViolation(format!(
                "worker activation {activation_resource_id} is {}",
                inspection.resource.lifecycle
            )));
        }
        if payload_str(payload, "workerId")? != hello.worker.id.as_str() {
            return Err(EngineError::PolicyViolation(
                "activation workerId does not match hello worker".to_owned(),
            ));
        }
        if payload_str(payload, "functionId")?.trim().is_empty() {
            return Err(EngineError::PolicyViolation(
                "activation functionId must be present".to_owned(),
            ));
        }
        if payload_str(payload, "governanceFingerprint")?
            != hello
                .worker_token
                .governance_fingerprint
                .as_deref()
                .unwrap_or_default()
        {
            return Err(EngineError::PolicyViolation(
                "activation governance fingerprint does not match worker token".to_owned(),
            ));
        }
        if payload_str(payload, "tokenFingerprint")? != token_fingerprint(&hello.worker_token)? {
            return Err(EngineError::PolicyViolation(
                "activation token fingerprint does not match worker token".to_owned(),
            ));
        }
        if payload_str(payload, "grantId")? != hello.worker_token.authority_grant_id.as_str() {
            return Err(EngineError::PolicyViolation(
                "activation grant id does not match worker token".to_owned(),
            ));
        }
        let expires_at = parse_time(payload_str(payload, "expiresAt")?, "activation expiresAt")?;
        if expires_at <= Utc::now() {
            self.update_activation_status(
                activation_resource_id,
                "expired",
                Some("activation expired before hello"),
                Some(&hello.worker.id),
                &[],
                &[],
            )
            .await?;
            self.orchestration
                .mark_failed_for_activation(
                    activation_resource_id,
                    "expired",
                    Some("activation expired before hello"),
                )
                .await?;
            return Err(EngineError::PolicyViolation(format!(
                "worker activation {activation_resource_id} is expired"
            )));
        }
        let grant = self
            .host
            .inspect_authority_grant(&hello.worker_token.authority_grant_id)
            .await?
            .ok_or_else(|| {
                EngineError::PolicyViolation(format!(
                    "activation grant {} does not exist",
                    hello.worker_token.authority_grant_id
                ))
            })?;
        if grant.lifecycle == EngineGrantLifecycle::Revoked {
            self.update_activation_status(
                activation_resource_id,
                "revoked",
                Some("activation grant revoked"),
                Some(&hello.worker.id),
                &[],
                &[],
            )
            .await?;
            self.orchestration
                .mark_failed_for_activation(
                    activation_resource_id,
                    "revoked",
                    Some("activation grant revoked"),
                )
                .await?;
            return Err(EngineError::PolicyViolation(format!(
                "activation grant {} is revoked",
                grant.grant_id
            )));
        }
        if let Some(expires_at) = grant.expires_at
            && expires_at <= Utc::now()
        {
            self.update_activation_status(
                activation_resource_id,
                "expired",
                Some("activation grant expired"),
                Some(&hello.worker.id),
                &[],
                &[],
            )
            .await?;
            self.orchestration
                .mark_failed_for_activation(
                    activation_resource_id,
                    "expired",
                    Some("activation grant expired"),
                )
                .await?;
            return Err(EngineError::PolicyViolation(format!(
                "activation grant {} is expired",
                grant.grant_id
            )));
        }
        if grant_policy_hash(&grant) != hello.worker_token.authority_grant_hash {
            return Err(EngineError::PolicyViolation(
                "activation grant hash does not match worker token".to_owned(),
            ));
        }
        if hello.registration_mode != WorkerRegistrationMode::Volatile {
            return Err(EngineError::PolicyViolation(
                "activation workers must use volatile registration".to_owned(),
            ));
        }
        if hello.default_visibility == WorkerVisibility::System {
            return Err(EngineError::PolicyViolation(
                "activation workers cannot request system visibility".to_owned(),
            ));
        }
        if hello.worker_token.visibility_ceiling != hello.default_visibility {
            return Err(EngineError::PolicyViolation(
                "activation worker visibility must match token ceiling".to_owned(),
            ));
        }
        if hello.worker.namespace_claims != hello.worker_token.namespace_claims {
            return Err(EngineError::PolicyViolation(
                "activation worker namespace claims must exactly match scoped token".to_owned(),
            ));
        }
        ensure_activation_scope(payload, hello)?;
        Ok(())
    }

    pub(super) async fn validate_activation_function_registration(
        &self,
        connection: &ExternalWorkerConnection,
        definition: &FunctionDefinition,
    ) -> Result<()> {
        let Some(activation_resource_id) =
            connection.worker_token.activation_resource_id.as_deref()
        else {
            return Ok(());
        };
        if !connection.functions.is_empty() {
            return Err(EngineError::PolicyViolation(
                "activation workers may register only the expected function".to_owned(),
            ));
        }
        let inspection = self.activation_inspection(activation_resource_id).await?;
        let payload = activation_payload(&inspection)?;
        if matches!(
            inspection.resource.lifecycle.as_str(),
            "expired" | "revoked" | "failed" | "archived"
        ) {
            return Err(EngineError::PolicyViolation(format!(
                "worker activation {activation_resource_id} is {}",
                inspection.resource.lifecycle
            )));
        }
        if payload_str(payload, "tokenFingerprint")? != token_fingerprint(&connection.worker_token)?
        {
            return Err(EngineError::PolicyViolation(
                "activation token fingerprint does not match connection token".to_owned(),
            ));
        }
        let expected: FunctionDefinition = serde_json::from_value(
            payload
                .get("expectedFunctionDefinition")
                .cloned()
                .ok_or_else(|| {
                    EngineError::PolicyViolation(
                        "activation payload missing expectedFunctionDefinition".to_owned(),
                    )
                })?,
        )
        .map_err(|error| {
            EngineError::PolicyViolation(format!(
                "activation expectedFunctionDefinition is invalid: {error}"
            ))
        })?;
        validate_expected_activation_function(connection, &expected, definition)
    }

    pub(super) fn validate_activation_trigger_registration(
        &self,
        connection: &ExternalWorkerConnection,
    ) -> Result<()> {
        if connection.worker_token.activation_resource_id.is_some() {
            return Err(EngineError::PolicyViolation(
                "activation workers cannot register triggers".to_owned(),
            ));
        }
        Ok(())
    }

    pub(super) async fn mark_activation_connected(
        &self,
        connection: &ExternalWorkerConnection,
    ) -> Result<()> {
        self.mark_connection_activation(connection, "connected", None)
            .await
    }

    pub(super) async fn mark_activation_registered(
        &self,
        connection: &ExternalWorkerConnection,
    ) -> Result<()> {
        self.mark_connection_activation(connection, "registered", None)
            .await
    }

    pub(super) async fn mark_activation_disconnected(
        &self,
        connection: &ExternalWorkerConnection,
        reason: Option<&str>,
    ) -> Result<()> {
        self.mark_connection_activation(connection, "disconnected", reason)
            .await
    }

    async fn mark_connection_activation(
        &self,
        connection: &ExternalWorkerConnection,
        status: &str,
        reason: Option<&str>,
    ) -> Result<()> {
        let Some(activation_resource_id) =
            connection.worker_token.activation_resource_id.as_deref()
        else {
            return Ok(());
        };
        self.update_activation_status(
            activation_resource_id,
            status,
            reason,
            Some(&connection.worker_id),
            &connection.functions.iter().cloned().collect::<Vec<_>>(),
            &connection.triggers.iter().cloned().collect::<Vec<_>>(),
        )
        .await?;
        match status {
            "connected" => {
                self.orchestration
                    .mark_hello_seen(activation_resource_id, reason)
                    .await?;
            }
            "registered" => {
                self.orchestration
                    .mark_ready(activation_resource_id, reason)
                    .await?;
            }
            "disconnected" => {
                self.orchestration
                    .mark_failed_for_activation(activation_resource_id, "unhealthy", reason)
                    .await?;
            }
            _ => {}
        }
        Ok(())
    }

    async fn activation_inspection(&self, resource_id: &str) -> Result<EngineResourceInspection> {
        let inspection = self
            .host
            .inspect_resource(resource_id)
            .await?
            .ok_or_else(|| EngineError::NotFound {
                kind: "worker_activation",
                id: resource_id.to_owned(),
            })?;
        if inspection.resource.kind != WORKER_ACTIVATION_KIND {
            return Err(EngineError::PolicyViolation(format!(
                "activation resource {resource_id} is kind {}",
                inspection.resource.kind
            )));
        }
        Ok(inspection)
    }

    async fn update_activation_status(
        &self,
        resource_id: &str,
        status: &str,
        reason: Option<&str>,
        worker_id: Option<&WorkerId>,
        functions: &[String],
        triggers: &[String],
    ) -> Result<EngineResourceVersion> {
        let inspection = self.activation_inspection(resource_id).await?;
        let mut payload = activation_payload(&inspection)?.clone();
        payload["status"] = Value::String(status.to_owned());
        if payload.get("metadata").and_then(Value::as_object).is_none() {
            payload["metadata"] = json!({});
        }
        payload["metadata"]["lastEvent"] = json!({
            "status": status,
            "reason": reason,
            "workerId": worker_id.map(WorkerId::as_str),
            "functions": functions,
            "triggers": triggers,
            "timestamp": Utc::now().to_rfc3339(),
        });
        self.host
            .update_resource(UpdateResource {
                resource_id: resource_id.to_owned(),
                expected_current_version_id: inspection.resource.current_version_id,
                lifecycle: Some(status.to_owned()),
                payload,
                state: None,
                locations: Vec::new(),
                trace_id: TraceId::generate(),
                invocation_id: None,
            })
            .await
    }
}

fn validate_expected_activation_function(
    connection: &ExternalWorkerConnection,
    expected: &FunctionDefinition,
    actual: &FunctionDefinition,
) -> Result<()> {
    if actual.id != expected.id {
        return Err(EngineError::PolicyViolation(
            "activation function id does not match expected definition".to_owned(),
        ));
    }
    if actual.owner_worker != connection.worker_id || expected.owner_worker != connection.worker_id
    {
        return Err(EngineError::PolicyViolation(
            "activation function owner worker does not match connection".to_owned(),
        ));
    }
    if actual.visibility != expected.visibility
        || actual.visibility != connection.default_visibility.as_visibility_scope()
    {
        return Err(EngineError::PolicyViolation(
            "activation function visibility does not match expected scope".to_owned(),
        ));
    }
    if actual.description != expected.description
        || actual.request_schema != expected.request_schema
        || actual.response_schema != expected.response_schema
        || actual.opaque_response != expected.opaque_response
        || actual.tags != expected.tags
        || actual.effect_class != expected.effect_class
        || actual.risk_level != expected.risk_level
        || actual.idempotency != expected.idempotency
        || actual.resource_lease != expected.resource_lease
        || actual.compensation != expected.compensation
        || actual.output_contract != expected.output_contract
        || actual.required_authority != expected.required_authority
        || actual.allowed_delivery_modes != expected.allowed_delivery_modes
    {
        return Err(EngineError::PolicyViolation(
            "activation function contract does not match expected definition".to_owned(),
        ));
    }
    for key in [
        "contractId",
        "implementationId",
        "pluginId",
        "trustTier",
        "signatureStatus",
        "contextPrimerLevel",
        "runtimeRequirements",
    ] {
        if expected.metadata.get(key) != actual.metadata.get(key) {
            return Err(EngineError::PolicyViolation(format!(
                "activation function metadata {key} does not match expected definition"
            )));
        }
    }
    let plugin_id = actual
        .metadata
        .get("pluginId")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let trust_tier = actual
        .metadata
        .get("trustTier")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let signature_status = actual
        .metadata
        .get("signatureStatus")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if plugin_id != connection.worker_token.plugin_id {
        return Err(EngineError::PolicyViolation(
            "activation function pluginId does not match worker token".to_owned(),
        ));
    }
    if trust_tier != connection.worker_token.trust_tier {
        return Err(EngineError::PolicyViolation(
            "activation function trustTier does not match worker token".to_owned(),
        ));
    }
    if signature_status != connection.worker_token.signature_status {
        return Err(EngineError::PolicyViolation(
            "activation function signatureStatus does not match worker token".to_owned(),
        ));
    }
    Ok(())
}

fn ensure_activation_scope(payload: &Value, hello: &WorkerHello) -> Result<()> {
    let target = payload_str(payload, "targetVisibility")?;
    let scope = payload.get("scope").ok_or_else(|| {
        EngineError::PolicyViolation("activation payload missing scope".to_owned())
    })?;
    match target {
        "session" => {
            let expected_session =
                scope
                    .get("sessionId")
                    .and_then(Value::as_str)
                    .ok_or_else(|| {
                        EngineError::PolicyViolation(
                            "activation session scope missing sessionId".to_owned(),
                        )
                    })?;
            if hello.default_visibility != WorkerVisibility::Session
                || hello.session_id.as_deref() != Some(expected_session)
                || hello.worker_token.session_id.as_deref() != Some(expected_session)
            {
                return Err(EngineError::PolicyViolation(
                    "activation session scope does not match worker hello".to_owned(),
                ));
            }
            let expected_workspace = scope.get("workspaceId").and_then(Value::as_str);
            if expected_workspace.is_some()
                && (hello.workspace_id.as_deref() != expected_workspace
                    || hello.worker_token.workspace_id.as_deref() != expected_workspace)
            {
                return Err(EngineError::PolicyViolation(
                    "activation workspace binding does not match session worker hello".to_owned(),
                ));
            }
        }
        "workspace" => {
            let expected_workspace = scope
                .get("workspaceId")
                .and_then(Value::as_str)
                .ok_or_else(|| {
                    EngineError::PolicyViolation(
                        "activation workspace scope missing workspaceId".to_owned(),
                    )
                })?;
            if hello.default_visibility != WorkerVisibility::Workspace
                || hello.workspace_id.as_deref() != Some(expected_workspace)
                || hello.worker_token.workspace_id.as_deref() != Some(expected_workspace)
            {
                return Err(EngineError::PolicyViolation(
                    "activation workspace scope does not match worker hello".to_owned(),
                ));
            }
        }
        other => {
            return Err(EngineError::PolicyViolation(format!(
                "activation target visibility {other} is not supported"
            )));
        }
    }
    Ok(())
}

fn activation_payload(inspection: &EngineResourceInspection) -> Result<&Value> {
    let current = inspection
        .resource
        .current_version_id
        .as_deref()
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "activation resource {} has no current version",
                inspection.resource.resource_id
            ))
        })?;
    inspection
        .versions
        .iter()
        .find(|version| version.version_id == current)
        .map(|version| &version.payload)
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "activation resource {} current version is missing",
                inspection.resource.resource_id
            ))
        })
}

fn payload_str<'a>(payload: &'a Value, field: &str) -> Result<&'a str> {
    payload.get(field).and_then(Value::as_str).ok_or_else(|| {
        EngineError::PolicyViolation(format!("activation payload field {field} must be a string"))
    })
}

fn parse_time(value: &str, label: &str) -> Result<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| EngineError::PolicyViolation(format!("invalid {label}: {error}")))
}

fn token_fingerprint(token: &ScopedWorkerToken) -> Result<String> {
    let bytes = serde_json::to_vec(token).map_err(|error| {
        EngineError::PolicyViolation(format!("failed to fingerprint worker token: {error}"))
    })?;
    Ok(hex::encode(Sha256::digest(bytes)))
}
