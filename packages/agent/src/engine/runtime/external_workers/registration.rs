//! External-worker registration and worker-owned stream publication.

use super::proxy::ExternalFunctionProxyHandler;
use super::validation::{
    namespace_claims_value, stamp_external_capability_metadata, stream_topic_allowed_by_token,
    validate_external_capability_metadata,
};
use super::*;

impl EngineExternalWorkerRuntime {
    /// Attach an executable transport proxy for a connected worker.
    pub fn attach_invoker(
        &mut self,
        worker_id: WorkerId,
        invoker: Arc<dyn ExternalWorkerInvoker>,
    ) -> Result<()> {
        if !self.connections.contains_key(&worker_id) {
            return Err(EngineError::NotFound {
                kind: "external worker connection",
                id: worker_id.to_string(),
            });
        }
        self.invokers.insert(worker_id, invoker);
        Ok(())
    }

    /// Register a function from a local worker. External functions default to
    /// session visibility unless they are explicitly promoted later.
    pub async fn register_function(
        &mut self,
        message: RegisterFunction,
    ) -> Result<WorkerCatalogChange> {
        let worker_id = message.definition.owner_worker.clone();
        if !self.connections.contains_key(&worker_id) {
            return Err(EngineError::NotFound {
                kind: "external worker connection",
                id: worker_id.to_string(),
            });
        }
        let connection = self.connection_mut(&worker_id)?.clone();
        if connection.health != WorkerHealth::Healthy {
            return Err(EngineError::PolicyViolation(format!(
                "worker {worker_id} is not healthy"
            )));
        }
        let expected_visibility = connection.default_visibility.as_visibility_scope();
        if message.default_visibility != expected_visibility
            || message.definition.visibility != expected_visibility
        {
            return Err(EngineError::PolicyViolation(
                "external worker function visibility must match the worker default visibility"
                    .to_owned(),
            ));
        }
        let id = message.definition.id.to_string();
        let mut definition = message.definition;
        definition.health = match connection.health {
            WorkerHealth::Healthy => FunctionHealth::Healthy,
            WorkerHealth::Unhealthy | WorkerHealth::Disconnected => FunctionHealth::Unhealthy,
        };
        if let Some(session_id) = connection.session_id.clone() {
            definition.provenance.session_id = Some(session_id);
        }
        if let Some(workspace_id) = connection.workspace_id.clone() {
            definition.provenance.workspace_id = Some(workspace_id);
        }
        let worker = self.host.inspect_worker(&worker_id).await?;
        validate_external_capability_metadata(
            &definition,
            &worker.namespace_claims,
            &connection.worker_token,
        )?;
        stamp_external_capability_metadata(&mut definition, &connection.worker_token);
        let handler = self.invokers.get(&worker_id).map(|invoker| {
            Arc::new(ExternalFunctionProxyHandler {
                invoker: invoker.clone(),
            }) as Arc<dyn InProcessFunctionHandler>
        });
        self.host
            .register_function(
                definition,
                handler,
                connection.registration_mode == WorkerRegistrationMode::Volatile,
            )
            .await?;
        self.connection_mut(&worker_id)?
            .functions
            .insert(id.clone());
        let connection = self.connection_mut(&worker_id)?.clone();
        self.publish_lifecycle_event(
            "worker.function_registered",
            &connection,
            None,
            self.host.catalog_revision().await.0,
        )
        .await?;
        Ok(WorkerCatalogChange {
            subject_id: id,
            owner_worker: worker_id,
            kind: "function_registered".to_owned(),
            catalog_revision: self.host.catalog_revision().await.0,
        })
    }

    /// Register a trigger from a local worker.
    pub async fn register_trigger(
        &mut self,
        message: RegisterTrigger,
    ) -> Result<WorkerCatalogChange> {
        let worker_id = message.definition.owner_worker.clone();
        let connection = self.connection_mut(&worker_id)?.clone();
        if connection.health != WorkerHealth::Healthy {
            return Err(EngineError::PolicyViolation(format!(
                "worker {worker_id} is not healthy"
            )));
        }
        validate_worker_trigger(&self.host, &connection, &message.definition).await?;
        let id = message.definition.id.to_string();
        self.host
            .register_trigger(
                message.definition,
                connection.registration_mode == WorkerRegistrationMode::Volatile,
            )
            .await?;
        self.connection_mut(&worker_id)?.triggers.insert(id.clone());
        let connection = self.connection_mut(&worker_id)?.clone();
        self.publish_lifecycle_event(
            "worker.trigger_registered",
            &connection,
            None,
            self.host.catalog_revision().await.0,
        )
        .await?;
        Ok(WorkerCatalogChange {
            subject_id: id,
            owner_worker: worker_id,
            kind: "trigger_registered".to_owned(),
            catalog_revision: self.host.catalog_revision().await.0,
        })
    }

