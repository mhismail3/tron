//! Local external-worker runtime.
//!
//! This is deliberately loopback-only and protocol-bound. Local workers register
//! scoped functions/triggers, receive catalog snapshots, publish stream events
//! through the engine stream primitive, and are cleaned up by heartbeat and
//! disconnect policy. Volatile registrations disappear on disconnect or missed
//! heartbeat. Durable local registrations stay in the catalog but are marked
//! unhealthy until the worker reconnects and re-registers, so agents never
//! discover stale capabilities as runnable.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde_json::Value;

use crate::engine::catalog::discovery::{ActorContext, ActorKind, FunctionQuery};
use crate::engine::invocation::host::EngineHostHandle;
use crate::engine::invocation::model::{CausalContext, InProcessFunctionHandler, Invocation};
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::{
    ActorId, AuthorityGrantId, FunctionId, InvocationId, TraceId, WorkerId,
};
use crate::engine::kernel::policy::ENGINE_INTERNAL_INVOKE_SCOPE;
use crate::engine::kernel::types::{
    DeliveryMode, FunctionDefinition, FunctionHealth, VisibilityScope, WorkerLifecycleState,
};
use crate::engine::runtime::worker_protocol::{
    CatalogSnapshot, RegisterFunction, RegisterTrigger, ScopedWorkerToken, WORKER_PROTOCOL_VERSION,
    WorkerCatalogChange, WorkerDisconnect, WorkerHealth, WorkerHeartbeat, WorkerHello,
    WorkerInvocationResult, WorkerInvoke, WorkerLifecycleEvent, WorkerProtocolMessage,
    WorkerRegistrationMode, WorkerStreamPublish, WorkerVisibility,
};

const WORKER_LIFECYCLE_TOPIC: &str = "worker.lifecycle";

/// Transport client used to invoke a connected local external worker.
#[async_trait]
pub trait ExternalWorkerInvoker: Send + Sync {
    /// Send one invocation to the worker and wait for its result.
    async fn invoke(&self, invoke: WorkerInvoke) -> Result<WorkerInvocationResult>;
}

/// Runtime state for one connected local external worker.
#[derive(Clone, Debug, PartialEq)]
pub struct ExternalWorkerConnection {
    /// Worker id.
    pub worker_id: WorkerId,
    /// Owner actor allowed to unregister the worker.
    pub owner_actor: ActorId,
    /// Last heartbeat sequence.
    pub heartbeat_sequence: u64,
    /// Last accepted heartbeat/hello timestamp.
    pub last_heartbeat_at: DateTime<Utc>,
    /// Protocol is loopback/local only.
    pub loopback_only: bool,
    /// Registration durability.
    pub registration_mode: WorkerRegistrationMode,
    /// Default visibility for registered entries.
    pub default_visibility: WorkerVisibility,
    /// Optional session scope.
    pub session_id: Option<String>,
    /// Optional workspace scope.
    pub workspace_id: Option<String>,
    /// Scoped token policy accepted at hello time.
    pub worker_token: ScopedWorkerToken,
    /// Current runtime health.
    pub health: WorkerHealth,
    /// Registered function ids.
    pub functions: BTreeSet<String>,
    /// Registered trigger ids.
    pub triggers: BTreeSet<String>,
}

/// In-process local external-worker runtime.
pub struct EngineExternalWorkerRuntime {
    host: EngineHostHandle,
    connections: BTreeMap<WorkerId, ExternalWorkerConnection>,
    invokers: BTreeMap<WorkerId, Arc<dyn ExternalWorkerInvoker>>,
}

impl EngineExternalWorkerRuntime {
    /// Create a runtime over an engine host.
    #[must_use]
    pub fn new(host: EngineHostHandle) -> Self {
        Self {
            host,
            connections: BTreeMap::new(),
            invokers: BTreeMap::new(),
        }
    }

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

