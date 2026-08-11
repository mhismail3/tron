//! Paged native reads and the canonical server-authored agent projections.

use super::*;

impl WorkerRuntime {
    pub(crate) async fn client_agent_relations(
        &self,
        invocation: &Invocation,
    ) -> Result<Value, String> {
        let scope = self.client_agent_scope(invocation).await?;
        let offset =
            decode_offset_cursor(invocation.payload.get("cursor").and_then(Value::as_str))?;
        let limit = client_limit(&invocation.payload, 50);
        let related_ids = scope
            .related_ids
            .iter()
            .filter(|agent_id| *agent_id != &scope.owner.agent_id)
            .cloned()
            .collect::<Vec<_>>();
        let page = self.store.agent_relationship_page(
            &scope.owner.agent_id,
            &related_ids,
            offset,
            limit,
        )?;
        let mut items = Vec::new();
        for agent in &page.items {
            items.push(self.client_relation_json(&scope, agent)?);
        }
        let next = offset.saturating_add(items.len());
        Ok(json!({
            "totals":{"active":page.active,"related":page.total},
            "items":items,
            "nextCursor":(u64::try_from(next).unwrap_or(u64::MAX) < page.total).then(|| format!("offset:{next}")),
        }))
    }

    pub(crate) async fn client_agent_inspect(
        &self,
        invocation: &Invocation,
    ) -> Result<Value, String> {
        let scope = self.client_agent_scope(invocation).await?;
        let agent_id = required_client_string(&invocation.payload, "agentId")?;
        let agent = self.require_scoped_agent(&scope, &agent_id)?;
        self.client_agent_inspect_json(&scope, agent)
    }

    pub(crate) async fn client_agent_assignments(
        &self,
        invocation: &Invocation,
    ) -> Result<Value, String> {
        let scope = self.client_agent_scope(invocation).await?;
        let agent_id = required_client_string(&invocation.payload, "agentId")?;
        let agent = self.require_scoped_agent(&scope, &agent_id)?;
        let offset =
            decode_offset_cursor(invocation.payload.get("cursor").and_then(Value::as_str))?;
        let limit = client_limit(&invocation.payload, 40);
        let page = self
            .store
            .agent_assignment_history_page(&agent.agent_id, offset, limit)?;
        let usage = self.assignment_usage_by_id(
            agent,
            page.items
                .iter()
                .map(|assignment| assignment.assignment_id.as_str()),
        )?;
        let items = page
            .items
            .iter()
            .map(|assignment| {
                self.client_assignment_json(
                    &scope,
                    assignment,
                    usage.get(&assignment.assignment_id),
                )
            })
            .collect::<Result<Vec<_>, _>>()?;
        let next = offset.saturating_add(items.len());
        Ok(json!({
            "items":items,
            "nextCursor":(u64::try_from(next).unwrap_or(u64::MAX) < page.total).then(|| format!("offset:{next}")),
        }))
    }

    pub(crate) async fn client_agent_messages(
        &self,
        invocation: &Invocation,
    ) -> Result<Value, String> {
        let scope = self.client_agent_scope(invocation).await?;
        let agent_id = required_client_string(&invocation.payload, "agentId")?;
        let agent = self.require_scoped_agent(&scope, &agent_id)?;
        let before =
            decode_message_cursor(invocation.payload.get("cursor").and_then(Value::as_str))?;
        let limit = client_limit(&invocation.payload, 50);
        let messages = self
            .event_store
            .list_agent_messages_for_participant(
                &agent.agent_id,
                before
                    .as_ref()
                    .map(|(created_at, message_id)| (created_at.as_str(), message_id.as_str())),
                limit.saturating_add(1),
            )
            .map_err(|error| error.to_string())?;
        let has_more = messages.len() > limit;
        let page = messages.into_iter().take(limit).collect::<Vec<_>>();
        let items = page
            .iter()
            .map(|message| client_message_summary(&scope, agent, message))
            .collect::<Vec<_>>();
        let next_cursor = has_more
            .then(|| page.last())
            .flatten()
            .map(|message| encode_message_cursor(&message.created_at, &message.message_id));
        Ok(json!({"items":items,"nextCursor":next_cursor}))
    }

