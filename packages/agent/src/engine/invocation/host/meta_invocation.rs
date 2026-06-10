//! Engine meta-function invocation and delegated child execution.

use super::*;

impl EngineHost {
    pub(super) fn invoke_sync_host_dispatched_primitive(
        &mut self,
        mut invocation: Invocation,
    ) -> InvocationResult {
        let function = match self.prepare_meta_invocation(&mut invocation) {
            Ok(function) => function,
            Err(err) => return self.meta_error(&invocation, err),
        };

        let idempotency = match self
            .catalog
            .begin_invocation_idempotency(&function, &invocation)
        {
            InvocationIdempotencyDecision::None => None,
            InvocationIdempotencyDecision::Reserved(reservation) => Some(reservation),
            InvocationIdempotencyDecision::Finished { result, scope } => {
                return self
                    .catalog
                    .record_invocation_result(&invocation, result, scope);
            }
        };
        if let Err(err) = self.consume_invocation_budget_sync(&function, &invocation) {
            return self.finish_meta_invocation(invocation, function, Err(err), idempotency);
        }

        let compensation_contract = function.compensation.clone();
        let lease_result = self.acquire_resource_lease_for_invocation(&function, &invocation);
        let mut lease_ids = Vec::new();
        let value = match lease_result {
            Ok(Some(lease)) => {
                lease_ids.push(lease.lease_id.clone());
                let result = primitives::runtime::dispatch(self, &invocation);
                release_after_primary(self.release_resource_lease_sync(&lease.lease_id), result)
            }
            Ok(None) => primitives::runtime::dispatch(self, &invocation),
            Err(error) => Err(error),
        };
        self.finish_meta_invocation_with_contracts(
            invocation,
            function,
            value,
            idempotency,
            lease_ids,
            compensation_contract,
        )
    }

    pub(super) fn invoke_sync_meta(&mut self, mut invocation: Invocation) -> InvocationResult {
        let function = match self.prepare_meta_invocation(&mut invocation) {
            Ok(function) => function,
            Err(err) => return self.meta_error(&invocation, err),
        };

        let idempotency = match self
            .catalog
            .begin_invocation_idempotency(&function, &invocation)
        {
            InvocationIdempotencyDecision::None => None,
            InvocationIdempotencyDecision::Reserved(reservation) => Some(reservation),
            InvocationIdempotencyDecision::Finished { result, scope } => {
                return self
                    .catalog
                    .record_invocation_result(&invocation, result, scope);
            }
        };
        if let Err(err) = self.consume_invocation_budget_sync(&function, &invocation) {
            return self.finish_meta_invocation(invocation, function, Err(err), idempotency);
        }

        let compensation_contract = function.compensation.clone();
        let lease_result = self.acquire_resource_lease_for_invocation(&function, &invocation);
        let mut lease_ids = Vec::new();
        let value = match lease_result {
            Ok(Some(lease)) => {
                lease_ids.push(lease.lease_id.clone());
                let result = match invocation.function_id.as_str() {
                    DISCOVER_FUNCTION => self.meta_discover(&invocation),
                    INSPECT_FUNCTION => self.meta_inspect(&invocation),
                    WATCH_FUNCTION => self.meta_watch(&invocation),
                    PROMOTE_FUNCTION => self.meta_promote(&invocation),
                    _ => Err(EngineError::NotFound {
                        kind: "function",
                        id: invocation.function_id.to_string(),
                    }),
                };
                release_after_primary(self.release_resource_lease_sync(&lease.lease_id), result)
            }
            Ok(None) => match invocation.function_id.as_str() {
                DISCOVER_FUNCTION => self.meta_discover(&invocation),
                INSPECT_FUNCTION => self.meta_inspect(&invocation),
                WATCH_FUNCTION => self.meta_watch(&invocation),
                PROMOTE_FUNCTION => self.meta_promote(&invocation),
                _ => Err(EngineError::NotFound {
                    kind: "function",
                    id: invocation.function_id.to_string(),
                }),
            },
            Err(error) => Err(error),
        };
        self.finish_meta_invocation_with_contracts(
            invocation,
            function,
            value,
            idempotency,
            lease_ids,
            compensation_contract,
        )
    }