    /// Accept a worker hello and return a catalog snapshot visible to the
    /// worker. Non-loopback workers are rejected until the remote-worker
    /// identity and authorization model is complete.
    pub async fn hello(&mut self, hello: WorkerHello) -> Result<CatalogSnapshot> {
        if hello.protocol_version != WORKER_PROTOCOL_VERSION {
            return Err(EngineError::PolicyViolation(format!(
                "unsupported worker protocol version {}",
                hello.protocol_version
            )));
        }
        if !hello.loopback_only {
            return Err(EngineError::PolicyViolation(
                "external workers are loopback-only in this package".to_owned(),
            ));
        }
        let worker_id = hello.worker.id.clone();
        if hello.identity.worker_id != worker_id {
            return Err(EngineError::PolicyViolation(format!(
                "worker identity {} does not match definition {}",
                hello.identity.worker_id, worker_id
            )));
        }
        if hello.registration_mode == WorkerRegistrationMode::Durable && !hello.loopback_only {
            return Err(EngineError::PolicyViolation(
                "durable workers must be authenticated local workers".to_owned(),
            ));
        }
        if hello.default_visibility == WorkerVisibility::Workspace && hello.workspace_id.is_none() {
            return Err(EngineError::PolicyViolation(
                "workspace-visible workers require workspaceId".to_owned(),
            ));
        }
        validate_worker_token(&hello)?;
        let owner_actor = hello.worker.owner_actor.clone();
        let volatile = hello.registration_mode == WorkerRegistrationMode::Volatile;
        self.host.register_worker(hello.worker, volatile).await?;
        self.connections.insert(
            worker_id.clone(),
            ExternalWorkerConnection {
                worker_id: worker_id.clone(),
                owner_actor,
                heartbeat_sequence: 0,
                last_heartbeat_at: Utc::now(),
                loopback_only: true,
                registration_mode: hello.registration_mode,
                default_visibility: hello.default_visibility,
                session_id: hello.session_id,
                workspace_id: hello.workspace_id,
                worker_token: hello.worker_token,
                health: WorkerHealth::Healthy,
                functions: BTreeSet::new(),
                triggers: BTreeSet::new(),
            },
        );
        let snapshot = self.catalog_snapshot_for(&worker_id).await;
        let connection = self.connection_mut(&worker_id)?.clone();
        self.publish_lifecycle_event(
            "worker.connected",
            &connection,
            None,
            self.host.catalog_revision().await.0,
        )
        .await?;
        Ok(snapshot)
    }

