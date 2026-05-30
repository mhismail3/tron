//! Module maintenance queue producers owned by the engine host handle.

use super::*;

impl EngineHostHandle {
    /// Enqueue due module health checks from active activation resources.
    pub async fn enqueue_due_module_health_checks(&self, now: DateTime<Utc>) -> Result<usize> {
        let host = self.inner.lock().await;
        let function_id = FunctionId::new(primitives::module::CHECK_HEALTH_FUNCTION)?;
        let actor = ActorContext::new(
            ActorId::new(ENGINE_OWNER_ACTOR)?,
            ActorKind::System,
            AuthorityGrantId::new(ENGINE_AUTHORITY_GRANT)?,
        );
        let function = host.catalog.inspect_function(&function_id, Some(&actor))?;
        let resources = {
            let resources = host.primitives.resources.lock().map_err(|_| {
                EngineError::HandlerFailed("resource store lock poisoned".to_owned())
            })?;
            resources.list(super::super::resources::ListResources {
                kind: Some(super::super::resources::ACTIVATION_RECORD_KIND.to_owned()),
                scope: None,
                lifecycle: Some("active".to_owned()),
                limit: 500,
            })?
        };
        let mut enqueued = 0usize;
        for resource in resources {
            let Some((version_id, payload)) = ({
                let resources = host.primitives.resources.lock().map_err(|_| {
                    EngineError::HandlerFailed("resource store lock poisoned".to_owned())
                })?;
                resources
                    .inspect(&resource.resource_id)?
                    .and_then(|inspection| {
                        let current = inspection.resource.current_version_id.clone()?;
                        let payload = inspection
                            .versions
                            .iter()
                            .find(|version| version.version_id == current)?
                            .payload
                            .clone();
                        Some((current, payload))
                    })
            }) else {
                continue;
            };
            let interval = payload
                .get("healthPolicy")
                .and_then(|policy| policy.get("intervalSeconds"))
                .and_then(Value::as_u64)
                .filter(|value| *value > 0);
            let Some(interval) = interval else {
                continue;
            };
            if let Some(checked_at) = payload.get("checkedAt").and_then(Value::as_str)
                && let Ok(checked_at) = DateTime::parse_from_rfc3339(checked_at)
            {
                let elapsed = now
                    .signed_duration_since(checked_at.with_timezone(&Utc))
                    .num_seconds();
                if elapsed >= 0 && elapsed < interval as i64 {
                    continue;
                }
            }
            let bucket = now.timestamp().div_euclid(interval as i64);
            let idempotency_key = format!(
                "module.health:{}:{}:{}",
                resource.resource_id, version_id, bucket
            );
            let already_queued = {
                let queue = host.primitives.queue.lock().map_err(|_| {
                    EngineError::HandlerFailed("queue store lock poisoned".to_owned())
                })?;
                queue
                    .list("module", 500)?
                    .iter()
                    .any(|item| item.idempotency_key.as_deref() == Some(idempotency_key.as_str()))
            };
            if already_queued {
                continue;
            }
            let (session_id, workspace_id) = match &resource.scope {
                super::super::resources::EngineResourceScope::System => (None, None),
                super::super::resources::EngineResourceScope::Workspace(id) => {
                    (None, Some(id.clone()))
                }
                super::super::resources::EngineResourceScope::Session(id) => {
                    (Some(id.clone()), None)
                }
            };
            let item = EnqueueInvocation {
                queue: "module".to_owned(),
                function_id: function_id.clone(),
                target_revision: Some(function.revision),
                payload: json!({
                    "activationResourceId": resource.resource_id,
                    "activationVersionId": version_id,
                    "expectedCurrentVersionId": version_id,
                    "mode": "scheduled",
                }),
                actor_id: ActorId::new(ENGINE_OWNER_ACTOR)?,
                actor_kind: ActorKind::System,
                authority_grant_id: AuthorityGrantId::new(ENGINE_AUTHORITY_GRANT)?,
                authority_scopes: vec!["module.write".to_owned()],
                trace_id: TraceId::generate(),
                parent_invocation_id: None,
                trigger_id: None,
                session_id,
                workspace_id,
                idempotency_key: Some(idempotency_key),
            };
            host.primitives
                .queue
                .lock()
                .map_err(|_| EngineError::HandlerFailed("queue store lock poisoned".to_owned()))?
                .enqueue(item)?;
            enqueued = enqueued.saturating_add(1);
        }
        Ok(enqueued)
    }

