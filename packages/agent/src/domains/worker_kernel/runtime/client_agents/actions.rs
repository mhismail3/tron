//! Authenticated operator mutations and exact destructive-impact accounting.

use super::*;

impl WorkerRuntime {
    pub(crate) async fn client_agent_operator_message(
        &self,
        invocation: &Invocation,
    ) -> Result<Value, String> {
        let scope = self.client_agent_scope(invocation).await?;
        let agent_id = required_client_string(&invocation.payload, "agentId")?;
        let target = self.require_scoped_agent(&scope, &agent_id)?;
        if target.state == AgentInstanceState::Closed {
            return Err("closed agents cannot receive operator instructions".to_owned());
        }
        if !self.store.has_agent_management(
            &scope.owner.agent_id,
            &target.agent_id,
            AgentManagementCapability::Assign,
        )? {
            return Err(
                "the selected session has no assignment authority for this agent".to_owned(),
            );
        }
        let content = required_client_string(&invocation.payload, "content")?;
        let mutation_id = required_client_string(&invocation.payload, "clientMutationId")?;
        let mut delegated = invocation.clone();
        delegated.payload = json!({
            "to":target.agent_id,
            "kind":"instruction",
            "content":content,
            "clientMutationId":mutation_id,
        });
        self.agent_send(&delegated).await?;
        self.client_mutation_result(invocation, &agent_id, vec![agent_id.clone()])
            .await
    }