    /// Handle a protocol message.
    pub async fn handle_message(
        &mut self,
        message: WorkerProtocolMessage,
    ) -> Result<Option<WorkerProtocolMessage>> {
        match message {
            WorkerProtocolMessage::Hello(hello) => {
                let snapshot = self.hello(*hello).await?;
                Ok(Some(WorkerProtocolMessage::CatalogSnapshot(snapshot)))
            }
            WorkerProtocolMessage::RegisterFunction(message) => {
                let change = self.register_function(*message).await?;
                Ok(Some(WorkerProtocolMessage::CatalogChange(change)))
            }
            WorkerProtocolMessage::RegisterTrigger(message) => {
                let change = self.register_trigger(message).await?;
                Ok(Some(WorkerProtocolMessage::CatalogChange(change)))
            }
            WorkerProtocolMessage::PublishStream(message) => {
                let change = self.publish_stream(message).await?;
                Ok(Some(WorkerProtocolMessage::CatalogChange(change)))
            }
            WorkerProtocolMessage::Heartbeat(message) => {
                self.heartbeat(message)?;
                Ok(None)
            }
            WorkerProtocolMessage::Disconnect(message) => {
                self.disconnect(message).await?;
                Ok(None)
            }
            WorkerProtocolMessage::Result(_)
            | WorkerProtocolMessage::Invoke(_)
            | WorkerProtocolMessage::CatalogSnapshot(_)
            | WorkerProtocolMessage::CatalogChange(_) => Ok(None),
        }
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

    /// Record worker heartbeat.
    pub fn heartbeat(&mut self, heartbeat: WorkerHeartbeat) -> Result<()> {
        let connection = self.connection_mut(&heartbeat.worker_id)?;
        if connection.health == WorkerHealth::Disconnected {
            return Err(EngineError::PolicyViolation(format!(
                "worker {} is disconnected",
                heartbeat.worker_id
            )));
        }
        if heartbeat.sequence <= connection.heartbeat_sequence {
            return Err(EngineError::PolicyViolation(format!(
                "stale heartbeat {} for worker {}",
                heartbeat.sequence, heartbeat.worker_id
            )));
        }
        connection.heartbeat_sequence = heartbeat.sequence;
        connection.last_heartbeat_at = Utc::now();
        Ok(())
    }

    /// Disconnect workers whose heartbeat timestamp is older than `timeout`.
    pub async fn disconnect_timed_out(&mut self, timeout: Duration) -> Result<Vec<WorkerId>> {
        let now = Utc::now();
        let expired = self
            .connections
            .values()
            .filter(|connection| {
                let age = now
                    .signed_duration_since(connection.last_heartbeat_at)
                    .to_std()
                    .unwrap_or(Duration::ZERO);
                age > timeout
            })
            .map(|connection| connection.worker_id.clone())
            .collect::<Vec<_>>();
        for worker_id in &expired {
            self.disconnect(WorkerDisconnect {
                worker_id: worker_id.clone(),
                reason: "heartbeat timeout".to_owned(),
            })
            .await?;
        }
        Ok(expired)
    }

    /// Disconnect a worker and unregister its volatile registrations.
    pub async fn disconnect(&mut self, disconnect: WorkerDisconnect) -> Result<()> {
        let Some(connection) = self.connections.remove(&disconnect.worker_id) else {
            return Ok(());
        };
        self.invokers.remove(&disconnect.worker_id);
        if connection.registration_mode == WorkerRegistrationMode::Volatile {
            self.host
                .unregister_worker(&connection.worker_id, connection.owner_actor.as_str())
                .await?;
            let event_type = if disconnect.reason == "heartbeat timeout" {
                "worker.heartbeat_timeout"
            } else {
                "worker.disconnected"
            };
            self.publish_lifecycle_event(
                event_type,
                &connection,
                Some(disconnect.reason.as_str()),
                self.host.catalog_revision().await.0,
            )
            .await?;
            self.publish_lifecycle_event(
                "worker.unregistered",
                &connection,
                Some(disconnect.reason.as_str()),
                self.host.catalog_revision().await.0,
            )
            .await?;
        } else {
            self.mark_durable_worker_disconnected(&connection).await?;
            self.publish_lifecycle_event(
                "worker.disconnected",
                &connection,
                Some(disconnect.reason.as_str()),
                self.host.catalog_revision().await.0,
            )
            .await?;
            let mut health_changed = connection.clone();
            health_changed.health = WorkerHealth::Disconnected;
            self.publish_lifecycle_event(
                "worker.health_changed",
                &health_changed,
                Some(disconnect.reason.as_str()),
                self.host.catalog_revision().await.0,
            )
            .await?;
        }
        Ok(())
    }

    /// Convert a worker result message to an invocation result envelope.
    #[must_use]
    pub fn invocation_result_from_worker(
        invocation_id: InvocationId,
        result: WorkerInvocationResult,
    ) -> Value {
        serde_json::json!({
            "invocationId": invocation_id,
            "workerInvocationId": result.invocation_id,
            "result": result.result,
            "error": result.error,
        })
    }

    /// Return current connection ids.
    #[must_use]
    pub fn connections(&self) -> Vec<WorkerId> {
        self.connections.keys().cloned().collect()
    }

    /// Test helper for deterministic heartbeat-expiry coverage.
    #[cfg(test)]
    pub fn set_last_heartbeat_for_test(
        &mut self,
        worker_id: &WorkerId,
        last_heartbeat_at: DateTime<Utc>,
    ) -> Result<()> {
        self.connection_mut(worker_id)?.last_heartbeat_at = last_heartbeat_at;
        Ok(())
    }

    async fn publish_lifecycle_event(
        &self,
        event_type: &str,
        connection: &ExternalWorkerConnection,
        reason: Option<&str>,
        catalog_revision: u64,
    ) -> Result<()> {
        let trace_id = TraceId::generate();
        let event = WorkerLifecycleEvent {
            event_type: event_type.to_owned(),
            worker_id: connection.worker_id.clone(),
            registration_mode: connection.registration_mode.clone(),
            visibility: connection.default_visibility.clone(),
            session_id: connection.session_id.clone(),
            workspace_id: connection.workspace_id.clone(),
            health: connection.health.clone(),
            reason: reason.map(ToOwned::to_owned),
            functions: connection.functions.iter().cloned().collect(),
            triggers: connection.triggers.iter().cloned().collect(),
            catalog_revision,
            trace_id: trace_id.clone(),
            timestamp: Utc::now().to_rfc3339(),
        };
        let mut context = CausalContext::new(
            ActorId::new("worker-runtime")?,
            ActorKind::System,
            AuthorityGrantId::new("worker-runtime")?,
            trace_id,
        )
        .with_scope("stream.write")
        .with_scope(ENGINE_INTERNAL_INVOKE_SCOPE)
        .with_idempotency_key(format!(
            "worker-lifecycle:{event_type}:{}:{catalog_revision}:{}",
            connection.worker_id,
            InvocationId::generate()
        ));
        if let Some(session_id) = connection.session_id.clone() {
            context = context.with_session_id(session_id);
        }
        if let Some(workspace_id) = connection.workspace_id.clone() {
            context = context.with_workspace_id(workspace_id);
        }
        let mut payload = serde_json::json!({
            "topic": WORKER_LIFECYCLE_TOPIC,
            "payload": event,
            "visibility": lifecycle_visibility(connection).as_str(),
            "producer": "worker-runtime",
        });
        if let Some(session_id) = connection.session_id.clone() {
            payload["sessionId"] = serde_json::Value::String(session_id);
        }
        if let Some(workspace_id) = connection.workspace_id.clone() {
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
        Ok(())
    }

    async fn catalog_snapshot_for(&self, worker_id: &WorkerId) -> CatalogSnapshot {
        let authority_grant = self
            .connections
            .get(worker_id)
            .map(|connection| connection.worker_token.authority_grant_id.clone())
            .unwrap_or_else(|| AuthorityGrantId::new("worker-runtime").expect("valid grant id"));
        let actor = ActorContext::new(
            ActorId::new(format!("worker:{worker_id}")).expect("valid worker actor id"),
            ActorKind::Worker,
            authority_grant,
        );
        let functions = self
            .host
            .discover(&FunctionQuery {
                actor: Some(actor),
                ..FunctionQuery::default()
            })
            .await;
        CatalogSnapshot {
            functions,
            triggers: Vec::new(),
        }
    }

    fn connection_mut(&mut self, worker_id: &WorkerId) -> Result<&mut ExternalWorkerConnection> {
        self.connections
            .get_mut(worker_id)
            .ok_or_else(|| EngineError::NotFound {
                kind: "external worker connection",
                id: worker_id.to_string(),
            })
    }

    async fn mark_durable_worker_disconnected(
        &self,
        connection: &ExternalWorkerConnection,
    ) -> Result<()> {
        let admin_actor = ActorContext::new(
            ActorId::new("worker-runtime")?,
            ActorKind::System,
            AuthorityGrantId::new("worker-runtime")?,
        );
        for function_id in &connection.functions {
            let id = FunctionId::new(function_id.clone())?;
            let mut definition = self.host.inspect_function(&id, Some(&admin_actor)).await?;
            definition.health = FunctionHealth::Unhealthy;
            self.host.register_function(definition, None, false).await?;
        }
        let mut worker = self.host.inspect_worker(&connection.worker_id).await?;
        worker.lifecycle = WorkerLifecycleState::Stopped;
        self.host.register_worker(worker, false).await?;
        Ok(())
    }
}

fn validate_worker_token(hello: &WorkerHello) -> Result<()> {
    let token = &hello.worker_token;
    if token.plugin_id.trim().is_empty() {
        return Err(EngineError::PolicyViolation(
            "workerToken.pluginId is required".to_owned(),
        ));
    }
    if token.namespace_claims.is_empty() {
        return Err(EngineError::PolicyViolation(
            "workerToken.namespaceClaims must not be empty".to_owned(),
        ));
    }
    for claim in &hello.worker.namespace_claims {
        if !token_claims_namespace(&token.namespace_claims, claim) {
            return Err(EngineError::PolicyViolation(format!(
                "worker namespace claim {claim} exceeds scoped token claims {:?}",
                token.namespace_claims
            )));
        }
    }
    if hello.worker.authority_grant != token.authority_grant_id {
        return Err(EngineError::PolicyViolation(format!(
            "worker authority grant {} does not match scoped token grant {}",
            hello.worker.authority_grant, token.authority_grant_id
        )));
    }
    if token.authority_grant_revision == 0 || token.authority_grant_hash.trim().is_empty() {
        return Err(EngineError::PolicyViolation(
            "workerToken authority grant revision and hash are required".to_owned(),
        ));
    }
    if token.resource_selectors.is_empty() {
        return Err(EngineError::PolicyViolation(
            "workerToken.resourceSelectors must not be empty".to_owned(),
        ));
    }
    if visibility_rank(&hello.default_visibility) > visibility_rank(&token.visibility_ceiling) {
        return Err(EngineError::PolicyViolation(format!(
            "worker visibility {:?} exceeds token visibility ceiling {:?}",
            hello.default_visibility, token.visibility_ceiling
        )));
    }
    if let Some(expected) = token.session_id.as_deref()
        && hello.session_id.as_deref() != Some(expected)
    {
        return Err(EngineError::PolicyViolation(
            "worker sessionId does not match scoped token".to_owned(),
        ));
    }
    if let Some(expected) = token.workspace_id.as_deref()
        && hello.workspace_id.as_deref() != Some(expected)
    {
        return Err(EngineError::PolicyViolation(
            "worker workspaceId does not match scoped token".to_owned(),
        ));
    }
    if let Some(expires_at) = token.expires_at.as_deref() {
        let expires_at = chrono::DateTime::parse_from_rfc3339(expires_at)
            .map_err(|error| {
                EngineError::PolicyViolation(format!("invalid worker token expiry: {error}"))
            })?
            .with_timezone(&Utc);
        if expires_at <= Utc::now() {
            return Err(EngineError::PolicyViolation(
                "worker scoped token is expired".to_owned(),
            ));
        }
    }
    Ok(())
}

fn validate_external_capability_metadata(
    definition: &FunctionDefinition,
    namespace_claims: &[String],
    token: &ScopedWorkerToken,
) -> Result<()> {
    if !definition.visibility.is_agent_visible() {
        return Ok(());
    }
    if definition.request_schema.is_none() || definition.response_schema.is_none() {
        return Err(EngineError::PolicyViolation(format!(
            "external visible function {} requires request and response schemas",
            definition.id
        )));
    }
    let required = [
        "contractId",
        "implementationId",
        "pluginId",
        "trustTier",
        "contextPrimerLevel",
        "runtimeRequirements",
    ];
    for key in required {
        if definition.metadata.get(key).is_none() {
            return Err(EngineError::PolicyViolation(format!(
                "external visible function {} requires capability metadata `{key}`",
                definition.id
            )));
        }
    }
    let contract_id = definition
        .metadata
        .get("contractId")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let implementation_id = definition
        .metadata
        .get("implementationId")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let plugin_id = definition
        .metadata
        .get("pluginId")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let trust_tier = definition
        .metadata
        .get("trustTier")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if plugin_id != token.plugin_id {
        return Err(EngineError::PolicyViolation(format!(
            "external visible function {} pluginId {plugin_id} does not match scoped token plugin {}",
            definition.id, token.plugin_id
        )));
    }
    if trust_tier != token.trust_tier {
        return Err(EngineError::PolicyViolation(format!(
            "external visible function {} trustTier {trust_tier} does not match scoped token trust {}",
            definition.id, token.trust_tier
        )));
    }
    let contract_namespace = contract_id
        .split_once("::")
        .map(|(namespace, _)| namespace)
        .unwrap_or(contract_id);
    let claims_match = |value: &str| {
        namespace_claims.iter().any(|claim| {
            value == claim || value.starts_with(&format!("{claim}::")) || value.contains(claim)
        })
    };
    if !claims_match(definition.id.namespace())
        || !claims_match(contract_namespace)
        || !claims_match(implementation_id)
    {
        return Err(EngineError::PolicyViolation(format!(
            "external visible function {} metadata must stay within namespace claims {:?}",
            definition.id, namespace_claims
        )));
    }
    Ok(())
}

fn stamp_external_capability_metadata(
    definition: &mut FunctionDefinition,
    token: &ScopedWorkerToken,
) {
    if !definition.visibility.is_agent_visible() {
        return;
    }
    let health_state = external_health_state(definition, token);
    let Some(metadata) = definition.metadata.as_object_mut() else {
        return;
    };
    metadata.insert(
        "pluginId".to_owned(),
        Value::String(token.plugin_id.clone()),
    );
    metadata.insert(
        "trustTier".to_owned(),
        Value::String(token.trust_tier.clone()),
    );
    metadata.insert(
        "signatureStatus".to_owned(),
        Value::String(token.signature_status.clone()),
    );
    metadata.insert(
        "healthState".to_owned(),
        Value::String(health_state.to_owned()),
    );
}

fn external_health_state(
    definition: &FunctionDefinition,
    token: &ScopedWorkerToken,
) -> &'static str {
    if definition.health == FunctionHealth::Healthy
        && token.trust_tier == "session_generated"
        && matches!(
            token.signature_status.as_str(),
            "session_scoped" | "engine_issued"
        )
    {
        "healthy"
    } else {
        "candidate"
    }
}

fn token_claims_namespace(claims: &[String], value: &str) -> bool {
    claims.iter().any(|claim| {
        value == claim || value.starts_with(&format!("{claim}::")) || value.contains(claim)
    })
}

fn visibility_rank(visibility: &WorkerVisibility) -> u8 {
    match visibility {
        WorkerVisibility::Session => 0,
        WorkerVisibility::Workspace => 1,
        WorkerVisibility::System => 2,
    }
}

fn lifecycle_visibility(connection: &ExternalWorkerConnection) -> VisibilityScope {
    match connection.default_visibility {
        WorkerVisibility::Session if connection.session_id.is_none() => VisibilityScope::System,
        WorkerVisibility::Workspace if connection.workspace_id.is_none() => VisibilityScope::System,
        _ => connection.default_visibility.as_visibility_scope(),
    }
}

struct ExternalFunctionProxyHandler {
    invoker: Arc<dyn ExternalWorkerInvoker>,
}

#[async_trait]
impl InProcessFunctionHandler for ExternalFunctionProxyHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        let result = self
            .invoker
            .invoke(WorkerInvoke {
                invocation_id: invocation.id.clone(),
                function_id: invocation.function_id.clone(),
                payload: invocation.payload.clone(),
                actor_kind: invocation.causal_context.actor_kind.clone(),
                authority_grant_id: invocation.causal_context.authority_grant_id.clone(),
                authority_scopes: invocation.causal_context.authority_scopes.clone(),
                trace_id: invocation.causal_context.trace_id.clone(),
                parent_invocation_id: invocation.causal_context.parent_invocation_id.clone(),
                trigger_id: invocation.causal_context.trigger_id.clone(),
                idempotency_key: invocation.causal_context.idempotency_key.clone(),
                session_id: invocation.causal_context.session_id.clone(),
                workspace_id: invocation.causal_context.workspace_id.clone(),
                timeout_ms: 30_000,
            })
            .await?;
        if let Some(error) = result.error {
            if worker_result_error_code(&error) == Some("WORKER_DISCONNECTED") {
                return Err(EngineError::WorkerTransportFailure {
                    code: "WORKER_DISCONNECTED".to_owned(),
                    message: worker_result_error_message(&error),
                });
            }
            return Err(EngineError::HandlerFailed(error.to_string()));
        }
        Ok(result.result.unwrap_or(Value::Null))
    }
}

fn worker_result_error_code(error: &Value) -> Option<&str> {
    error.get("code").and_then(Value::as_str)
}

fn worker_result_error_message(error: &Value) -> String {
    error
        .get("message")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| error.to_string())
}