    pub(crate) async fn client_agent_message_detail(
        &self,
        invocation: &Invocation,
    ) -> Result<Value, String> {
        let scope = self.client_agent_scope(invocation).await?;
        let agent_id = required_client_string(&invocation.payload, "agentId")?;
        let agent = self.require_scoped_agent(&scope, &agent_id)?;
        let message_id = required_client_string(&invocation.payload, "messageId")?;
        let message = self
            .event_store
            .agent_message_metadata(&message_id)
            .map_err(|error| error.to_string())?
            .ok_or_else(|| format!("agent message '{message_id}' was not found"))?;
        if message.source_agent_id != agent.agent_id && message.target_agent_id != agent.agent_id {
            return Err(format!(
                "agent message '{message_id}' is outside agent '{}' communication history",
                agent.agent_id
            ));
        }
        Ok(client_message_detail(&scope, agent, &message))
    }

    pub(crate) async fn client_agent_result_read(
        &self,
        invocation: &Invocation,
    ) -> Result<Value, String> {
        let scope = self.client_agent_scope(invocation).await?;
        let agent_id = required_client_string(&invocation.payload, "agentId")?;
        let _ = self.require_scoped_agent(&scope, &agent_id)?;
        let result_id = required_client_string(&invocation.payload, "resultId")?;
        let result = self
            .store
            .agent_result(&result_id)?
            .ok_or_else(|| format!("agent result '{result_id}' was not found"))?;
        if result.agent_id != agent_id {
            return Err(format!(
                "agent result '{result_id}' does not belong to agent '{agent_id}'"
            ));
        }
        let pointer = invocation
            .payload
            .get("pointer")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let offset = invocation
            .payload
            .get("offset")
            .and_then(Value::as_u64)
            .and_then(|value| usize::try_from(value).ok())
            .unwrap_or_default();
        let limit = invocation
            .payload
            .get("limit")
            .and_then(Value::as_u64)
            .and_then(|value| usize::try_from(value).ok())
            .unwrap_or(20)
            .clamp(1, 20);
        self.read_agent_assignment_result(invocation, &result.assignment_id, pointer, offset, limit)
            .await
    }

    fn client_relation_json(
        &self,
        scope: &ClientAgentScope,
        agent: &AgentInstanceRecord,
    ) -> Result<Value, String> {
        let relation = relationship(&scope.owner, agent, &scope.agents);
        let preferred = self.store.preferred_agent_assignment(&agent.agent_id)?;
        let latest = self
            .store
            .agent_assignment_history_page(&agent.agent_id, 0, 1)?;
        let current = preferred.as_ref().or(latest.items.first());
        let trace_pause = current
            .map(|assignment| self.assignment_trace_pause(assignment))
            .transpose()?
            .flatten();
        let messages = self
            .event_store
            .list_agent_messages_for_participant(&agent.agent_id, None, 1)
            .map_err(|error| error.to_string())?;
        let session = self
            .event_store
            .get_session(&agent.session_id)
            .map_err(|error| error.to_string())?;
        let own_usage = session.as_ref().map(session_usage_json);
        let subtree_usage = self.subtree_usage_json(agent, &scope.agents)?;
        Ok(json!({
            "agentId":agent.agent_id,
            "relationship":relation.name,
            "parentAgentId":agent.management_owner_agent_id,
            "depth":relation.depth,
            "status":if trace_pause.is_some() {"autonomy_paused"} else {current.map_or(agent.state.as_str(), |assignment| assignment.status.as_str())},
            "statusDetail":trace_pause.as_ref().map(|state| state.reason.as_str()).or_else(|| current.and_then(|assignment| assignment.error.as_deref())),
            "name":agent.name,
            "role":agent.role_id.as_deref().unwrap_or(agent.kind.as_str()),
            "taskPreview":current.map(|assignment| bounded_preview(&assignment.task, 300)),
            "lastActivityAt":session.as_ref().map_or(agent.updated_at.as_str(), |row| row.last_activity_at.as_str()),
            "lastMessagePreview":messages.first().map(|message| bounded_preview(&message.content.text, 180)),
            "ownUsage":own_usage,
            "subtreeUsage":subtree_usage,
            "resultState":current.map(|assignment| assignment.status.as_str()),
            "transcriptSessionId":agent.session_id,
            "allowedActions":self.client_allowed_actions(&scope.owner, agent, current)?,
        }))
    }