    /// Enqueue due module trust audits from active schedule decision resources.
    pub async fn enqueue_due_module_trust_audits(&self, now: DateTime<Utc>) -> Result<usize> {
        let host = self.inner.lock().await;
        let function_id = FunctionId::new(primitives::module::RUN_SCHEDULED_TRUST_AUDIT_FUNCTION)?;
        let actor = ActorContext::new(
            ActorId::new(ENGINE_OWNER_ACTOR)?,
            ActorKind::System,
            AuthorityGrantId::new(ENGINE_AUTHORITY_GRANT)?,
        );
        let function = host.catalog.inspect_function(&function_id, Some(&actor))?;
        let resources = {
            let resources = host.primitives.resources.lock().map_err(|_| {
                EngineError::HandlerFailed("resource store lock poisoned".to_owned())
            })?;
            resources.list(super::super::resources::ListResources {
                kind: Some("decision".to_owned()),
                scope: None,
                lifecycle: Some("final".to_owned()),
                limit: 500,
            })?
        };
        let mut enqueued = 0usize;
        for resource in resources {
            let Some((version_id, payload)) = ({
                let resources = host.primitives.resources.lock().map_err(|_| {
                    EngineError::HandlerFailed("resource store lock poisoned".to_owned())
                })?;
                resources
                    .inspect(&resource.resource_id)?
                    .and_then(|inspection| {
                        let current = inspection.resource.current_version_id.clone()?;
                        let payload = inspection
                            .versions
                            .iter()
                            .find(|version| version.version_id == current)?
                            .payload
                            .clone();
                        Some((current, payload))
                    })
            }) else {
                continue;
            };
            let Some(due_bucket) = primitives::module::trust_audit_current_due_bucket(
                &resource.resource_id,
                &version_id,
                &resource.lifecycle,
                resource.created_at,
                &payload,
                now,
            )
            .ok()
            .flatten() else {
                continue;
            };
            let already_completed = {
                let resources = host.primitives.resources.lock().map_err(|_| {
                    EngineError::HandlerFailed("resource store lock poisoned".to_owned())
                })?;
                resources
                    .list(super::super::resources::ListResources {
                        kind: Some("evidence".to_owned()),
                        scope: None,
                        lifecycle: None,
                        limit: 500,
                    })?
                    .into_iter()
                    .filter_map(|evidence| resources.inspect(&evidence.resource_id).ok().flatten())
                    .filter_map(|inspection| {
                        let current = inspection.resource.current_version_id.clone()?;
                        inspection
                            .versions
                            .iter()
                            .find(|version| version.version_id == current)
                            .map(|version| version.payload.clone())
                    })
                    .any(|payload| {
                        primitives::module::trust_audit_evidence_matches_due_bucket(
                            &payload,
                            &resource.resource_id,
                            &version_id,
                            &due_bucket,
                        )
                    })
            };
            if already_completed {
                continue;
            }
            let idempotency_key = format!(
                "module.trust_audit:{}:{}:{}",
                resource.resource_id, version_id, due_bucket
            );
            let already_queued = {
                let queue = host.primitives.queue.lock().map_err(|_| {
                    EngineError::HandlerFailed("queue store lock poisoned".to_owned())
                })?;
                queue
                    .list("module", 500)?
                    .iter()
                    .any(|item| item.idempotency_key.as_deref() == Some(idempotency_key.as_str()))
            };
            if already_queued {
                continue;
            }
            let (session_id, workspace_id) = match &resource.scope {
                super::super::resources::EngineResourceScope::System => (None, None),
                super::super::resources::EngineResourceScope::Workspace(id) => {
                    (None, Some(id.clone()))
                }
                super::super::resources::EngineResourceScope::Session(id) => {
                    (Some(id.clone()), None)
                }
            };
            let item = EnqueueInvocation {
                queue: "module".to_owned(),
                function_id: function_id.clone(),
                target_revision: Some(function.revision),
                payload: json!({
                    "scheduleDecisionResourceId": resource.resource_id,
                    "scheduleDecisionVersionId": version_id,
                    "dueBucket": due_bucket,
                }),
                actor_id: ActorId::new(ENGINE_OWNER_ACTOR)?,
                actor_kind: ActorKind::System,
                authority_grant_id: AuthorityGrantId::new(ENGINE_AUTHORITY_GRANT)?,
                authority_scopes: vec!["module.write".to_owned()],
                trace_id: TraceId::generate(),
                parent_invocation_id: None,
                trigger_id: None,
                session_id,
                workspace_id,
                idempotency_key: Some(idempotency_key),
            };
            host.primitives
                .queue
                .lock()
                .map_err(|_| EngineError::HandlerFailed("queue store lock poisoned".to_owned()))?
                .enqueue(item)?;
            enqueued = enqueued.saturating_add(1);
        }
        Ok(enqueued)
    }
}