    pub(crate) async fn client_agent_manage(
        &self,
        invocation: &Invocation,
    ) -> Result<Value, String> {
        let scope = self.client_agent_scope(invocation).await?;
        let agent_id = required_client_string(&invocation.payload, "agentId")?;
        let target = self.require_scoped_agent(&scope, &agent_id)?;
        let action = required_client_string(&invocation.payload, "action")?;
        let mutation_id = required_client_string(&invocation.payload, "clientMutationId")?;
        let configuration = invocation
            .payload
            .get("configuration")
            .cloned()
            .unwrap_or(Value::Null);
        let mut affected = vec![agent_id.clone()];

        match action.as_str() {
            "cancel" => {
                self.require_client_management(
                    &scope.owner,
                    target,
                    AgentManagementCapability::Cancel,
                )?;
                if let Some(assignment_id) = invocation
                    .payload
                    .get("assignmentId")
                    .and_then(Value::as_str)
                {
                    let assignment =
                        self.store.agent_assignment(assignment_id)?.ok_or_else(|| {
                            format!("agent assignment '{assignment_id}' was not found")
                        })?;
                    if assignment.agent_id != target.agent_id {
                        return Err("assignment does not belong to the selected agent".to_owned());
                    }
                    self.cancel_execution_tree(&assignment.execution_id).await?;
                } else {
                    self.cancel_agent_owned_subtree(
                        &target.agent_id,
                        "cancelled by an authenticated operator",
                    )
                    .await?;
                }
                affected = self.store.agent_owned_subtree_ids(&target.agent_id)?;
            }
            "close" => {
                self.require_client_management(
                    &scope.owner,
                    target,
                    AgentManagementCapability::Close,
                )?;
                let subtree = self.store.agent_owned_subtree_ids(&target.agent_id)?;
                let lifecycle_reservation =
                    self.reserve_agent_lifecycle_runs(&subtree, "close agent")?;
                self.require_client_wait_quiescence(&subtree, "close")?;
                affected = self.store.close_agent_subtree(&target.agent_id)?;
                lifecycle_reservation.commit_closed();
                self.demote_closed_agent_wakes(&subtree);
            }
            "configure" => {
                self.require_client_management(
                    &scope.owner,
                    target,
                    AgentManagementCapability::Configure,
                )?;
                let lifecycle_reservation = self.reserve_agent_lifecycle_runs(
                    std::slice::from_ref(&target.agent_id),
                    "configure agent",
                )?;
                let current = self
                    .store
                    .agent_instance(&target.agent_id)?
                    .ok_or_else(|| format!("agent '{}' was not found", target.agent_id))?;
                self.require_client_wait_quiescence(
                    std::slice::from_ref(&target.agent_id),
                    "configure",
                )?;
                let object = configuration
                    .as_object()
                    .ok_or_else(|| "agent configure requires configuration".to_owned())?;
                let tools = object
                    .get("tools")
                    .cloned()
                    .unwrap_or_else(|| current.tool_grant.clone());
                let write_scopes = object
                    .get("writeScopes")
                    .cloned()
                    .unwrap_or_else(|| current.write_scopes.clone());
                let limits = object
                    .get("limits")
                    .map(|value| normalize_client_limits(value, &current.limits))
                    .transpose()?
                    .unwrap_or_else(|| current.limits.clone());
                ensure_json_subset(&tools, &current.tool_grant, "tool grant")?;
                ensure_json_subset(&write_scopes, &current.write_scopes, "write scopes")?;
                ensure_limit_tightening(&limits, &current.limits)?;
                self.store.configure_agent(&AgentConfigurationUpdate {
                    agent_id: current.agent_id,
                    model: current.default_model,
                    reasoning_level: current.default_reasoning_level,
                    tool_grant: tools,
                    write_scopes,
                    limits,
                })?;
                drop(lifecycle_reservation);
            }
            "grant_management" => {
                if !self
                    .store
                    .agent_is_management_ancestor(&scope.owner.agent_id, &target.agent_id)?
                {
                    return Err(
                        "management rights may be delegated only by an owning ancestor".to_owned(),
                    );
                }
                let object = configuration
                    .as_object()
                    .ok_or_else(|| "management grant requires configuration".to_owned())?;
                let grantee = object
                    .get("targetAgentId")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "management grant requires targetAgentId".to_owned())?;
                self.require_scoped_agent(&scope, grantee)?;
                let rights = object
                    .get("rights")
                    .and_then(Value::as_array)
                    .ok_or_else(|| "management grant requires rights".to_owned())?;
                if rights.is_empty() {
                    return Err("management grant requires at least one right".to_owned());
                }
                // Validate the complete request before the first durable
                // mutation. A malformed or unauthorized later right must not
                // leave a partial management grant behind.
                let capabilities = rights
                    .iter()
                    .map(|right| {
                        parse_client_management_capability(
                            right
                                .as_str()
                                .ok_or_else(|| "management rights must be strings".to_owned())?,
                        )
                    })
                    .collect::<Result<Vec<_>, _>>()?;
                for capability in &capabilities {
                    self.require_client_management(&scope.owner, target, *capability)?;
                }
                self.store
                    .grant_agent_management_batch(&NewAgentManagementGrantBatch {
                        idempotency_key: format!(
                            "client-agent-grant:{mutation_id}:{}",
                            target.agent_id
                        ),
                        target_agent_id: target.agent_id.clone(),
                        grantee_agent_id: grantee.to_owned(),
                        granted_by_agent_id: scope.owner.agent_id.clone(),
                        capabilities,
                    })?;
                affected.push(grantee.to_owned());
            }
            "revoke_management" => {
                if !self
                    .store
                    .agent_is_management_ancestor(&scope.owner.agent_id, &target.agent_id)?
                {
                    return Err(
                        "management rights may be revoked only by an owning ancestor".to_owned(),
                    );
                }
                let grantee = configuration
                    .get("targetAgentId")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "management revocation requires targetAgentId".to_owned())?;
                let grants = self.store.list_agent_management_grants_for_subtree(
                    &target.agent_id,
                    false,
                    MAX_CLIENT_AUDIT_ITEMS,
                )?;
                let mut revoked = 0;
                for grant in grants.into_iter().filter(|grant| {
                    grant.target_agent_id == target.agent_id
                        && grant.grantee_agent_id == grantee
                        && grant.granted_by_agent_id == scope.owner.agent_id
                }) {
                    revoked += usize::from(
                        self.store
                            .revoke_agent_management(&grant.grant_id, &scope.owner.agent_id)?,
                    );
                }
                if revoked == 0 {
                    return Err("no active management grant matched that agent".to_owned());
                }
                affected.push(grantee.to_owned());
            }
            "upgrade_role" => {
                self.require_client_management(
                    &scope.owner,
                    target,
                    AgentManagementCapability::Configure,
                )?;
                let lifecycle_reservation = self.reserve_agent_lifecycle_runs(
                    std::slice::from_ref(&target.agent_id),
                    "upgrade agent role",
                )?;
                let current = self
                    .store
                    .agent_instance(&target.agent_id)?
                    .ok_or_else(|| format!("agent '{}' was not found", target.agent_id))?;
                self.require_client_wait_quiescence(
                    std::slice::from_ref(&target.agent_id),
                    "upgrade role",
                )?;
                let role_id = current.role_id.as_deref().ok_or_else(|| {
                    "general agents do not have a pinned role to upgrade".to_owned()
                })?;
                let active = self.store.load_indexed_active(role_id)?;
                if !super::coordination::is_executable_agent_role(
                    &active.summary,
                    active.bundle.agent_role.as_ref(),
                ) {
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
                let owner_tools = self
                    .delegation_ceiling_for_agent(&scope.owner)
                    .await?
                    .into_iter()
                    .collect::<HashSet<_>>();
                let tools = tool_ceiling
                    .iter()
                    .filter(|tool| owner_tools.contains(*tool))
                    .cloned()
                    .collect::<Vec<_>>();
                let role_limits =
                    serde_json::to_value(limits).map_err(|error| error.to_string())?;
                let effective_limits = super::coordination::tighten_limits(
                    &self.default_agent_limits(),
                    &role_limits,
                    &current.limits,
                )?;
                let effective_model = default_model
                    .clone()
                    .or_else(|| current.default_model.clone());
                let effective_reasoning = default_reasoning_level
                    .clone()
                    .or_else(|| current.default_reasoning_level.clone());
                super::coordination::validate_agent_model_reasoning(
                    effective_model.as_deref(),
                    effective_reasoning.as_deref(),
                    &crate::shared::foundation::paths::auth_path_for_home(self.store.home()),
                )?;
                self.store.update_agent_role(&AgentRoleUpdate {
                    agent_id: current.agent_id,
                    role_id: role_id.to_owned(),
                    role_version: active.summary.active_version,
                    model: effective_model,
                    reasoning_level: effective_reasoning,
                    tool_grant: json!(tools),
                    limits: effective_limits,
                })?;
                drop(lifecycle_reservation);
            }
            other => {
                return Err(format!(
                    "unsupported client agent management action '{other}'"
                ));
            }
        }
        self.delivery_maintenance.notify_one();
        self.client_mutation_result(invocation, &agent_id, affected)
            .await
    }

    pub(crate) async fn client_agent_retry(
        &self,
        invocation: &Invocation,
    ) -> Result<Value, String> {
        let scope = self.client_agent_scope(invocation).await?;
        let agent_id = required_client_string(&invocation.payload, "agentId")?;
        let target = self.require_scoped_agent(&scope, &agent_id)?;
        self.require_client_management(&scope.owner, target, AgentManagementCapability::Assign)?;
        let original_id = required_client_string(&invocation.payload, "assignmentId")?;
        let original = self
            .store
            .agent_assignment(&original_id)?
            .ok_or_else(|| format!("agent assignment '{original_id}' was not found"))?;
        if original.agent_id != target.agent_id
            || !matches!(
                original.status,
                AgentAssignmentStatus::Failed
                    | AgentAssignmentStatus::Cancelled
                    | AgentAssignmentStatus::TimedOut
                    | AgentAssignmentStatus::Expired
                    | AgentAssignmentStatus::Declined
            )
        {
            return Err(
                "only an unsuccessful terminal assignment on this agent can be retried".to_owned(),
            );
        }
        let mutation_id = required_client_string(&invocation.payload, "clientMutationId")?;
        let limits = &self.settings_runtime.current().settings.agent.coordination;
        let message_id = format!("agent_message_{mutation_id}");
        let mut participants = [scope.owner.agent_id.as_str(), target.agent_id.as_str()];
        participants.sort_unstable();
        self.store.enqueue_agent_assignment(&NewAgentAssignment {
            admission_key: format!("client-agent-retry:{mutation_id}"),
            agent_id: target.agent_id.clone(),
            requester_agent_id: Some(scope.owner.agent_id.clone()),
            delegator_agent_id: Some(scope.owner.agent_id.clone()),
            kind: AgentAssignmentKind::Operator,
            offered: false,
            task: original.task.clone(),
            context: self.assignment_context_for_agent(
                target,
                json!({"retryOf":original.assignment_id,"operator":true}),
            )?,
            parent_execution_id: None,
            trace_id: invocation.causal_context.trace_id.as_str().to_owned(),
            causal_depth: 1,
            child_slot: None,
            max_active_children: limits.max_active_children,
            max_child_executions: scope
                .owner
                .limits
                .get("maxChildExecutions")
                .and_then(Value::as_u64)
                .and_then(|value| u32::try_from(value).ok())
                .unwrap_or(limits.max_execution_nodes)
                .min(limits.max_execution_nodes),
            max_execution_nodes: limits.max_execution_nodes,
            max_causal_depth: limits.max_causal_depth,
            max_queued_assignments: self
                .effective_agent_queue_ceiling(target, limits.max_queued_assignments),
            model: original
                .model
                .clone()
                .or_else(|| target.default_model.clone()),
            reasoning_level: original
                .reasoning_level
                .clone()
                .or_else(|| target.default_reasoning_level.clone()),
            authority_snapshot: target.tool_grant.clone(),
            resource_snapshot: original.resource_snapshot.clone(),
            write_scopes_snapshot: target.write_scopes.clone(),
            limits_snapshot: target.limits.clone(),
            retry_of_assignment_id: Some(original.assignment_id),
            deadline_at: assignment_deadline(&target.limits),
            message: NewAgentAssignmentMessage {
                deduplication_key: format!("client-agent-retry-message:{mutation_id}"),
                message_id,
                channel_id: format!("agent_channel:{}:{}", participants[0], participants[1]),
                source_agent_id: scope.owner.agent_id.clone(),
                source_session_id: scope.owner.session_id.clone(),
                source_name: Some(scope.owner.name.clone()),
                target_session_id: target.session_id.clone(),
                kind: AgentMessageKind::Instruction,
                authority: AgentMessageAuthority::Operator,
                reply_to: None,
                text: original.task,
                autonomous_hop: 0,
            },
        })?;
        let _ = self.import_agent_coordination_outbox().await;
        self.delivery_maintenance.notify_one();
        self.client_mutation_result(invocation, &agent_id, vec![agent_id.clone()])
            .await
    }

    pub(crate) async fn client_agent_promote(
        &self,
        invocation: &Invocation,
    ) -> Result<Value, String> {
        let scope = self.client_agent_scope(invocation).await?;
        let agent_id = required_client_string(&invocation.payload, "agentId")?;
        let target = self.require_scoped_agent(&scope, &agent_id)?;
        self.require_client_management(&scope.owner, target, AgentManagementCapability::Configure)?;
        let mutation_id = required_client_string(&invocation.payload, "clientMutationId")?;
        let subtree = self.store.agent_owned_subtree_ids(&target.agent_id)?;
        let lifecycle_reservation = self.reserve_agent_lifecycle_runs(&subtree, "promote agent")?;
        self.require_client_wait_quiescence(&subtree, "promote")?;
        self.store
            .promote_agent(&agent_id, &format!("client-agent-promote:{mutation_id}"))?;
        drop(lifecycle_reservation);
        self.import_agent_coordination_outbox().await?;
        self.client_mutation_result(invocation, &agent_id, vec![agent_id.clone()])
            .await
    }

    async fn client_mutation_result(
        &self,
        invocation: &Invocation,
        agent_id: &str,
        affected_agent_ids: Vec<String>,
    ) -> Result<Value, String> {
        let mut inspect_invocation = invocation.clone();
        inspect_invocation.payload = json!({
            "ownerSessionId":required_client_string(&invocation.payload, "ownerSessionId")?,
            "agentId":agent_id,
        });
        Ok(json!({
            "agent":self.client_agent_inspect(&inspect_invocation).await?,
            "affectedAgentIds":affected_agent_ids,
        }))
    }

    fn require_client_management(
        &self,
        owner: &AgentInstanceRecord,
        target: &AgentInstanceRecord,
        capability: AgentManagementCapability,
    ) -> Result<(), String> {
        if !self
            .store
            .has_agent_management(&owner.agent_id, &target.agent_id, capability)?
        {
            return Err(format!(
                "the selected session has no {} authority for agent '{}'",
                capability.as_str(),
                target.agent_id
            ));
        }
        Ok(())
    }

    fn require_client_wait_quiescence(
        &self,
        agent_ids: &[String],
        action: &str,
    ) -> Result<(), String> {
        for agent_id in agent_ids {
            if self
                .event_store
                .has_pending_coordination_wait_for_agent(agent_id)
                .map_err(|error| error.to_string())?
            {
                return Err(format!(
                    "cannot {action} agent '{agent_id}' while a coordination wait or reply is pending"
                ));
            }
        }
        Ok(())
    }

    /// Count the exact mixed execution records that subtree cancellation would
    /// currently terminalize. The projection is server-authored so clients do
    /// not infer destructive impact from paged relationship or history views.
    pub(super) fn client_cancellable_work_count(&self, agent_id: &str) -> Result<u64, String> {
        let roots = self
            .store
            .nonterminal_agent_assignments_for_owned_subtree(agent_id)?;
        let assignment_run_agents = roots
            .iter()
            .filter(|assignment| {
                matches!(
                    assignment.status,
                    AgentAssignmentStatus::Running | AgentAssignmentStatus::Waiting
                )
            })
            .map(|assignment| assignment.agent_id.clone())
            .collect::<HashSet<_>>();
        let mut assignment_ids = HashSet::new();
        let mut worker_invocation_ids = HashSet::new();
        for root in roots {
            assignment_ids.insert(root.assignment_id.clone());
            for node in self.store.execution_subtree(&root.execution_id)? {
                if let Some(assignment_id) = node.assignment_id {
                    let assignment = self
                        .store
                        .agent_assignment(&assignment_id)?
                        .ok_or_else(|| format!("agent assignment '{assignment_id}' disappeared"))?;
                    if !assignment.status.is_terminal() {
                        assignment_ids.insert(assignment_id);
                    }
                }
                if let Some(invocation_id) = node.worker_invocation_id {
                    let invocation = self.store.invocation(&invocation_id)?.ok_or_else(|| {
                        format!("worker invocation '{invocation_id}' disappeared")
                    })?;
                    if !matches!(
                        invocation.status.as_str(),
                        "completed" | "failed" | "cancelled"
                    ) {
                        worker_invocation_ids.insert(invocation_id);
                    }
                }
            }
        }
        let execution_count = u64::try_from(
            assignment_ids
                .len()
                .saturating_add(worker_invocation_ids.len()),
        )
        .unwrap_or(u64::MAX);
        let (wake_count, uncovered_run_count) = self
            .store
            .agent_owned_subtree_ids(agent_id)?
            .into_iter()
            .try_fold((0_u64, 0_u64), |(wake_count, run_count), agent_id| {
                let agent = self
                    .store
                    .agent_instance(&agent_id)?
                    .ok_or_else(|| format!("owned agent '{agent_id}' disappeared"))?;
                let wakes = self
                    .event_store
                    .count_agent_wakes_for_session(&agent.session_id)
                    .map_err(|error| error.to_string())?;
                let uncovered_run = wakes == 0
                    && !assignment_run_agents.contains(&agent_id)
                    && self
                        .orchestrator
                        .has_pending_or_active_run(&agent.session_id);
                Ok::<(u64, u64), String>((
                    wake_count.saturating_add(wakes),
                    run_count.saturating_add(u64::from(uncovered_run)),
                ))
            })?;
        Ok(execution_count
            .saturating_add(wake_count)
            .saturating_add(uncovered_run_count))
    }
}