    pub(super) async fn invoke_delegated(
        &mut self,
        mut invocation: Invocation,
    ) -> InvocationResult {
        let function = match self.prepare_meta_invocation(&mut invocation) {
            Ok(function) => function,
            Err(err) => return self.meta_error(&invocation, err),
        };

        if let Err(err) = self.consume_invocation_budget_sync(&function, &invocation) {
            return self.finish_meta_invocation(invocation, function, Err(err), None);
        }
        let value = match self.meta_invoke_child(&invocation).await {
            Ok(value) => Ok(value),
            Err(err) => Err(err),
        };
        self.finish_meta_invocation(invocation, function, value, None)
    }

    pub(super) fn prepare_delegated_invocation(
        &mut self,
        mut invocation: Invocation,
    ) -> PreparedDelegatedInvocationDecision {
        let function = match self.prepare_meta_invocation(&mut invocation) {
            Ok(function) => function,
            Err(err) => {
                return PreparedDelegatedInvocationDecision::Finished(Box::new(
                    self.meta_error(&invocation, err),
                ));
            }
        };

        let child = match delegated_child_invocation(&invocation) {
            Ok(child) => child,
            Err(err) => {
                return PreparedDelegatedInvocationDecision::Finished(Box::new(
                    self.finish_meta_invocation(invocation, function, Err(err), None),
                ));
            }
        };
        let child = if is_host_dispatched_primitive_function(&child.function_id) {
            PreparedDelegatedChild::Sync(PreparedSyncInvocationDecision::Finished(Box::new(
                self.invoke_sync_host_dispatched_primitive(child),
            )))
        } else {
            PreparedDelegatedChild::Sync(self.catalog.prepare_sync_invocation(child))
        };
        if let Err(err) = self.consume_invocation_budget_sync(&function, &invocation) {
            return PreparedDelegatedInvocationDecision::Finished(Box::new(
                self.finish_meta_invocation(invocation, function, Err(err), None),
            ));
        }
        PreparedDelegatedInvocationDecision::Execute(Box::new(PreparedDelegatedInvocation {
            meta_invocation: invocation,
            meta_function: function,
            child,
        }))
    }

    fn prepare_meta_invocation(&self, invocation: &mut Invocation) -> Result<FunctionDefinition> {
        let function = self
            .catalog
            .function(&invocation.function_id)
            .cloned()
            .ok_or_else(|| EngineError::NotFound {
                kind: "function",
                id: invocation.function_id.to_string(),
            })?;

        invocation.causal_context.catalog_revision = self.catalog.revision();
        policy::validate_invocation(&function, invocation)?;
        self.primitives
            .grants
            .lock()
            .map_err(|_| EngineError::HandlerFailed("grant store lock poisoned".to_owned()))?
            .authorize_invocation(&function, invocation)?;
        if let Some(schema) = &function.request_schema {
            schema::validate_payload(&function.id, "request", schema, &invocation.payload)?;
        }
        Ok(function)
    }

    fn consume_invocation_budget_sync(
        &mut self,
        function: &FunctionDefinition,
        invocation: &Invocation,
    ) -> Result<()> {
        self.primitives
            .grants
            .lock()
            .map_err(|_| EngineError::HandlerFailed("grant store lock poisoned".to_owned()))?
            .consume_invocation_budget(ConsumeGrantInvocationBudget {
                grant_id: invocation.causal_context.authority_grant_id.clone(),
                invocation_id: invocation.id.clone(),
                function_id: function.id.clone(),
                trace_id: invocation.causal_context.trace_id.clone(),
            })
            .map(|_| ())
    }

    pub(super) fn finish_meta_invocation(
        &mut self,
        invocation: Invocation,
        function: FunctionDefinition,
        value: Result<Value>,
        idempotency: Option<IdempotencyReservation>,
    ) -> InvocationResult {
        self.finish_meta_invocation_with_contracts(
            invocation,
            function,
            value,
            idempotency,
            Vec::new(),
            None,
        )
    }