    pub(super) fn client_agent_inspect_json(
        &self,
        scope: &ClientAgentScope,
        agent: &AgentInstanceRecord,
    ) -> Result<Value, String> {
        let relation = relationship(&scope.owner, agent, &scope.agents);
        let latest_history = self
            .store
            .agent_assignment_history_page(&agent.agent_id, 0, 1)?;
        let current_assignment = self.store.preferred_agent_assignment(&agent.agent_id)?;
        let current = current_assignment.as_ref();
        let latest = current.or(latest_history.items.first());
        let trace_pause = latest
            .map(|assignment| self.assignment_trace_pause(assignment))
            .transpose()?
            .flatten();
        let role_update = agent.role_id.as_deref().is_some_and(|role_id| {
            self.store
                .load_indexed_active(role_id)
                .ok()
                .is_some_and(|active| {
                    super::coordination::is_executable_agent_role(
                        &active.summary,
                        active.bundle.agent_role.as_ref(),
                    ) && active.summary.active_version
                        != agent.role_version.clone().unwrap_or_default()
                })
        });
        let role = json!({
            "roleId":agent.role_id,
            "name":agent.role_id.as_deref().unwrap_or("General agent"),
            "summary":if agent.role_id.is_some() {"Pinned immutable dynamic-worker role"} else {"General reusable Tron agent"},
            "workerId":agent.role_id,
            "workerVersion":agent.role_version,
            "updateAvailable":role_update,
        });
        let grants = string_values(&agent.tool_grant)
            .into_iter()
            .map(|function_id| {
                json!({
                    "functionId":function_id,
                    "delegation":"effective",
                    "workspaceEffect":Value::Null,
                })
            })
            .collect::<Vec<_>>();
        let limits = agent
            .limits
            .as_object()
            .into_iter()
            .flatten()
            .map(|(name, limit)| {
                let (display_name, display_limit, unit) = match name.as_str() {
                    "maxAssignmentTurns" => ("max_turns", limit.as_f64(), Some("turns")),
                    "maxAssignmentSeconds" => (
                        "max_minutes",
                        limit.as_f64().map(|seconds| seconds / 60.0),
                        Some("minutes"),
                    ),
                    _ => (name.as_str(), limit.as_f64(), limit_unit(name)),
                };
                json!({
                    "name":display_name,
                    "used":Value::Null,
                    "limit":display_limit,
                    "unit":unit,
                })
            })
            .collect::<Vec<_>>();
        let claims = self.store.list_workspace_claims(
            Some(&agent.agent_id),
            None,
            true,
            MAX_CLIENT_AUDIT_ITEMS,
        )?;
        let write_scopes = string_values(&agent.write_scopes)
            .into_iter()
            .map(|path| {
                let claim = claims.iter().find(|claim| claim.canonical_scope == path);
                json!({
                    "path":path,
                    "state":claim.map_or("available", |claim| claim.state.as_str()),
                    "detail":claim.map(|claim| format!("{} · {}", claim.kind.as_str(), claim.claim_id)),
                })
            })
            .collect::<Vec<_>>();
        let lineage = lineage_json(agent, &scope.agents);
        let contacts = self
            .all_agent_correspondents(&agent.agent_id)?
            .into_iter()
            .filter_map(|contact| scope.agents.get(&contact.agent_id))
            .map(|contact| {
                let relation = relationship(agent, contact, &scope.agents);
                json!({
                    "agentId":contact.agent_id,
                    "name":contact.name,
                    "relationship":relation.name,
                    "status":contact.state.as_str(),
                })
            })
            .collect::<Vec<_>>();
        let session = self
            .event_store
            .get_session(&agent.session_id)
            .map_err(|error| error.to_string())?;
        let own_usage = session.as_ref().map(session_usage_json);
        let subtree_usage = self.subtree_usage_json(agent, &scope.agents)?;
        let result = latest.map(assignment_result_summary);
        let attempts = latest
            .map(|assignment| {
                self.store.list_agent_assignment_attempts(
                    &assignment.assignment_id,
                    MAX_CLIENT_AUDIT_ITEMS,
                )
            })
            .transpose()?
            .unwrap_or_default();
        let execution_events = latest
            .map(|assignment| {
                self.store.list_agent_execution_events(
                    &assignment.execution_id,
                    None,
                    MAX_CLIENT_AUDIT_ITEMS,
                )
            })
            .transpose()?
            .unwrap_or_default();
        let current_usage = self.assignment_usage_by_id(
            agent,
            current
                .into_iter()
                .map(|assignment| assignment.assignment_id.as_str()),
        )?;
        let management_grants = self.store.list_agent_management_grants_for_subtree(
            &agent.agent_id,
            true,
            MAX_CLIENT_AUDIT_ITEMS,
        )?;
        let waits = self
            .event_store
            .list_coordination_waits(&agent.session_id, MAX_CLIENT_AUDIT_ITEMS)
            .map_err(|error| error.to_string())?;
        Ok(json!({
            "agentId":agent.agent_id,
            "name":agent.name,
            "relationship":relation.name,
            "status":if trace_pause.is_some() {"autonomy_paused"} else {latest.map_or(agent.state.as_str(), |assignment| assignment.status.as_str())},
            "statusDetail":trace_pause.as_ref().map(|state| state.reason.as_str()).or_else(|| latest.and_then(|assignment| assignment.error.as_deref())),
            "taskPreview":latest.map(|assignment| bounded_preview(&assignment.task, 500)),
            "transcriptSessionId":agent.session_id,
            "currentAssignment":current.map(|assignment| self.client_assignment_json(scope, assignment, current_usage.get(&assignment.assignment_id))).transpose()?,
            "role":role,
            "grants":grants,
            "limits":limits,
            "writeScopes":write_scopes,
            "lineage":lineage,
            "contacts":contacts,
            "ownUsage":own_usage,
            "subtreeUsage":subtree_usage,
            "result":result,
            "technical":{
                "agentId":agent.agent_id,
                "transcriptSessionId":agent.session_id,
                "rootSessionId":agent.root_session_id,
                "workspaceId":agent.workspace_id,
                "spawnedByAgentId":agent.spawned_by_agent_id,
                "managementOwnerAgentId":agent.management_owner_agent_id,
                "roleVersion":agent.role_version,
                "visibility":agent.visibility.as_str(),
                "assignmentAttempts":attempts,
                "executionEvents":execution_events,
                "managementGrants":management_grants,
                "workspaceClaims":claims,
                "coordinationWaits":waits,
                "coordinationTraceState":trace_pause,
                "createdAt":agent.created_at,
                "updatedAt":agent.updated_at,
            },
            "allowedActions":self.client_allowed_actions(&scope.owner, agent, latest)?,
        }))
    }

