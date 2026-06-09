//! External-worker connection lifecycle and health transitions.

use std::time::Duration;

use super::validation::validate_worker_token;
use super::*;

impl EngineExternalWorkerRuntime {
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

    pub(super) async fn publish_lifecycle_event(
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

    pub(super) fn connection_mut(
        &mut self,
        worker_id: &WorkerId,
    ) -> Result<&mut ExternalWorkerConnection> {
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

fn lifecycle_visibility(connection: &ExternalWorkerConnection) -> VisibilityScope {
    match connection.default_visibility {
        WorkerVisibility::Session if connection.session_id.is_none() => VisibilityScope::System,
        WorkerVisibility::Workspace if connection.workspace_id.is_none() => VisibilityScope::System,
        _ => connection.default_visibility.as_visibility_scope(),
    }
}