    /// Publish a worker-owned stream event through the engine stream primitive.
    pub async fn publish_stream(
        &mut self,
        message: WorkerStreamPublish,
    ) -> Result<WorkerCatalogChange> {
        let connection = self.connection_mut(&message.worker_id)?.clone();
        if connection.health != WorkerHealth::Healthy {
            return Err(EngineError::PolicyViolation(format!(
                "worker {} is not healthy",
                message.worker_id
            )));
        }
        validate_worker_stream_publish(&connection, &message)?;
        let mut context = CausalContext::new(
            ActorId::new(format!("worker:{}", message.worker_id))?,
            ActorKind::Worker,
            connection.worker_token.authority_grant_id.clone(),
            message.trace_id.clone().unwrap_or_else(TraceId::generate),
        )
        .with_scope("stream.write")
        .with_scope(ENGINE_INTERNAL_INVOKE_SCOPE)
        .with_idempotency_key(message.idempotency_key.clone());
        if let Some(parent) = message.parent_invocation_id.clone() {
            context = context.with_parent_invocation(parent);
        }
        if let Some(session_id) = message.session_id.clone().or(connection.session_id.clone()) {
            context = context.with_session_id(session_id);
        }
        if let Some(workspace_id) = message
            .workspace_id
            .clone()
            .or(connection.workspace_id.clone())
        {
            context = context.with_workspace_id(workspace_id);
        }
        let mut payload = serde_json::json!({
            "topic": message.topic,
            "payload": message.payload,
            "visibility": message.visibility.as_str(),
            "producer": message.worker_id.to_string(),
        });
        if let Some(session_id) = message.session_id {
            payload["sessionId"] = serde_json::Value::String(session_id);
        }
        if let Some(workspace_id) = message.workspace_id {
            payload["workspaceId"] = serde_json::Value::String(workspace_id);
        }
        let result = self
            .host
            .invoke(
                Invocation::new_sync(FunctionId::new("stream::publish")?, payload, context)
                    .with_delivery_mode(DeliveryMode::Sync),
            )
            .await;
        if let Some(error) = result.error {
            return Err(error);
        }
        Ok(WorkerCatalogChange {
            subject_id: message.worker_id.to_string(),
            owner_worker: message.worker_id,
            kind: "stream_published".to_owned(),
            catalog_revision: result.catalog_revision.0,
        })
    }
}

async fn validate_worker_trigger(
    host: &EngineHostHandle,
    connection: &ExternalWorkerConnection,
    trigger: &TriggerDefinition,
) -> Result<()> {
    let expected_visibility = connection.default_visibility.as_visibility_scope();
    if trigger.visibility != expected_visibility {
        return Err(EngineError::PolicyViolation(
            "external worker trigger visibility must match the worker default visibility"
                .to_owned(),
        ));
    }
    if trigger.authority_grant != connection.worker_token.authority_grant_id {
        return Err(EngineError::PolicyViolation(
            "external worker trigger authority grant must match the scoped token".to_owned(),
        ));
    }
    if !namespace_claims_value(
        &connection.worker_token.namespace_claims,
        trigger.id.as_str(),
    ) {
        return Err(EngineError::PolicyViolation(format!(
            "external worker trigger {} must stay within scoped token namespace claims {:?}",
            trigger.id, connection.worker_token.namespace_claims
        )));
    }
    if !namespace_claims_value(
        &connection.worker_token.namespace_claims,
        trigger.target_function.namespace(),
    ) {
        return Err(EngineError::PolicyViolation(format!(
            "external worker trigger target {} must stay within scoped token namespace claims {:?}",
            trigger.target_function, connection.worker_token.namespace_claims
        )));
    }
    let admin_actor = ActorContext::new(
        ActorId::new("worker-runtime")?,
        ActorKind::System,
        AuthorityGrantId::new("worker-runtime")?,
    );
    let target = host
        .inspect_function(&trigger.target_function, Some(&admin_actor))
        .await?;
    if target.owner_worker != connection.worker_id {
        return Err(EngineError::PolicyViolation(format!(
            "external worker trigger {} cannot target function {} owned by {}",
            trigger.id, trigger.target_function, target.owner_worker
        )));
    }
    Ok(())
}

fn validate_worker_stream_publish(
    connection: &ExternalWorkerConnection,
    message: &WorkerStreamPublish,
) -> Result<()> {
    let expected_visibility = connection.default_visibility.as_visibility_scope();
    if message.visibility != expected_visibility {
        return Err(EngineError::PolicyViolation(
            "external worker stream visibility must match the worker default visibility".to_owned(),
        ));
    }
    if !stream_topic_allowed_by_token(&connection.worker_token, &message.topic) {
        return Err(EngineError::PolicyViolation(format!(
            "external worker stream topic {} is not allowed by scoped token selectors {:?}",
            message.topic, connection.worker_token.resource_selectors
        )));
    }
    match connection.default_visibility {
        WorkerVisibility::Session => {
            let expected = connection.session_id.as_deref().ok_or_else(|| {
                EngineError::PolicyViolation(
                    "session-visible worker stream requires connection sessionId".to_owned(),
                )
            })?;
            if message.session_id.as_deref() != Some(expected) {
                return Err(EngineError::PolicyViolation(
                    "external worker stream sessionId must match the scoped worker session"
                        .to_owned(),
                ));
            }
            if message.workspace_id.is_some()
                && message.workspace_id.as_deref() != connection.workspace_id.as_deref()
            {
                return Err(EngineError::PolicyViolation(
                    "external worker stream workspaceId must match the scoped worker workspace"
                        .to_owned(),
                ));
            }
        }
        WorkerVisibility::Workspace => {
            let expected = connection.workspace_id.as_deref().ok_or_else(|| {
                EngineError::PolicyViolation(
                    "workspace-visible worker stream requires connection workspaceId".to_owned(),
                )
            })?;
            if message.workspace_id.as_deref() != Some(expected) {
                return Err(EngineError::PolicyViolation(
                    "external worker stream workspaceId must match the scoped worker workspace"
                        .to_owned(),
                ));
            }
            if message.session_id.is_some()
                && message.session_id.as_deref() != connection.session_id.as_deref()
            {
                return Err(EngineError::PolicyViolation(
                    "external worker stream sessionId must match the scoped worker session"
                        .to_owned(),
                ));
            }
        }
        WorkerVisibility::System => {
            if message.session_id.is_some() || message.workspace_id.is_some() {
                return Err(EngineError::PolicyViolation(
                    "system-visible worker streams must not claim session or workspace scope"
                        .to_owned(),
                ));
            }
        }
    }
    Ok(())
}
