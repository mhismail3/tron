//! Management authorization, wait topology, and structured cancellation.

use super::*;

impl WorkerRuntime {
    /// Closed management union for offers, cancellation, quiescent
    /// configuration/close, bounded management grants, and immutable role
    /// upgrades.
    pub(crate) async fn agent_manage(&self, invocation: &Invocation) -> Result<Value, String> {
        let (caller, _) = self.resolve_calling_agent(invocation).await?;
        let action = required_coordination_string(&invocation.payload, "action")?;
        match action.as_str() {
            "respond_to_offer" => {
                let assignment_id =
                    required_coordination_string(&invocation.payload, "assignmentId")?;
                let response = required_coordination_string(&invocation.payload, "response")?;
                let assignment = self
                    .store
                    .agent_assignment(&assignment_id)?
                    .ok_or_else(|| format!("agent assignment '{assignment_id}' was not found"))?;
                if assignment.agent_id != caller.agent_id
                    || assignment.status != AgentAssignmentStatus::Offered
                {
                    return Err("only the offered-to agent may answer a pending offer".to_owned());
                }
                let target = match response.as_str() {
                    "accept" => AgentAssignmentStatus::Accepted,
                    "decline" => AgentAssignmentStatus::Declined,
                    other => return Err(format!("unsupported offer response '{other}'")),
                };
                let mut updated =
                    self.store
                        .transition_agent_assignment(&AgentAssignmentTransition {
                            assignment_id,
                            expected_status: AgentAssignmentStatus::Offered,
                            target_status: target,
                            result: None,
                            error: invocation
                                .payload
                                .get("reason")
                                .and_then(Value::as_str)
                                .map(ToOwned::to_owned),
                        })?;
                if updated.status == AgentAssignmentStatus::Accepted {
                    updated =
                        self.store
                            .transition_agent_assignment(&AgentAssignmentTransition {
                                assignment_id: updated.assignment_id.clone(),
                                expected_status: AgentAssignmentStatus::Accepted,
                                target_status: AgentAssignmentStatus::Queued,
                                result: None,
                                error: None,
                            })?;
                }
                // Accepted work is now runnable; declined work owns a terminal
                // result outbox. Wake the shared importer/dispatcher for both.
                let _ = self.import_agent_coordination_outbox().await;
                self.delivery_maintenance.notify_one();
                Ok(json!({
                    "action":action,
                    "status":updated.status.as_str(),
                    "agentId":updated.agent_id,
                    "assignmentId":updated.assignment_id,
                    "executionId":updated.execution_id,
                    "affected":1,
                }))
            }
            "cancel" => {
                let target = invocation
                    .payload
                    .get("target")
                    .and_then(Value::as_object)
                    .ok_or_else(|| "agent cancel requires target".to_owned())?;
                let kind = target
                    .get("kind")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "agent cancel target.kind is required".to_owned())?;
                let id = target
                    .get("id")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "agent cancel target.id is required".to_owned())?;
                let affected = match kind {
                    "assignment" => {
                        let assignment = self
                            .store
                            .agent_assignment(id)?
                            .ok_or_else(|| format!("agent assignment '{id}' was not found"))?;
                        if assignment.requester_agent_id.as_deref() != Some(&caller.agent_id)
                            && !self.store.has_agent_management(
                                &caller.agent_id,
                                &assignment.agent_id,
                                AgentManagementCapability::Cancel,
                            )?
                        {
                            return Err(
                                "agent assignment cancellation is outside caller authority"
                                    .to_owned(),
                            );
                        }
                        self.cancel_execution_tree(&assignment.execution_id).await?
                    }
                    "agent" => {
                        self.require_management(
                            &caller.agent_id,
                            id,
                            AgentManagementCapability::Cancel,
                        )?;
                        self.cancel_agent_owned_subtree(
                            id,
                            "cancelled by an authorized coordinating agent",
                        )
                        .await?
                    }
                    "worker_execution" => {
                        let execution_id = if self.store.execution_node(id)?.is_some() {
                            id.to_owned()
                        } else {
                            format!("execution_{id}")
                        };
                        let node = self
                            .store
                            .execution_node(&execution_id)?
                            .ok_or_else(|| format!("worker execution '{id}' was not found"))?;
                        let owner = node.owner_agent_id.as_deref().ok_or_else(|| {
                            "worker execution has no durable agent owner".to_owned()
                        })?;
                        self.require_management(
                            &caller.agent_id,
                            owner,
                            AgentManagementCapability::Cancel,
                        )?;
                        self.cancel_execution_tree(&execution_id).await?
                    }
                    other => return Err(format!("unsupported cancellation target '{other}'")),
                };
                Ok(json!({"action":action,"status":"cancelled","affected":affected}))
            }
            "close" => {
                let agent_id = required_coordination_string(&invocation.payload, "agentId")?;
                self.require_management(
                    &caller.agent_id,
                    &agent_id,
                    AgentManagementCapability::Close,
                )?;
                let subtree = self.store.agent_owned_subtree_ids(&agent_id)?;
                let lifecycle_reservation =
                    self.reserve_agent_lifecycle_runs(&subtree, "close agent")?;
                self.require_no_pending_coordination_waits(&agent_id, true)?;
                let closed = self.store.close_agent_subtree(&agent_id)?;
                lifecycle_reservation.commit_closed();
                self.demote_closed_agent_wakes(&subtree);
                Ok(json!({
                    "action":action,"status":"closed","agentId":agent_id,
                    "affected":closed.len(),
                }))
            }
            "configure" => {
                let agent_id = required_coordination_string(&invocation.payload, "agentId")?;
                self.require_management(
                    &caller.agent_id,
                    &agent_id,
                    AgentManagementCapability::Configure,
                )?;
                let _lifecycle_reservation = self.reserve_agent_lifecycle_runs(
                    std::slice::from_ref(&agent_id),
                    "configure agent",
                )?;
                self.require_no_pending_coordination_waits(&agent_id, false)?;
                let current = self
                    .store
                    .agent_instance(&agent_id)?
                    .ok_or_else(|| format!("agent '{agent_id}' was not found"))?;
                let configuration = invocation
                    .payload
                    .get("configuration")
                    .and_then(Value::as_object)
                    .ok_or_else(|| "agent configure requires configuration".to_owned())?;
                let current_tools = string_array(&current.tool_grant)
                    .into_iter()
                    .collect::<BTreeSet<_>>();
                let tools = optional_string_array(&Value::Object(configuration.clone()), "tools")?
                    .unwrap_or_else(|| current_tools.iter().cloned().collect());
                if tools.iter().any(|tool| !current_tools.contains(tool)) {
                    return Err(
                        "agent configuration may only tighten its current tool grant".to_owned(),
                    );
                }
                let current_scopes = string_array(&current.write_scopes);
                let write_scopes =
                    optional_string_array(&Value::Object(configuration.clone()), "writeScopes")?
                        .map(|scopes| {
                            scopes
                                .into_iter()
                                .map(|scope| canonical_write_scope(&scope))
                                .collect::<Result<Vec<_>, _>>()
                        })
                        .transpose()?
                        .unwrap_or_else(|| current_scopes.clone());
                if write_scopes.iter().any(|scope| {
                    !current_scopes
                        .iter()
                        .any(|parent| scope_is_within(scope, parent))
                }) {
                    return Err("agent configuration may only tighten write scopes".to_owned());
                }
                let limits = configuration
                    .get("limits")
                    .map(|requested| tighten_limits(&current.limits, &current.limits, requested))
                    .transpose()?
                    .unwrap_or_else(|| current.limits.clone());
                let updated = self.store.configure_agent(&AgentConfigurationUpdate {
                    agent_id: agent_id.clone(),
                    model: current.default_model,
                    reasoning_level: current.default_reasoning_level,
                    tool_grant: json!(tools),
                    write_scopes: json!(write_scopes),
                    limits,
                })?;
                Ok(json!({
                    "action":action,"status":"configured","agentId":updated.agent_id,
                    "affected":1,
                }))
            }
            "grant_management" => {
                let target_agent_id = required_coordination_string(&invocation.payload, "agentId")?;
                let grantee_agent_id =
                    required_coordination_string(&invocation.payload, "toAgentId")?;
                let capabilities = optional_string_array(&invocation.payload, "capabilities")?
                    .ok_or_else(|| "management grant requires capabilities".to_owned())?;
                if !self.is_management_owner(&caller.agent_id, &target_agent_id)? {
                    return Err(
                        "management rights may be delegated only by an owning ancestor".to_owned(),
                    );
                }
                // Validate the complete request before the first durable write.
                // A caller holding a bounded grant cannot re-delegate it.
                let capabilities = capabilities
                    .into_iter()
                    .map(|capability| parse_management_capability(&capability))
                    .collect::<Result<Vec<_>, _>>()?;
                let grants =
                    self.store
                        .grant_agent_management_batch(&NewAgentManagementGrantBatch {
                            idempotency_key: format!("agent-manage-grant:{}", invocation.id),
                            target_agent_id: target_agent_id.clone(),
                            grantee_agent_id: grantee_agent_id.clone(),
                            granted_by_agent_id: caller.agent_id.clone(),
                            capabilities,
                        })?;
                Ok(json!({
                    "action":action,"status":"granted","agentId":target_agent_id,
                    "grantId":grants.first().map(|grant| grant.grant_id.as_str()),
                    "affected":grants.len(),
                }))
            }
            "revoke_management" => {
                let grant_id = required_coordination_string(&invocation.payload, "grantId")?;
                let revoked = self
                    .store
                    .revoke_agent_management(&grant_id, &caller.agent_id)?;
                if !revoked {
                    return Err(
                        "management grant was not active or was issued by another agent".to_owned(),
                    );
                }
                Ok(json!({
                    "action":action,"status":"revoked","grantId":grant_id,"affected":1,
                }))
            }
            "upgrade_role" => {
                let agent_id = required_coordination_string(&invocation.payload, "agentId")?;
                self.require_management(
                    &caller.agent_id,
                    &agent_id,
                    AgentManagementCapability::Configure,
                )?;
                let _lifecycle_reservation = self.reserve_agent_lifecycle_runs(
                    std::slice::from_ref(&agent_id),
                    "upgrade agent role",
                )?;
                self.require_no_pending_coordination_waits(&agent_id, false)?;
                let role_id = required_coordination_string(&invocation.payload, "role")?;
                let current = self
                    .store
                    .agent_instance(&agent_id)?
                    .ok_or_else(|| format!("agent '{agent_id}' was not found"))?;
                if current.role_id.as_deref() != Some(role_id.as_str()) {
                    return Err(
                        "role upgrades must retain the agent's pinned role identity".to_owned()
                    );
                }
                let version = optional_coordination_string(&invocation.payload, "version")?;
                let active = version.as_deref().map_or_else(
                    || self.store.load_indexed_active(&role_id),
                    |version| self.store.load_version(&role_id, version),
                )?;
                if !is_executable_agent_role(&active.summary, active.bundle.agent_role.as_ref()) {
                    return Err(format!(
                        "agent role '{role_id}' is not an active healthy agent runner"
                    ));
                }
                let Some(WorkerAgentRole::Enabled {
                    discoverable: true,
                    default_model,
                    default_reasoning_level,
                    tool_ceiling,
                    limits,
                    ..
                }) = active.bundle.agent_role.as_ref()
                else {
                    return Err(format!(
                        "worker '{role_id}' has no discoverable enabled agent role"
                    ));
                };
                let caller_grant = self
                    .delegation_ceiling_for_agent(&caller)
                    .await?
                    .into_iter()
                    .collect::<BTreeSet<_>>();
                let tools = tool_ceiling
                    .iter()
                    .filter(|tool| caller_grant.contains(*tool))
                    .cloned()
                    .collect::<Vec<_>>();
                let role_limits =
                    serde_json::to_value(limits).map_err(|error| error.to_string())?;
                let effective_limits =
                    tighten_limits(&self.default_agent_limits(), &role_limits, &current.limits)?;
                let effective_model = default_model
                    .clone()
                    .or_else(|| current.default_model.clone());
                let effective_reasoning = default_reasoning_level
                    .clone()
                    .or_else(|| current.default_reasoning_level.clone());
                validate_agent_model_reasoning(
                    effective_model.as_deref(),
                    effective_reasoning.as_deref(),
                    &crate::shared::foundation::paths::auth_path_for_home(self.store.home()),
                )?;
                let updated = self.store.update_agent_role(&AgentRoleUpdate {
                    agent_id: agent_id.clone(),
                    role_id,
                    role_version: active.summary.active_version.clone(),
                    model: effective_model,
                    reasoning_level: effective_reasoning,
                    tool_grant: json!(tools),
                    limits: effective_limits,
                })?;
                Ok(json!({
                    "action":action,"status":"upgraded","agentId":updated.agent_id,
                    "affected":1,
                }))
            }
            other => Err(format!("unsupported agent management action '{other}'")),
        }
    }

    fn require_management(
        &self,
        caller_agent_id: &str,
        target_agent_id: &str,
        capability: AgentManagementCapability,
    ) -> Result<(), String> {
        if self
            .store
            .has_agent_management(caller_agent_id, target_agent_id, capability)?
        {
            Ok(())
        } else {
            Err(format!(
                "agent '{caller_agent_id}' has no {} authority over '{target_agent_id}'",
                capability.as_str()
            ))
        }
    }

    fn is_management_owner(
        &self,
        caller_agent_id: &str,
        target_agent_id: &str,
    ) -> Result<bool, String> {
        let mut current = self.store.agent_instance(target_agent_id)?;
        let mut visited = BTreeSet::new();
        while let Some(agent) = current {
            if !visited.insert(agent.agent_id.clone()) {
                return Err("agent management ownership contains a cycle".to_owned());
            }
            if agent.agent_id == caller_agent_id {
                return Ok(true);
            }
            current = match agent.management_owner_agent_id.as_deref() {
                Some(owner_id) => self.store.agent_instance(owner_id)?,
                None => None,
            };
        }
        Ok(false)
    }

    fn require_no_pending_coordination_waits(
        &self,
        target_agent_id: &str,
        include_owned_subtree: bool,
    ) -> Result<(), String> {
        let candidates = if include_owned_subtree {
            self.store.agent_owned_subtree_ids(target_agent_id)?
        } else {
            vec![target_agent_id.to_owned()]
        };
        if candidates.is_empty() {
            return Err(format!("agent '{target_agent_id}' was not found"));
        }
        for candidate in candidates {
            if self
                .event_store
                .has_pending_coordination_wait_for_agent(&candidate)
                .map_err(|error| error.to_string())?
            {
                return Err(format!(
                    "agent '{candidate}' has a pending coordination wait and is not quiescent"
                ));
            }
        }
        Ok(())
    }

    /// Reserve the exact transcript set which one quiescent lifecycle mutation
    /// will inspect and change. The orchestrator owns the shared boundary with
    /// delivery-wake admission, so an auxiliary provider run cannot appear
    /// between this check and the durable WorkerStore mutation.
    pub(in crate::domains::worker_kernel::runtime) fn reserve_agent_lifecycle_runs(
        &self,
        agent_ids: &[String],
        action: &str,
    ) -> Result<
        crate::domains::agent::r#loop::orchestrator::core::LifecycleRunAdmissionReservation,
        String,
    > {
        let mut session_ids = Vec::new();
        for agent_id in agent_ids {
            let agent = self
                .store
                .agent_instance(agent_id)?
                .ok_or_else(|| format!("agent '{agent_id}' was not found"))?;
            if agent.state != AgentInstanceState::Closed {
                session_ids.push(agent.session_id);
            }
        }
        self.orchestrator
            .try_reserve_lifecycle_runs(&session_ids)
            .map_err(|error| format!("cannot {action}: {error}"))
    }

    /// Preserve pending coordination evidence while making every wake for a
    /// durably closed transcript passive. The process-lifetime admission block
    /// has already committed when this runs, so a transient EventStore failure
    /// cannot make the wake runnable; the delivery dispatcher retries the same
    /// closed-state reconciliation later.
    pub(in crate::domains::worker_kernel::runtime) fn demote_closed_agent_wakes(
        &self,
        agent_ids: &[String],
    ) {
        for agent_id in agent_ids {
            let agent = match self.store.agent_instance(agent_id) {
                Ok(Some(agent)) => agent,
                Ok(None) => {
                    tracing::warn!(agent_id, "closed agent disappeared before wake demotion");
                    continue;
                }
                Err(error) => {
                    tracing::warn!(
                        agent_id,
                        error,
                        "could not resolve closed agent transcript for wake demotion"
                    );
                    continue;
                }
            };
            if let Err(error) = self
                .event_store
                .demote_all_agent_wakes_for_session(&agent.session_id)
            {
                tracing::warn!(
                    agent_id,
                    session_id = agent.session_id,
                    error = %error,
                    "could not make a closed agent's retained wakes passive"
                );
            }
        }
    }

    pub(in crate::domains::worker_kernel::runtime) fn authorize_wait_target(
        &self,
        caller: &AgentInstanceRecord,
        session_id: &str,
        kind: CoordinationTargetKind,
        id: &str,
    ) -> Result<(), String> {
        match kind {
            CoordinationTargetKind::AgentAssignment => {
                let assignment = self
                    .store
                    .agent_assignment(id)?
                    .ok_or_else(|| format!("agent assignment '{id}' was not found"))?;
                let participant = assignment.agent_id == caller.agent_id
                    || assignment.requester_agent_id.as_deref() == Some(&caller.agent_id)
                    || assignment.delegator_agent_id.as_deref() == Some(&caller.agent_id);
                if participant
                    || self.store.has_agent_management(
                        &caller.agent_id,
                        &assignment.agent_id,
                        AgentManagementCapability::Assign,
                    )?
                {
                    Ok(())
                } else {
                    Err("agent assignment wait is outside the caller relationship".to_owned())
                }
            }
            CoordinationTargetKind::WorkerInvocation => {
                let worker = self
                    .store
                    .invocation(id)?
                    .ok_or_else(|| format!("worker invocation '{id}' was not found"))?;
                if worker.origin_session_id.as_deref() == Some(session_id) {
                    return Ok(());
                }
                let execution = self
                    .store
                    .execution_node(&format!("execution_{id}"))?
                    .ok_or_else(|| {
                        "worker invocation has no mixed execution identity".to_owned()
                    })?;
                let owner = execution
                    .owner_agent_id
                    .as_deref()
                    .ok_or_else(|| "worker invocation has no durable agent owner".to_owned())?;
                if owner == caller.agent_id
                    || self.store.has_agent_management(
                        &caller.agent_id,
                        owner,
                        AgentManagementCapability::Assign,
                    )?
                {
                    Ok(())
                } else {
                    Err("worker wait is outside the caller's causal ownership".to_owned())
                }
            }
            CoordinationTargetKind::Reply => {
                let question = self
                    .event_store
                    .agent_message_metadata(id)
                    .map_err(|error| error.to_string())?
                    .ok_or_else(|| format!("agent question '{id}' was not found"))?;
                if question.kind == AgentMessageKind::Question
                    && question.source_agent_id == caller.agent_id
                {
                    Ok(())
                } else {
                    Err("reply wait requires a question sent by the caller".to_owned())
                }
            }
        }
    }

    /// Resolve opaque model handles into the one dependency namespace used by
    /// EventStore's transactional wait graph. Stable agent identities are the
    /// scheduler nodes: an assignment or direct-agent execution points to the
    /// exact agent that must run it, while ordinary command/service workers
    /// remain independently progressing execution nodes. Mixed causal
    /// parentage always points parent -> child because structured completion
    /// joins descendants.
    pub(in crate::domains::worker_kernel::runtime) fn resolve_coordination_wait_topology(
        &self,
        caller: &AgentInstanceRecord,
        invocation: &Invocation,
        targets: &[CoordinationWaitTarget],
    ) -> Result<
        (
            String,
            Vec<CoordinationWaitDependency>,
            Vec<CoordinationDependencyEdge>,
        ),
        String,
    > {
        let owner_dependency_id = coordination_agent_dependency_id(&caller.agent_id);
        let mut edges = BTreeSet::new();
        if let Some(source_execution_id) = causal_parent_execution_id(invocation) {
            let ancestry = self.store.execution_ancestry(&source_execution_id)?;
            let source = ancestry
                .last()
                .ok_or_else(|| "calling execution ancestry is empty".to_owned())?;
            if source.assignment_id.is_some()
                && source.owner_agent_id.as_deref() != Some(caller.agent_id.as_str())
            {
                return Err(
                    "calling assignment execution does not belong to the stable agent".to_owned(),
                );
            }
            append_execution_dependency_edges(&ancestry, &mut edges)?;
        }

        let mut dependencies = Vec::with_capacity(targets.len());
        for target in targets {
            let dependency_id = match target.kind {
                CoordinationTargetKind::AgentAssignment => {
                    let assignment = self
                        .store
                        .agent_assignment(&target.id)?
                        .ok_or_else(|| format!("agent assignment '{}' disappeared", target.id))?;
                    let ancestry = self.store.execution_ancestry(&assignment.execution_id)?;
                    append_execution_dependency_edges(&ancestry, &mut edges)?;
                    coordination_execution_dependency_id(&assignment.execution_id)
                }
                CoordinationTargetKind::WorkerInvocation => {
                    let execution = self
                        .store
                        .execution_node_for_worker_invocation(&target.id)?
                        .ok_or_else(|| {
                            format!(
                                "worker invocation '{}' has no mixed execution identity",
                                target.id
                            )
                        })?;
                    let ancestry = self.store.execution_ancestry(&execution.execution_id)?;
                    append_execution_dependency_edges(&ancestry, &mut edges)?;
                    coordination_execution_dependency_id(&execution.execution_id)
                }
                CoordinationTargetKind::Reply => {
                    let question = self
                        .event_store
                        .agent_message_metadata(&target.id)
                        .map_err(|error| error.to_string())?
                        .ok_or_else(|| format!("agent question '{}' disappeared", target.id))?;
                    let _ = self
                        .store
                        .agent_instance(&question.target_agent_id)?
                        .ok_or_else(|| {
                            format!(
                                "question responder agent '{}' disappeared",
                                question.target_agent_id
                            )
                        })?;
                    coordination_agent_dependency_id(&question.target_agent_id)
                }
            };
            dependencies.push(CoordinationWaitDependency {
                target: target.clone(),
                dependency_id,
            });
        }
        Ok((
            owner_dependency_id,
            dependencies,
            edges.into_iter().collect(),
        ))
    }

    pub(in crate::domains::worker_kernel::runtime) fn effective_direct_child_execution_ceiling(
        &self,
        invocation: &Invocation,
        caller: &AgentInstanceRecord,
        profile_ceiling: u32,
    ) -> Result<u32, String> {
        let fallback = caller
            .limits
            .get("maxChildExecutions")
            .and_then(Value::as_u64)
            .and_then(|value| u32::try_from(value).ok())
            .unwrap_or(profile_ceiling);
        let Some(parent_execution_id) = causal_parent_execution_id(invocation) else {
            return Ok(fallback.min(profile_ceiling));
        };
        let parent = self
            .store
            .execution_node(&parent_execution_id)?
            .ok_or_else(|| format!("parent execution '{parent_execution_id}' was not found"))?;
        let ceiling = if let Some(assignment_id) = parent.assignment_id.as_deref() {
            self.store
                .agent_assignment(assignment_id)?
                .and_then(|assignment| {
                    assignment
                        .limits_snapshot
                        .get("maxChildExecutions")
                        .and_then(Value::as_u64)
                })
                .and_then(|value| u32::try_from(value).ok())
                .unwrap_or(fallback)
        } else if let Some(invocation_id) = parent.worker_invocation_id.as_deref() {
            let worker = self.store.invocation(invocation_id)?.ok_or_else(|| {
                format!("parent worker invocation '{invocation_id}' was not found")
            })?;
            self.store
                .load_version(&worker.worker_id, &worker.worker_version)?
                .bundle
                .execution_limits
                .max_child_invocations
                .unwrap_or(fallback)
        } else {
            fallback
        };
        Ok(ceiling.min(profile_ceiling))
    }

    pub(in crate::domains::worker_kernel::runtime) fn coordination_terminal_evidence(
        &self,
        caller: &AgentInstanceRecord,
        targets: &[CoordinationWaitTarget],
    ) -> Result<Vec<CoordinationTerminalEvidence>, String> {
        let mut evidence = Vec::new();
        for target in targets {
            match target.kind {
                CoordinationTargetKind::AgentAssignment => {
                    let assignment = self
                        .store
                        .agent_assignment(&target.id)?
                        .ok_or_else(|| format!("agent assignment '{}' disappeared", target.id))?;
                    if assignment.status.is_terminal() {
                        evidence.push(CoordinationTerminalEvidence {
                            target: target.clone(),
                            status: assignment.status.as_str().to_owned(),
                            evidence_reference: json!({
                                "assignmentId":assignment.assignment_id,
                                "result":assignment.result_reference,
                                "error":assignment.error,
                            }),
                        });
                    }
                }
                CoordinationTargetKind::WorkerInvocation => {
                    let worker = self
                        .store
                        .invocation(&target.id)?
                        .ok_or_else(|| format!("worker invocation '{}' disappeared", target.id))?;
                    if matches!(worker.status.as_str(), "completed" | "failed" | "cancelled") {
                        evidence.push(CoordinationTerminalEvidence {
                            target: target.clone(),
                            status: worker.status.clone(),
                            evidence_reference: json!({
                                "invocationId":worker.invocation_id,
                                "result":self.store.result_reference(&target.id)?,
                                "error":worker.error,
                            }),
                        });
                    }
                }
                CoordinationTargetKind::Reply => {
                    if let Some(answer) = self
                        .event_store
                        .answer_for_agent_question(&caller.agent_id, &target.id)
                        .map_err(|error| error.to_string())?
                    {
                        evidence.push(CoordinationTerminalEvidence {
                            target: target.clone(),
                            status: "answered".to_owned(),
                            evidence_reference: json!({"messageId":answer.message_id}),
                        });
                    }
                }
            }
        }
        Ok(evidence)
    }

    /// Cancel every live assignment in the exact management-owned subtree.
    ///
    /// This deliberately does not derive ownership from causal edges: a
    /// reusable descendant can be working on a later peer request whose trace
    /// no longer descends from its original spawn assignment. The store query
    /// is unpaged and descendant-first, while each assignment's execution tree
    /// supplies mixed agent/worker recursion.
    pub(in crate::domains::worker_kernel::runtime) async fn cancel_agent_owned_subtree(
        &self,
        agent_id: &str,
        reason: &str,
    ) -> Result<usize, String> {
        let agent_ids = self.store.agent_owned_subtree_ids(agent_id)?;
        let agents = agent_ids
            .iter()
            .map(|agent_id| {
                self.store
                    .agent_instance(agent_id)?
                    .ok_or_else(|| format!("owned agent '{agent_id}' disappeared"))
            })
            .collect::<Result<Vec<_>, String>>()?;
        let cancellable_session_ids = agents
            .iter()
            .filter(|agent| agent.state != AgentInstanceState::Closed)
            .map(|agent| agent.session_id.clone())
            .collect::<Vec<_>>();
        // One registry transaction cancels active tokens, tombstones selected
        // wake reservations, and blocks fresh admission for the whole exact
        // management subtree. Hold it until executions and retained wakes have
        // both reached their durable cancellation boundary.
        let _run_cancellation = self
            .orchestrator
            .reserve_agent_run_cancellation(&cancellable_session_ids)
            .map_err(|error| format!("cannot cancel agent subtree: {error}"))?;
        let assignments = self
            .store
            .nonterminal_agent_assignments_for_owned_subtree(agent_id)?;
        let mut affected = 0;
        for assignment in assignments {
            affected += self
                .cancel_execution_tree_with_reason(&assignment.execution_id, reason)
                .await?;
        }
        // Questions, offers, and operator continuations may own a transcript
        // run without owning an assignment. Abort those exact sessions and
        // make every retained wake passive, including a wake whose admission
        // reservation was cancelled before `begin_run` could consume it.
        for agent in agents {
            affected = affected.saturating_add(
                self.event_store
                    .demote_all_agent_wakes_for_session(&agent.session_id)
                    .map_err(|error| error.to_string())?,
            );
        }
        if affected > 0 {
            self.delivery_maintenance.notify_one();
        }
        Ok(affected)
    }

    pub(in crate::domains::worker_kernel::runtime) async fn cancel_execution_tree(
        &self,
        execution_id: &str,
    ) -> Result<usize, String> {
        self.cancel_execution_tree_with_reason(
            execution_id,
            "cancelled by an authorized coordinating agent",
        )
        .await
    }

    async fn cancel_execution_tree_with_reason(
        &self,
        execution_id: &str,
        reason: &str,
    ) -> Result<usize, String> {
        let mut nodes = self.store.execution_subtree(execution_id)?;
        nodes.reverse();
        let mut affected = 0;
        for node in nodes {
            // A direct agent-worker execution can project both identities on
            // one node. Terminalize the assignment side first so its live
            // attempt is retained as interrupted before worker cancellation
            // observes and closes the same mapping.
            if let Some(assignment_id) = node.assignment_id.as_deref() {
                affected += self.cancel_agent_assignment(assignment_id, reason)?;
            }
            if let Some(invocation_id) = node.worker_invocation_id.as_deref() {
                let worker = self
                    .store
                    .invocation(invocation_id)?
                    .ok_or_else(|| format!("worker invocation '{invocation_id}' disappeared"))?;
                if !matches!(worker.status.as_str(), "completed" | "failed" | "cancelled") {
                    self.cancel_invocation(invocation_id).await?;
                    affected += 1;
                }
            }
        }
        Ok(affected)
    }

    fn cancel_agent_assignment(&self, assignment_id: &str, reason: &str) -> Result<usize, String> {
        // Provider completion and cancellation can meet at a safe boundary.
        // Re-read after a lost compare-and-set so a concurrently terminalized
        // assignment is success, while live work is never silently skipped.
        for _ in 0..3 {
            let Some(assignment) = self.store.agent_assignment(assignment_id)? else {
                return Err(format!("agent assignment '{assignment_id}' disappeared"));
            };
            if assignment.status.is_terminal() {
                return Ok(0);
            }
            if matches!(
                assignment.status,
                AgentAssignmentStatus::Running | AgentAssignmentStatus::Waiting
            ) && let Some(agent) = self.store.agent_instance(&assignment.agent_id)?
            {
                let _ = self.orchestrator.abort(&agent.session_id);
            }
            self.event_store
                .cancel_coordination_waits_for_assignment(assignment_id)
                .map_err(|error| error.to_string())?;
            self.store
                .interrupt_running_agent_assignment_attempts(assignment_id, reason)?;
            match self
                .store
                .transition_agent_assignment(&AgentAssignmentTransition {
                    assignment_id: assignment.assignment_id,
                    expected_status: assignment.status,
                    target_status: AgentAssignmentStatus::Cancelled,
                    result: None,
                    error: Some(reason.to_owned()),
                }) {
                Ok(_) => return Ok(1),
                Err(error) => {
                    let Some(current) = self.store.agent_assignment(assignment_id)? else {
                        return Err(format!("agent assignment '{assignment_id}' disappeared"));
                    };
                    if current.status.is_terminal() {
                        return Ok(0);
                    }
                    if current.status != assignment.status {
                        continue;
                    }
                    return Err(error);
                }
            }
        }
        let assignment = self.store.agent_assignment(assignment_id)?;
        if assignment.is_some_and(|assignment| assignment.status.is_terminal()) {
            Ok(0)
        } else {
            Err(format!(
                "agent assignment '{assignment_id}' remained live after cancellation retries"
            ))
        }
    }
}