    fn finish_meta_invocation_with_contracts(
        &mut self,
        invocation: Invocation,
        function: FunctionDefinition,
        value: Result<Value>,
        idempotency: Option<IdempotencyReservation>,
        resource_lease_ids: Vec<String>,
        compensation_contract: Option<CompensationContract>,
    ) -> InvocationResult {
        let mut result = match value {
            Ok(value) => InvocationResult::success(
                &invocation,
                function.owner_worker.clone(),
                function.revision,
                self.catalog.revision(),
                value,
            ),
            Err(err) => InvocationResult::error(
                &invocation,
                function.owner_worker.clone(),
                function.revision,
                self.catalog.revision(),
                err,
            ),
        };
        let idempotency_scope = idempotency
            .as_ref()
            .map(|reservation| reservation.key.scope.clone());
        if let Some(reservation) = &idempotency {
            if let Some(completion_error) = self.catalog.complete_invocation_idempotency(
                reservation,
                &invocation,
                &function,
                &result,
            ) {
                result = completion_error;
            }
        }
        let compensation_status = compensation_contract
            .as_ref()
            .map(|_| "recorded".to_owned());
        let compensation = self.record_compensation_for_result_sync(
            &invocation,
            compensation_contract,
            &result,
            resource_lease_ids.clone(),
        );
        let compensation_status = compensation
            .as_ref()
            .map(|record| record.status.as_str().to_owned())
            .or(compensation_status);
        self.catalog.record_invocation_result_with_contracts(
            &invocation,
            result,
            idempotency_scope,
            resource_lease_ids,
            compensation_status,
        )
    }

    fn meta_error(&mut self, invocation: &Invocation, err: EngineError) -> InvocationResult {
        let worker_id = self
            .catalog
            .function(&invocation.function_id)
            .map(|function| function.owner_worker.clone())
            .unwrap_or_else(|| worker_id(ENGINE_WORKER_ID).expect("valid engine worker id"));
        let revision = self
            .catalog
            .function(&invocation.function_id)
            .map(|function| function.revision)
            .unwrap_or(FunctionRevision(0));
        let result = InvocationResult::error(
            invocation,
            worker_id,
            revision,
            self.catalog.revision(),
            err,
        );
        self.catalog
            .record_invocation_result(invocation, result, None)
    }

    fn meta_discover(&self, invocation: &Invocation) -> Result<Value> {
        let payload = &invocation.payload;
        let query = FunctionQuery {
            actor: Some(actor_context(&invocation.causal_context)),
            visibility: optional_visibility(payload.get("visibility"))?,
            namespace_prefix: optional_string(payload.get("namespacePrefix"))?,
            text: optional_string(payload.get("text"))?,
            effect_class: optional_effect(payload.get("effectClass"))?,
            max_risk: optional_risk(payload.get("maxRisk"))?,
            health: optional_health(payload.get("health"))?,
            include_internal: payload
                .get("includeInternal")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        };
        let functions = self.catalog.discover_functions(&query);
        Ok(json!({
            "functions": functions,
        }))
    }

    pub(super) fn meta_inspect(&self, invocation: &Invocation) -> Result<Value> {
        let kind = required_str(&invocation.payload, "kind")?;
        let id = required_str(&invocation.payload, "id")?;
        let actor = actor_context(&invocation.causal_context);
        let definition = match kind {
            "function" => {
                let definition = self
                    .catalog
                    .inspect_function(&function_id(id)?, Some(&actor))?;
                json!(definition)
            }
            "worker" => {
                let definition = self.catalog.inspect_worker(&worker_id(id)?)?;
                if !is_visibility_visible(
                    &definition.visibility,
                    definition.provenance.session_id.as_deref(),
                    definition.provenance.workspace_id.as_deref(),
                    &actor,
                ) {
                    return Err(EngineError::PolicyViolation(format!(
                        "worker {id} is not visible"
                    )));
                }
                json!(definition)
            }
            "trigger_type" => {
                let definition = self
                    .catalog
                    .inspect_trigger_type(&TriggerTypeId::new(id)?)?;
                if !is_visibility_visible(
                    &definition.visibility,
                    definition.provenance.session_id.as_deref(),
                    definition.provenance.workspace_id.as_deref(),
                    &actor,
                ) {
                    return Err(EngineError::PolicyViolation(format!(
                        "trigger type {id} is not visible"
                    )));
                }
                json!(definition)
            }
            "trigger" => {
                let definition = self.catalog.inspect_trigger(&TriggerId::new(id)?)?;
                if !is_visibility_visible(
                    &definition.visibility,
                    definition.provenance.session_id.as_deref(),
                    definition.provenance.workspace_id.as_deref(),
                    &actor,
                ) {
                    return Err(EngineError::PolicyViolation(format!(
                        "trigger {id} is not visible"
                    )));
                }
                json!(definition)
            }
            _ => {
                return Err(EngineError::PolicyViolation(format!(
                    "unsupported inspect kind {kind}"
                )));
            }
        };
        Ok(json!({
            "kind": kind,
            "definition": definition,
        }))
    }