    fn client_assignment_json(
        &self,
        scope: &ClientAgentScope,
        assignment: &AgentAssignmentRecord,
        usage: Option<&UsageTotals>,
    ) -> Result<Value, String> {
        let requester = assignment
            .requester_agent_id
            .as_deref()
            .and_then(|id| scope.agents.get(id));
        let retry_status_enabled = matches!(
            assignment.status,
            AgentAssignmentStatus::Failed
                | AgentAssignmentStatus::Cancelled
                | AgentAssignmentStatus::TimedOut
                | AgentAssignmentStatus::Expired
                | AgentAssignmentStatus::Declined
        );
        let retry_enabled = retry_status_enabled
            && scope.agents.get(&assignment.agent_id).is_some_and(|agent| {
                self.store
                    .has_agent_management(
                        &scope.owner.agent_id,
                        &agent.agent_id,
                        AgentManagementCapability::Assign,
                    )
                    .unwrap_or(false)
            });
        let trace_pause = self.assignment_trace_pause(assignment)?;
        Ok(json!({
            "assignmentId":assignment.assignment_id,
            "executionId":assignment.execution_id,
            "kind":assignment.kind.as_str(),
            "status":if trace_pause.is_some() {"autonomy_paused"} else {assignment.status.as_str()},
            "task":assignment.task,
            "requesterName":requester.map(|agent| agent.name.as_str()),
            "requesterAgentId":assignment.requester_agent_id,
            "queuePosition":assignment.queue_ordinal,
            "createdAt":assignment.created_at,
            "startedAt":assignment.started_at,
            "completedAt":assignment.completed_at,
            "retryOf":assignment.retry_of_assignment_id,
            "failure":trace_pause.as_ref().map(|state| state.reason.as_str()).or(assignment.error.as_deref()),
            "usage":usage.map(UsageTotals::as_json),
            "result":assignment_result_summary(assignment),
            "allowedActions":[allowed_action(
                "retry",
                retry_enabled,
                (!retry_enabled).then_some(if retry_status_enabled {
                    "The selected session has no assignment authority for this agent"
                } else {
                    "Only terminal unsuccessful assignments can be retried"
                }),
            )],
        }))
    }

