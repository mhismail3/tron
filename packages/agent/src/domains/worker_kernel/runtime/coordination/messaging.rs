//! Durable semantic messaging and generalized wait admission.

use super::*;

impl WorkerRuntime {
    /// Send one durable semantic message and, for work-bearing kinds, admit a
    /// distinct assignment before scheduling the recipient. The two stores are
    /// joined only by stable preallocated ids and idempotent outboxes.
    pub(crate) async fn agent_send(&self, invocation: &Invocation) -> Result<Value, String> {
        if invocation.payload.get("target").is_some() {
            return self.legacy_agent_send(invocation).await;
        }
        let (caller, source_session) = self.resolve_calling_agent(invocation).await?;
        let target_id = match required_coordination_string(&invocation.payload, "to")?.as_str() {
            "parent" => caller.management_owner_agent_id.clone().ok_or_else(|| {
                "agents without a management owner do not have a parent address".to_owned()
            })?,
            target => target.to_owned(),
        };
        let target = self
            .store
            .agent_instance(&target_id)?
            .ok_or_else(|| format!("agent '{target_id}' was not found"))?;
        if target.state == AgentInstanceState::Closed {
            return Err(format!("agent '{target_id}' is closed"));
        }
        let kind_name = required_coordination_string(&invocation.payload, "kind")?;
        let kind = parse_agent_message_kind(&kind_name)?;
        let is_operator = invocation.causal_context.actor_kind == ActorKind::Client;
        let autonomous_hop = if is_operator {
            0
        } else {
            invocation
                .causal_context
                .autonomous_wake_hop()
                .saturating_add(1)
        };
        if is_operator && kind != AgentMessageKind::Instruction {
            return Err(
                "authenticated operator messages must use instruction semantics".to_owned(),
            );
        }
        let text = required_coordination_string(&invocation.payload, "content")?;
        let supplied_assignment_id =
            optional_coordination_string(&invocation.payload, "assignmentId")?;
        let reply_to = optional_coordination_string(&invocation.payload, "replyTo")?;
        if matches!(
            kind,
            AgentMessageKind::Instruction | AgentMessageKind::Request
        ) && supplied_assignment_id.is_some()
        {
            return Err(
                "instructions and requests create a new assignment; use update for existing work"
                    .to_owned(),
            );
        }
        if kind == AgentMessageKind::Answer && reply_to.is_none() {
            return Err("agent answers require replyTo".to_owned());
        }
        if kind != AgentMessageKind::Answer && reply_to.is_some() {
            return Err("replyTo is reserved for agent answers".to_owned());
        }
        let answered_question = if let Some(reply_to) = reply_to.as_deref() {
            let question = self
                .event_store
                .agent_message_metadata(reply_to)
                .map_err(|error| error.to_string())?
                .ok_or_else(|| format!("agent question '{reply_to}' was not found"))?;
            if question.kind != AgentMessageKind::Question
                || question.source_agent_id != target.agent_id
                || question.target_agent_id != caller.agent_id
            {
                return Err(
                    "agent answer must reference the exact question and sender/recipient pair"
                        .to_owned(),
                );
            }
            Some(question)
        } else {
            None
        };
        if let Some(question) = answered_question.as_ref()
            && supplied_assignment_id.is_some()
            && supplied_assignment_id.as_deref() != question.assignment_id.as_deref()
        {
            return Err("agent answer assignmentId must match the referenced question".to_owned());
        }
        let can_assign = self.store.has_agent_management(
            &caller.agent_id,
            &target.agent_id,
            AgentManagementCapability::Assign,
        )?;
        if kind == AgentMessageKind::Instruction && !can_assign {
            return Err(format!(
                "agent '{}' has no assign authority over '{}'",
                caller.agent_id, target.agent_id
            ));
        }
        let authority = if is_operator {
            AgentMessageAuthority::Operator
        } else if can_assign {
            AgentMessageAuthority::Owner
        } else {
            AgentMessageAuthority::Peer
        };
        let operation_identity = if is_operator {
            invocation
                .payload
                .get("clientMutationId")
                .and_then(Value::as_str)
                .unwrap_or_else(|| invocation.id.as_str())
        } else {
            invocation.id.as_str()
        };
        let message_id = format!("agent_message_{operation_identity}");
        let mut participants = [caller.agent_id.as_str(), target.agent_id.as_str()];
        participants.sort_unstable();
        let channel_id = format!("agent_channel:{}:{}", participants[0], participants[1]);

        let operator_active_assignment = if is_operator && target.state != AgentInstanceState::Idle
        {
            self.store
                .list_agent_assignments(&target.agent_id, 16)?
                .into_iter()
                .filter(|assignment| !assignment.status.is_terminal())
                .min_by_key(|assignment| match assignment.status {
                    AgentAssignmentStatus::Running | AgentAssignmentStatus::Waiting => 0,
                    AgentAssignmentStatus::Accepted | AgentAssignmentStatus::Queued => 1,
                    AgentAssignmentStatus::Offered => 2,
                    _ => 3,
                })
        } else {
            None
        };
        let target_tool_grant = json!(self.effective_agent_tool_names(&target).await?);
        if let Some(active) = operator_active_assignment.as_ref()
            && let Some(execution) = self.store.execution_node(&active.execution_id)?
        {
            // Authenticated operator input is the only automatic-resume source
            // and begins a fresh autonomous-hop chain.
            let _ = self.store.resume_coordination_trace(&execution.trace_id)?;
        }
        let creates_assignment = matches!(
            kind,
            AgentMessageKind::Instruction | AgentMessageKind::Request
        ) && operator_active_assignment.is_none();
        let assignment = if creates_assignment {
            let coordination = &self.settings_runtime.current().settings.agent.coordination;
            let offered = kind == AgentMessageKind::Request;
            let limits = target.limits.clone();
            let deadline_at = limits
                .get("maxAssignmentSeconds")
                .and_then(Value::as_u64)
                .and_then(|seconds| chrono::Duration::try_seconds(i64::try_from(seconds).ok()?))
                .map(|duration| (chrono::Utc::now() + duration).to_rfc3339());
            let parent_execution_id = causal_parent_execution_id(invocation);
            let max_child_executions = self.effective_direct_child_execution_ceiling(
                invocation,
                &caller,
                coordination.max_execution_nodes,
            )?;
            let (assignment, _) = self.store.enqueue_agent_assignment(&NewAgentAssignment {
                admission_key: format!("agent-send-assignment:{operation_identity}"),
                agent_id: target.agent_id.clone(),
                requester_agent_id: Some(caller.agent_id.clone()),
                delegator_agent_id: can_assign.then(|| caller.agent_id.clone()),
                kind: if is_operator {
                    AgentAssignmentKind::Operator
                } else if kind == AgentMessageKind::Instruction {
                    AgentAssignmentKind::Instruction
                } else {
                    AgentAssignmentKind::Request
                },
                offered,
                task: text.clone(),
                context: self
                    .assignment_context_for_agent(&target, json!({"messageKind":kind_name}))?,
                parent_execution_id,
                trace_id: invocation.causal_context.trace_id.as_str().to_owned(),
                causal_depth: child_execution_depth(invocation),
                child_slot: invocation.causal_context.origin_worker_tool_ordinal(),
                model: target.default_model.clone(),
                reasoning_level: target.default_reasoning_level.clone(),
                authority_snapshot: target_tool_grant,
                resource_snapshot: json!({"workspaceId":target.workspace_id}),
                write_scopes_snapshot: target.write_scopes.clone(),
                limits_snapshot: limits,
                retry_of_assignment_id: None,
                deadline_at,
                max_active_children: coordination.max_active_children,
                max_child_executions,
                max_execution_nodes: coordination.max_execution_nodes,
                max_causal_depth: coordination.max_causal_depth,
                max_queued_assignments: self
                    .effective_agent_queue_ceiling(&target, coordination.max_queued_assignments),
                message: NewAgentAssignmentMessage {
                    deduplication_key: format!("agent-message:{operation_identity}"),
                    message_id: message_id.clone(),
                    channel_id: channel_id.clone(),
                    source_agent_id: caller.agent_id.clone(),
                    source_session_id: source_session.id.clone(),
                    source_name: Some(caller.name.clone()),
                    target_session_id: target.session_id.clone(),
                    kind,
                    authority,
                    reply_to: reply_to.clone(),
                    text: text.clone(),
                    autonomous_hop,
                },
            })?;
            Some(assignment)
        } else {
            None
        };
        let assignment_id = assignment
            .as_ref()
            .map(|record| record.assignment_id.clone())
            .or_else(|| {
                operator_active_assignment
                    .as_ref()
                    .map(|record| record.assignment_id.clone())
            })
            .or(supplied_assignment_id)
            .or_else(|| {
                answered_question
                    .as_ref()
                    .and_then(|question| question.assignment_id.clone())
            });
        let mut linked_information_actionable = false;
        if assignment.is_none()
            && let Some(assignment_id) = assignment_id.as_deref()
        {
            let existing = self
                .store
                .agent_assignment(assignment_id)?
                .ok_or_else(|| format!("agent assignment '{assignment_id}' was not found"))?;
            let caller_is_assignee = existing.agent_id == caller.agent_id;
            let target_is_assignee = existing.agent_id == target.agent_id;
            let caller_is_requester = existing.requester_agent_id.as_deref()
                == Some(&caller.agent_id)
                || existing.delegator_agent_id.as_deref() == Some(&caller.agent_id);
            let target_is_requester = existing.requester_agent_id.as_deref()
                == Some(&target.agent_id)
                || existing.delegator_agent_id.as_deref() == Some(&target.agent_id);
            let caller_manages_assignee = target_is_assignee
                && self.store.has_agent_management(
                    &caller.agent_id,
                    &existing.agent_id,
                    AgentManagementCapability::Assign,
                )?;
            if !((caller_is_assignee && target_is_requester)
                || (target_is_assignee && (caller_is_requester || caller_manages_assignee)))
            {
                return Err(
                    "agent message is outside the exact assignment participant relationship"
                        .to_owned(),
                );
            }
            if kind == AgentMessageKind::Update && existing.status.is_terminal() {
                return Err("terminal agent assignments cannot receive updates".to_owned());
            }
            linked_information_actionable = kind == AgentMessageKind::Information
                && target_is_assignee
                && !existing.status.is_terminal();
        }
        if kind == AgentMessageKind::Update && assignment_id.is_none() {
            return Err("agent updates require assignmentId".to_owned());
        }

        let actionable = matches!(
            kind,
            AgentMessageKind::Instruction
                | AgentMessageKind::Request
                | AgentMessageKind::Question
                | AgentMessageKind::Answer
                | AgentMessageKind::Update
        ) || linked_information_actionable;
        if assignment.is_none() {
            let (_outbox, _created) = self.store.enqueue_agent_message_outbox(
                &NewAgentMessageOutbox {
                    deduplication_key: format!("agent-message:{operation_identity}"),
                    source_agent_id: caller.agent_id.clone(),
                    target_agent_id: target.agent_id.clone(),
                    assignment_id: assignment_id.clone(),
                    payload: json!({
                        "messageId":message_id,
                        "channelId":channel_id,
                        "kind":serde_json::to_value(kind).map_err(|error| error.to_string())?,
                        "authority":serde_json::to_value(authority).map_err(|error| error.to_string())?,
                        "text":text,
                        "sourceName":caller.name,
                        "sourceSessionId":source_session.id,
                        "targetSessionId":target.session_id,
                        "replyTo":reply_to,
                        "actionable":actionable,
                        "expiresAt":assignment.as_ref().and_then(|record| record.deadline_at.as_deref()),
                        "sourceInvocationId":invocation.id.as_str(),
                        "traceId":invocation.causal_context.trace_id.as_str(),
                        "causalDepth":child_execution_depth(invocation),
                        "autonomousHop":autonomous_hop,
                    }),
                },
            )?;
        }
        let _ = self.import_agent_coordination_outbox().await;
        self.delivery_maintenance.notify_one();
        let autonomous_hop_exceeded = !is_operator
            && autonomous_hop
                > self
                    .settings_runtime
                    .current()
                    .settings
                    .agent
                    .coordination
                    .max_autonomous_wake_hops;
        if autonomous_hop_exceeded
            && !self
                .store
                .coordination_trace_is_paused(invocation.causal_context.trace_id.as_str())?
        {
            // The message outbox is already durable. Persist the scheduler
            // guard even if the best-effort transcript importer needs a
            // retry; its later pause/notification path is idempotent.
            self.store.pause_coordination_trace_for_root(
                invocation.causal_context.trace_id.as_str(),
                &caller.root_session_id,
                &format!(
                    "autonomous coordination exceeded the {}-wake-hop ceiling",
                    self.settings_runtime
                        .current()
                        .settings
                        .agent
                        .coordination
                        .max_autonomous_wake_hops
                ),
            )?;
        }
        let autonomy_paused = autonomous_hop_exceeded
            || (!is_operator
                && self
                    .store
                    .coordination_trace_is_paused(invocation.causal_context.trace_id.as_str())?);
        Ok(json!({
            "messageId":message_id,
            "assignmentId":assignment_id,
            "disposition":if autonomy_paused {
                "autonomy_paused"
            } else { match assignment.as_ref().map(|record| record.status) {
                Some(AgentAssignmentStatus::Offered) => "offered",
                Some(AgentAssignmentStatus::Accepted | AgentAssignmentStatus::Queued) => "accepted",
                _ if actionable => "delivered",
                _ => "queued",
            }},
        }))
    }