    pub(super) fn meta_watch(&self, invocation: &Invocation) -> Result<Value> {
        let actor = actor_context(&invocation.causal_context);
        let response =
            self.watch_catalog(&actor, watch_request_from_payload(&invocation.payload)?)?;
        let changes = response
            .changes
            .iter()
            .map(catalog_change_value)
            .collect::<Vec<_>>();
        Ok(json!({
            "changes": changes,
            "currentRevision": response.current_revision.0,
            "nextRevision": response.next_revision.0,
            "hasMore": response.has_more,
        }))
    }

    async fn meta_invoke_child(&mut self, invocation: &Invocation) -> Result<Value> {
        let child = delegated_child_invocation(invocation)?;
        let child_result = if is_host_dispatched_primitive_function(&child.function_id) {
            self.invoke_sync_host_dispatched_primitive(child)
        } else {
            self.catalog.invoke_sync(child).await
        };
        Ok(delegated_invoke_value(&child_result))
    }

    fn meta_promote(&mut self, invocation: &Invocation) -> Result<Value> {
        let function_id = function_id(required_str(&invocation.payload, "functionId")?)?;
        let target = required_visibility(&invocation.payload, "targetVisibility")?;
        let workspace_id = optional_string(invocation.payload.get("workspaceId"))?;

        let function = self
            .catalog
            .function(&function_id)
            .cloned()
            .ok_or_else(|| EngineError::NotFound {
                kind: "function",
                id: function_id.to_string(),
            })?;
        let owner_worker = match optional_string(invocation.payload.get("ownerWorker"))? {
            Some(owner) => worker_id(&owner)?,
            None => function.owner_worker.clone(),
        };
        if function.visibility != VisibilityScope::Session {
            return Err(EngineError::InvalidVisibilityPromotion {
                function_id: function_id.to_string(),
                target: target.as_str().to_owned(),
                reason: "only session-visible functions can be promoted by engine::promote"
                    .to_owned(),
            });
        }
        let actor = actor_context(&invocation.causal_context);
        if !actor.actor_kind.is_admin_like()
            && function.provenance.session_id.as_deref() != actor.session_id.as_deref()
        {
            return Err(EngineError::PolicyViolation(
                "cannot promote function from a different session".to_owned(),
            ));
        }
        match target {
            VisibilityScope::Workspace | VisibilityScope::System => {}
            _ => {
                return Err(EngineError::InvalidVisibilityPromotion {
                    function_id: function_id.to_string(),
                    target: target.as_str().to_owned(),
                    reason: "engine::promote only supports workspace or system targets".to_owned(),
                });
            }
        }

        let revision = self.catalog.promote_function_visibility(
            &function_id,
            &owner_worker,
            target.clone(),
            workspace_id,
        )?;
        Ok(json!({
            "functionId": function_id.as_str(),
            "revision": revision.0,
            "visibility": target.as_str(),
        }))
    }

    pub(super) fn visible_workers(&self, actor: &ActorContext) -> Vec<WorkerDefinition> {
        self.catalog
            .workers()
            .into_iter()
            .filter(|worker| {
                is_visibility_visible(
                    &worker.visibility,
                    worker.provenance.session_id.as_deref(),
                    worker.provenance.workspace_id.as_deref(),
                    actor,
                )
            })
            .collect()
    }

    pub(super) fn visible_triggers(&self, actor: &ActorContext) -> Vec<TriggerDefinition> {
        self.catalog
            .triggers()
            .into_iter()
            .filter(|trigger| {
                is_visibility_visible(
                    &trigger.visibility,
                    trigger.provenance.session_id.as_deref(),
                    trigger.provenance.workspace_id.as_deref(),
                    actor,
                )
            })
            .collect()
    }

    pub(super) fn visible_trigger_types(&self, actor: &ActorContext) -> Vec<TriggerTypeDefinition> {
        self.catalog
            .trigger_types()
            .into_iter()
            .filter(|trigger_type| {
                is_visibility_visible(
                    &trigger_type.visibility,
                    trigger_type.provenance.session_id.as_deref(),
                    trigger_type.provenance.workspace_id.as_deref(),
                    actor,
                )
            })
            .collect()
    }
}