    fn assignment_trace_pause(
        &self,
        assignment: &AgentAssignmentRecord,
    ) -> Result<Option<CoordinationTraceStateRecord>, String> {
        let Some(execution) = self.store.execution_node(&assignment.execution_id)? else {
            return Ok(None);
        };
        Ok(self
            .store
            .coordination_trace_state(&execution.trace_id)?
            .filter(|state| state.paused))
    }

    fn client_allowed_actions(
        &self,
        owner: &AgentInstanceRecord,
        target: &AgentInstanceRecord,
        assignment: Option<&AgentAssignmentRecord>,
    ) -> Result<Vec<Value>, String> {
        let is_closed = target.state == AgentInstanceState::Closed;
        let is_idle = target.state == AgentInstanceState::Idle;
        let subtree_ids = self.store.agent_owned_subtree_ids(&target.agent_id)?;
        let subtree_agents = subtree_ids
            .iter()
            .map(|agent_id| {
                self.store
                    .agent_instance(agent_id)?
                    .ok_or_else(|| format!("owned agent '{agent_id}' disappeared"))
            })
            .collect::<Result<Vec<_>, String>>()?;
        let subtree_active = subtree_agents.iter().any(|candidate| {
            !matches!(
                candidate.state,
                AgentInstanceState::Idle | AgentInstanceState::Closed
            )
        });
        let target_has_claims = !self
            .store
            .list_workspace_claims(Some(&target.agent_id), None, false, 1)?
            .is_empty();
        let target_has_waits = self
            .event_store
            .has_pending_coordination_wait_for_agent(&target.agent_id)
            .map_err(|error| error.to_string())?;
        let target_has_run = self
            .orchestrator
            .has_pending_or_active_run(&target.session_id);
        let subtree_has_claims = subtree_agents.iter().try_fold(false, |found, candidate| {
            if found {
                Ok(true)
            } else {
                self.store
                    .list_workspace_claims(Some(&candidate.agent_id), None, false, 1)
                    .map(|claims| !claims.is_empty())
            }
        })?;
        let subtree_has_waits = subtree_ids.iter().try_fold(false, |found, agent_id| {
            if found {
                Ok(true)
            } else {
                self.event_store
                    .has_pending_coordination_wait_for_agent(agent_id)
                    .map_err(|error| error.to_string())
            }
        })?;
        let subtree_has_run = subtree_agents.iter().any(|candidate| {
            self.orchestrator
                .has_pending_or_active_run(&candidate.session_id)
        });
        let subtree_has_wakes = subtree_agents.iter().try_fold(false, |found, candidate| {
            if found {
                Ok::<bool, String>(true)
            } else {
                self.event_store
                    .count_agent_wakes_for_session(&candidate.session_id)
                    .map(|count| count > 0)
                    .map_err(|error| error.to_string())
            }
        })?;
        let target_quiescent =
            is_idle && !target_has_claims && !target_has_waits && !target_has_run;
        let subtree_quiescent = is_idle
            && !subtree_active
            && !subtree_has_claims
            && !subtree_has_waits
            && !subtree_has_run;
        let cancellable_work_count = self.client_cancellable_work_count(&target.agent_id)?;
        let has_assign_authority = self.store.has_agent_management(
            &owner.agent_id,
            &target.agent_id,
            AgentManagementCapability::Assign,
        )?;
        let can_assign = !is_closed && has_assign_authority;
        let has_cancel_authority = self.store.has_agent_management(
            &owner.agent_id,
            &target.agent_id,
            AgentManagementCapability::Cancel,
        )?;
        let can_cancel = !is_closed && has_cancel_authority;
        let has_configure_authority = self.store.has_agent_management(
            &owner.agent_id,
            &target.agent_id,
            AgentManagementCapability::Configure,
        )?;
        let is_management_ancestor = self
            .store
            .agent_is_management_ancestor(&owner.agent_id, &target.agent_id)?;
        let can_delegate_management = !is_closed && is_management_ancestor;
        let can_configure = target_quiescent && has_configure_authority;
        let has_close_authority = self.store.has_agent_management(
            &owner.agent_id,
            &target.agent_id,
            AgentManagementCapability::Close,
        )?;
        let can_close = subtree_quiescent
            && target.kind != crate::domains::worker_kernel::persistence::AgentInstanceKind::Root
            && has_close_authority;
        let update_available = target.role_id.as_deref().is_some_and(|role_id| {
            self.store
                .load_indexed_active(role_id)
                .ok()
                .is_some_and(|active| {
                    super::coordination::is_executable_agent_role(
                        &active.summary,
                        active.bundle.agent_role.as_ref(),
                    ) && Some(active.summary.active_version.as_str())
                        != target.role_version.as_deref()
                })
        });
        Ok(vec![
            allowed_action(
                "operator_message",
                can_assign,
                (!can_assign).then_some(if is_closed {
                    "Closed agents retain audit history but cannot receive work"
                } else {
                    "The selected session has no assignment authority for this agent"
                }),
            ),
            allowed_action_with_count(
                "cancel",
                can_cancel
                    && (subtree_active
                        || subtree_has_run
                        || subtree_has_wakes
                        || assignment.is_some_and(|value| !value.status.is_terminal())),
                if is_closed {
                    Some("Closed agents have no cancellable work")
                } else if !has_cancel_authority {
                    Some("The selected session has no cancellation authority")
                } else if !subtree_active
                    && !subtree_has_run
                    && !subtree_has_wakes
                    && assignment.is_none_or(|value| value.status.is_terminal())
                {
                    Some("No active assignment or descendant workload is available to cancel")
                } else {
                    None
                },
                Some(cancellable_work_count),
            ),
            allowed_action(
                "configure",
                can_configure,
                if is_closed {
                    Some("Closed agents cannot be reconfigured")
                } else if !has_configure_authority {
                    Some("The selected session has no configuration authority for this agent")
                } else if !target_quiescent {
                    Some(
                        "Configuration requires an idle agent with no transcript run, waits, or resource claims",
                    )
                } else {
                    None
                },
            ),
            allowed_action(
                "grant_management",
                can_delegate_management,
                if is_closed {
                    Some("Closed agents cannot receive management changes")
                } else if !is_management_ancestor {
                    Some("Management grants require owning-ancestor authority")
                } else {
                    None
                },
            ),
            allowed_action(
                "revoke_management",
                can_delegate_management,
                if is_closed {
                    Some("Closed agents cannot receive management changes")
                } else if !is_management_ancestor {
                    Some("Management grants require owning-ancestor authority")
                } else {
                    None
                },
            ),
            allowed_action(
                "upgrade_role",
                can_configure && update_available,
                if is_closed {
                    Some("Closed agents cannot upgrade roles")
                } else if !has_configure_authority {
                    Some("The selected session has no configuration authority for this agent")
                } else if !target_quiescent {
                    Some(
                        "Role upgrades require an idle agent with no transcript run, waits, or resource claims",
                    )
                } else if !update_available {
                    Some("No reviewed role update is available")
                } else {
                    None
                },
            ),
            allowed_action(
                "promote",
                subtree_quiescent && target.visibility == AgentVisibility::Nested && can_configure,
                if is_closed {
                    Some("Closed agents cannot be promoted")
                } else if target.visibility != AgentVisibility::Nested {
                    Some("Only nested agents can be promoted into Sessions")
                } else if !has_configure_authority {
                    Some("The selected session has no configuration authority for this agent")
                } else if !subtree_quiescent {
                    Some(
                        "Promotion requires a quiescent agent, idle descendants, and no transcript runs, active waits, or claims",
                    )
                } else {
                    None
                },
            ),
            allowed_action(
                "close",
                can_close,
                if is_closed {
                    Some("Agent is already closed")
                } else if target.kind
                    == crate::domains::worker_kernel::persistence::AgentInstanceKind::Root
                {
                    Some("Visible root agents cannot be closed through nested-agent management")
                } else if !has_close_authority {
                    Some("The selected session has no close authority for this agent")
                } else if !subtree_quiescent {
                    Some(
                        "Close requires a quiescent agent, idle descendants, and no transcript runs, active waits, or claims",
                    )
                } else {
                    None
                },
            ),
        ])
    }
}