    /// Register a durable fan-in and reconcile already-terminal handles after
    /// registration, closing completion-before-registration races without
    /// polling. Later terminal imports reuse the same reconciliation API.
    pub(crate) async fn agent_wait(&self, invocation: &Invocation) -> Result<Value, String> {
        let (caller, source_session) = self.resolve_calling_agent(invocation).await?;
        let mode = match invocation
            .payload
            .get("mode")
            .and_then(Value::as_str)
            .unwrap_or("all")
        {
            "all" => CoordinationWaitMode::All,
            "any" => CoordinationWaitMode::Any,
            other => return Err(format!("unsupported agent wait mode '{other}'")),
        };
        let target_values = invocation
            .payload
            .get("targets")
            .and_then(Value::as_array)
            .ok_or_else(|| "agent_wait requires targets".to_owned())?;
        let mut targets = Vec::with_capacity(target_values.len());
        for value in target_values {
            let kind = value
                .get("kind")
                .and_then(Value::as_str)
                .ok_or_else(|| "agent_wait target.kind is required".to_owned())?;
            let id = value
                .get("id")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|id| !id.is_empty())
                .ok_or_else(|| "agent_wait target.id is required".to_owned())?
                .to_owned();
            let target_kind = match kind {
                "assignment" => CoordinationTargetKind::AgentAssignment,
                "worker_invocation" => CoordinationTargetKind::WorkerInvocation,
                "reply" => CoordinationTargetKind::Reply,
                other => return Err(format!("unsupported agent wait target '{other}'")),
            };
            self.authorize_wait_target(&caller, &source_session.id, target_kind, &id)?;
            targets.push(CoordinationWaitTarget {
                kind: target_kind,
                id,
            });
        }
        let (owner_dependency_id, dependencies, dependency_edges) =
            self.resolve_coordination_wait_topology(&caller, invocation, &targets)?;
        let terminals = self.coordination_terminal_evidence(&caller, &targets)?;
        let admission = self
            .event_store
            .create_coordination_wait(
                &NewCoordinationWait {
                    idempotency_key: format!("agent-wait:{}", invocation.id),
                    session_id: source_session.id.clone(),
                    owner_agent_id: caller.agent_id.clone(),
                    owner_assignment_id: invocation
                        .causal_context
                        .agent_assignment_id()
                        .map(ToOwned::to_owned),
                    trace_id: invocation.causal_context.trace_id.as_str().to_owned(),
                    autonomous_hop: invocation.causal_context.autonomous_wake_hop(),
                    mode,
                    targets: targets.clone(),
                    owner_dependency_id,
                    dependencies,
                    dependency_edges,
                },
                &terminals,
            )
            .map_err(|error| error.to_string())?;
        let wait = &admission.wait;
        let resolved = admission.resolution.as_ref();
        let durably_satisfied = wait.disposition == "satisfied" || resolved.is_some();
        if !matches!(wait.disposition.as_str(), "pending" | "satisfied") {
            return Err(format!(
                "agent wait '{}' is {} and cannot be replayed",
                wait.wait_id, wait.disposition
            ));
        }
        let mut parked_assignment = false;
        if !durably_satisfied
            && let Some(assignment_id) = invocation.causal_context.agent_assignment_id()
            && let Some(assignment) = self.store.agent_assignment(assignment_id)?
            && assignment.status == AgentAssignmentStatus::Running
        {
            self.store
                .transition_agent_assignment(&AgentAssignmentTransition {
                    assignment_id: assignment.assignment_id,
                    expected_status: AgentAssignmentStatus::Running,
                    target_status: AgentAssignmentStatus::Waiting,
                    result: None,
                    error: None,
                })?;
            parked_assignment = true;
        }
        if parked_assignment {
            let current_wait = self
                .event_store
                .coordination_wait(&wait.wait_id)
                .map_err(|error| error.to_string())?
                .ok_or_else(|| format!("coordination wait '{}' disappeared", wait.wait_id))?;
            if current_wait.disposition != "pending" {
                // The terminal import may have committed after registration's
                // snapshot but before Running -> Waiting. Re-notify the
                // assignment dispatcher after the park commits; the aggregate
                // message stays passive and cannot wake the just-ending tool
                // run as an auxiliary provider turn.
                self.delivery_maintenance.notify_one();
            }
        }
        let completed_members = if let Some(resolution) = resolved {
            resolution.satisfied.clone()
        } else if wait.disposition == "satisfied" {
            self.event_store
                .coordination_wait_members(&wait.wait_id)
                .map_err(|error| error.to_string())?
                .into_iter()
                .filter(|member| member.disposition == "satisfied")
                .collect()
        } else {
            Vec::new()
        };
        let completed = completed_members
            .iter()
            .map(|member| serde_json::to_value(member).map_err(|error| error.to_string()))
            .collect::<Result<Vec<_>, _>>()?;
        if resolved.is_some() {
            metrics::counter!(
                "agent_coordination_wait_resolutions_total",
                "mode" => if mode == CoordinationWaitMode::All { "all" } else { "any" },
                "delivery" => "inline"
            )
            .increment(1);
        }
        Ok(json!({
            "waitId":wait.wait_id,
            "mode":if mode == CoordinationWaitMode::All {"all"} else {"any"},
            "targets":targets,
            "status":if durably_satisfied {"satisfied"} else {"pending"},
            "completedTargets":completed,
        }))
    }
}
