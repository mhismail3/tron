//! Trusted Team Context, stable identities, and delegated authority projection.

use super::*;

impl WorkerRuntime {
    /// Project the compact trusted roster inserted by the provider phase.
    pub(crate) async fn agent_team_context(
        &self,
        invocation: &Invocation,
    ) -> Result<Value, String> {
        let requested_session_id = invocation
            .payload
            .get("sessionId")
            .and_then(Value::as_str)
            .ok_or_else(|| "agent team context requires sessionId".to_owned())?;
        if invocation.causal_context.session_id.as_deref() != Some(requested_session_id) {
            return Err("agent team context session does not match engine provenance".to_owned());
        }
        let (caller, _) = self.resolve_calling_agent(invocation).await?;
        let limit = invocation
            .payload
            .get("limit")
            .and_then(Value::as_u64)
            .and_then(|value| usize::try_from(value).ok())
            .unwrap_or(MAX_TEAM_ENTRIES)
            .clamp(1, MAX_TEAM_ENTRIES);
        let parent_agent = caller
            .management_owner_agent_id
            .as_deref()
            .map(|parent_id| self.store.agent_instance(parent_id))
            .transpose()?
            .flatten();
        // `limit` is one total context-entry budget, not a separate ceiling for
        // every array. Self always occupies the first entry.
        let mut remaining = limit.saturating_sub(1);
        let parent = if let Some(parent) = parent_agent.as_ref() {
            if remaining > 0 {
                remaining -= 1;
                Some(self.team_agent_projection(&caller, parent)?)
            } else {
                None
            }
        } else {
            None
        };
        let active_assignment_candidate =
            self.store.preferred_agent_assignment(&caller.agent_id)?;
        let active_assignment = if let Some(assignment) = active_assignment_candidate.as_ref() {
            if remaining > 0 {
                remaining -= 1;
                let trace_pause = self.team_assignment_trace_pause(assignment)?;
                Some(json!({
                    "assignmentId":assignment.assignment_id,
                    "executionId":assignment.execution_id,
                    "status":if trace_pause.is_some() {"autonomy_paused"} else {assignment.status.as_str()},
                    "statusDetail":trace_pause.as_ref().map(|state| state.reason.as_str()).or(assignment.error.as_deref()),
                    "coordinationTraceState":trace_pause,
                    "taskPreview":crate::shared::foundation::text::truncate_str(&assignment.task, 512),
                    "roleId":caller.role_id,
                    "roleVersion":caller.role_version,
                    "roleInstructions":assignment.context.get("roleInstructions"),
                    "referenceContext":assignment
                        .context
                        .get("reference")
                        .filter(|content| !content.is_null())
                        .map(|content| json!({
                            "trust":"untrusted_reference",
                            "content":content,
                        })),
                }))
            } else {
                None
            }
        } else {
            None
        };
        let child_page =
            self.store
                .management_child_agent_page(&caller.agent_id, false, 0, remaining.max(1))?;
        let child_total = child_page.total;
        let active_children = child_page.active;
        let mut child_items = Vec::new();
        for child in child_page.items.into_iter().take(remaining) {
            remaining -= 1;
            child_items.push(self.team_agent_projection(&caller, &child)?);
        }

        let unread_page = self
            .event_store
            .unobserved_agent_message_page(&caller.session_id, 0, remaining.max(1))
            .map_err(|error| error.to_string())?;
        let unread_total = unread_page.total;
        let mut unread = Vec::new();
        for message in unread_page.items.into_iter().take(remaining) {
            remaining -= 1;
            let source_name = self
                .store
                .agent_instance(&message.source_agent_id)?
                .map(|agent| agent.name);
            unread.push(json!({
                "messageId":message.message_id,
                "sourceAgentId":message.source_agent_id,
                "sourceName":source_name,
                "kind":message.kind,
                "authority":message.authority,
                "assignmentId":message.assignment_id,
                "replyTo":message.reply_to_message_id,
                "deliveryState":message.disposition,
                "preview":crate::shared::foundation::text::truncate_str(&message.content.text, 512),
                "createdAt":message.created_at,
            }));
        }

        // Cross-database correspondent queries cannot join management edges.
        // Build the exact direct-child exclusion set through stable store pages
        // so omitted children are not counted a second time as contacts.
        let mut correspondent_exclusions = vec![caller.agent_id.clone()];
        if let Some(parent_agent) = parent_agent.as_ref() {
            correspondent_exclusions.push(parent_agent.agent_id.clone());
        }
        let mut child_offset = 0_usize;
        loop {
            let page = self.store.management_child_agent_page(
                &caller.agent_id,
                true,
                child_offset,
                200,
            )?;
            let page_len = page.items.len();
            correspondent_exclusions.extend(page.items.into_iter().map(|agent| agent.agent_id));
            child_offset = child_offset.saturating_add(page_len);
            if page_len == 0 || u64::try_from(child_offset).unwrap_or(u64::MAX) >= page.total {
                break;
            }
        }
        let correspondent_page = self
            .event_store
            .agent_correspondent_page(
                &caller.agent_id,
                &correspondent_exclusions,
                0,
                remaining.max(1),
            )
            .map_err(|error| error.to_string())?;
        let correspondent_total = correspondent_page.total;
        let mut correspondents = Vec::new();
        for correspondent in correspondent_page.items.into_iter().take(remaining) {
            let Some(agent) = self.store.agent_instance(&correspondent.agent_id)? else {
                continue;
            };
            remaining -= 1;
            let mut projected = self.team_agent_projection(&caller, &agent)?;
            if let Some(object) = projected.as_object_mut() {
                object.insert(
                    "lastMessageAt".to_owned(),
                    Value::String(correspondent.last_message_at),
                );
                object.insert(
                    "messageCount".to_owned(),
                    Value::from(correspondent.message_count),
                );
            }
            correspondents.push(projected);
        }
        let resource_claim_page = self.store.workspace_claim_page(
            Some(&caller.agent_id),
            None,
            false,
            0,
            remaining.max(1),
        )?;
        let resource_claim_total = resource_claim_page.total;
        let mut resource_claims = Vec::new();
        for claim in resource_claim_page.items.into_iter().take(remaining) {
            resource_claims.push(json!({
                "claimId":claim.claim_id,
                "executionId":claim.execution_id,
                "kind":claim.kind.as_str(),
                "scope":claim.canonical_scope,
                "state":claim.state.as_str(),
                "requestedAt":claim.requested_at,
                "acquiredAt":claim.acquired_at,
            }));
        }
        let settings = &self.settings_runtime.current().settings.agent.coordination;
        let queued_assignments = self.store.queued_agent_assignment_count(&caller.agent_id)?;
        let queue_ceiling =
            self.effective_agent_queue_ceiling(&caller, settings.max_queued_assignments);
        let budgets = json!({
            "limits":caller.limits,
            "activeChildren":active_children,
            "remainingActiveChildren":u64::from(settings.max_active_children).saturating_sub(active_children),
            "queuedAssignments":queued_assignments,
            "remainingQueuedAssignments":u64::from(queue_ceiling).saturating_sub(queued_assignments),
            "maxExecutionNodes":settings.max_execution_nodes,
            "maxCausalDepth":settings.max_causal_depth,
            "maxCoordinationMessages":settings.max_coordination_messages,
            "maxAutonomousWakeHops":settings.max_autonomous_wake_hops,
        });
        let mut self_projection = self.team_agent_projection(&caller, &caller)?;
        let effective_caller_tools = self.effective_agent_tool_names(&caller).await?;
        let delegation_ceiling = self.delegation_ceiling_for_agent(&caller).await?;
        let delegable_tool_catalog = if delegation_ceiling
            .iter()
            .any(|tool| tool == "worker_upsert")
        {
            Some(self.delegable_tool_catalog(&delegation_ceiling).await?)
        } else {
            None
        };
        self_projection["capabilities"] = json!(effective_caller_tools.clone());
        let candidate_total = 1_u64
            .saturating_add(u64::from(parent_agent.is_some()))
            .saturating_add(u64::from(active_assignment_candidate.is_some()))
            .saturating_add(child_total)
            .saturating_add(unread_total)
            .saturating_add(correspondent_total)
            .saturating_add(resource_claim_total);
        let emitted = 1_usize
            .saturating_add(usize::from(parent.is_some()))
            .saturating_add(usize::from(active_assignment.is_some()))
            .saturating_add(child_items.len())
            .saturating_add(unread.len())
            .saturating_add(correspondents.len())
            .saturating_add(resource_claims.len());
        let overflow_count =
            candidate_total.saturating_sub(u64::try_from(emitted).unwrap_or(u64::MAX));
        Ok(json!({
            "self":self_projection,
            "parent":parent,
            "activeAssignment":active_assignment,
            "children":child_items,
            "correspondents":correspondents,
            "unread":unread,
            "authority":{
                "tools":effective_caller_tools,
                "writeScopes":string_array(&caller.write_scopes),
                "limits":caller.limits,
                "managementOwnerAgentId":caller.management_owner_agent_id,
                "relationship":if caller.management_owner_agent_id.is_some() {"child"} else {"root"},
                "canMessageProfile":true,
                "delegableToolCatalog":delegable_tool_catalog,
            },
            "resourceClaims":resource_claims,
            "budgets":budgets,
            "overflowCount":overflow_count,
        }))
    }

    pub(in crate::domains::worker_kernel::runtime) async fn resolve_calling_agent(
        &self,
        invocation: &Invocation,
    ) -> Result<
        (
            AgentInstanceRecord,
            crate::domains::session::event_store::SessionRow,
        ),
        String,
    > {
        let session_id = invocation
            .causal_context
            .session_id
            .as_deref()
            .ok_or_else(|| "agent coordination requires an engine-derived session".to_owned())?;
        let (agent, session) = self.ensure_agent_identity_for_session(session_id).await?;
        if agent.state == AgentInstanceState::Closed {
            return Err("closed agents cannot use coordination tools".to_owned());
        }
        Ok((agent, session))
    }

    /// Resolve the stable agent identity which owns one live transcript,
    /// lazily installing a root identity for an ordinary visible session.
    ///
    /// Direct agent-runner worker admission uses the same seam before its
    /// transactional bridge is created. That keeps top-level worker agents in
    /// the originating session's management tree instead of manufacturing an
    /// unowned nested lifecycle root.
    pub(in crate::domains::worker_kernel::runtime) async fn ensure_agent_identity_for_session(
        &self,
        session_id: &str,
    ) -> Result<
        (
            AgentInstanceRecord,
            crate::domains::session::event_store::SessionRow,
        ),
        String,
    > {
        let session = self
            .event_store
            .get_session(session_id)
            .map_err(|error| error.to_string())?
            .ok_or_else(|| format!("agent session '{session_id}' was not found"))?;
        if session.is_worker_session() || session.ended_at.is_some() {
            return Err("agent coordination requires a live agent transcript".to_owned());
        }
        if let Some(agent) = self.store.agent_instance_for_session(session_id)? {
            return Ok((agent, session));
        }
        if session.is_agent_session() {
            return Err("nested agent transcript has no durable agent identity".to_owned());
        }
        let grant = self.inheritable_tool_names().await?;
        let agent = self.store.ensure_root_agent(&NewRootAgent {
            session_id: session.id.clone(),
            workspace_id: session.workspace_id.clone(),
            name: session
                .title
                .clone()
                .filter(|title| !title.trim().is_empty())
                .unwrap_or_else(|| "Root agent".to_owned()),
            model: Some(session.latest_model.clone()),
            reasoning_level: None,
            tool_grant: json!(grant),
            limits: self.default_agent_limits(),
        })?;
        Ok((agent, session))
    }

    pub(in crate::domains::worker_kernel::runtime) async fn delegable_tool_names(
        &self,
    ) -> Result<Vec<String>, String> {
        self.tool_names_with_delegation(true).await
    }

    pub(in crate::domains::worker_kernel::runtime) async fn inheritable_tool_names(
        &self,
    ) -> Result<Vec<String>, String> {
        self.tool_names_with_delegation(false).await
    }

    async fn tool_names_with_delegation(
        &self,
        include_explicit: bool,
    ) -> Result<Vec<String>, String> {
        let actor = crate::engine::ActorContext::new(
            ActorId::new("agent:grant-resolution").map_err(|error| error.to_string())?,
            // Admission may inspect hidden catalog entries only to resolve a
            // source-owned delegable ceiling. Provider discovery still uses
            // Agent visibility, and execution requires the resulting exact
            // function-id grant.
            ActorKind::System,
        );
        let (_, functions) = self.host.visible_functions_with_revision(&actor).await;
        let mut names = functions
            .into_iter()
            .filter(|function| {
                function.delegation_policy == crate::engine::DelegationPolicy::Inherit
                    || (include_explicit
                        && function.delegation_policy == crate::engine::DelegationPolicy::Explicit)
            })
            .filter_map(|function| function.model_tool.map(|tool| tool.name))
            .collect::<Vec<_>>();
        names.sort();
        names.dedup();
        Ok(names)
    }

    async fn delegable_tool_catalog(&self, ceiling: &[String]) -> Result<Vec<Value>, String> {
        let ceiling = ceiling.iter().map(String::as_str).collect::<BTreeSet<_>>();
        let actor = crate::engine::ActorContext::new(
            ActorId::new("agent:grant-authoring-catalog").map_err(|error| error.to_string())?,
            ActorKind::System,
        );
        let (_, functions) = self.host.visible_functions_with_revision(&actor).await;
        let mut catalog = functions
            .into_iter()
            .filter(|function| function.delegation_policy != crate::engine::DelegationPolicy::Never)
            .filter_map(|function| {
                let name = function.model_tool?.name;
                ceiling.contains(name.as_str()).then(|| {
                    json!({
                        "name":name,
                        "delegation":function.delegation_policy.as_str(),
                        "workspaceEffect":function.workspace_effect.as_str(),
                    })
                })
            })
            .collect::<Vec<_>>();
        catalog.sort_by(|left, right| {
            left.get("name")
                .and_then(Value::as_str)
                .cmp(&right.get("name").and_then(Value::as_str))
        });
        Ok(catalog)
    }

    pub(in crate::domains::worker_kernel::runtime) async fn effective_agent_tool_names(
        &self,
        agent: &AgentInstanceRecord,
    ) -> Result<Vec<String>, String> {
        if agent.kind == AgentInstanceKind::Root {
            self.inheritable_tool_names().await
        } else {
            Ok(string_array(&agent.tool_grant))
        }
    }

    pub(in crate::domains::worker_kernel::runtime) async fn delegation_ceiling_for_agent(
        &self,
        agent: &AgentInstanceRecord,
    ) -> Result<Vec<String>, String> {
        if agent.kind == AgentInstanceKind::Root {
            self.delegable_tool_names().await
        } else {
            Ok(string_array(&agent.tool_grant))
        }
    }

    pub(in crate::domains::worker_kernel::runtime) fn default_agent_limits(&self) -> Value {
        let limits = &self.settings_runtime.current().settings.agent.coordination;
        json!({
            "maxAssignmentSeconds":limits.assignment_default_seconds,
            "maxAssignmentTurns":limits.assignment_default_turns,
            "maxChildExecutions":limits.max_execution_nodes,
            "maxQueuedAssignments":limits.max_queued_assignments,
        })
    }

    pub(in crate::domains::worker_kernel::runtime) fn effective_agent_queue_ceiling(
        &self,
        agent: &AgentInstanceRecord,
        profile_ceiling: u32,
    ) -> u32 {
        if agent.kind == AgentInstanceKind::Root {
            return profile_ceiling;
        }
        agent
            .limits
            .get("maxQueuedAssignments")
            .and_then(Value::as_u64)
            .and_then(|value| u32::try_from(value).ok())
            .unwrap_or(profile_ceiling)
            .min(profile_ceiling)
    }

    fn team_agent_projection(
        &self,
        caller: &AgentInstanceRecord,
        agent: &AgentInstanceRecord,
    ) -> Result<Value, String> {
        let latest = match self.store.preferred_agent_assignment(&agent.agent_id)? {
            Some(assignment) => Some(assignment),
            None => self
                .store
                .agent_assignment_history_page(&agent.agent_id, 0, 1)?
                .items
                .into_iter()
                .next(),
        };
        let trace_pause = latest
            .as_ref()
            .map(|assignment| self.team_assignment_trace_pause(assignment))
            .transpose()?
            .flatten();
        let owning_session_label = self
            .event_store
            .get_session(&agent.root_session_id)
            .map_err(|error| error.to_string())?
            .and_then(|session| session.title)
            .filter(|title| !title.trim().is_empty())
            .unwrap_or_else(|| "Untitled task".to_owned());
        let mut can_manage = false;
        if caller.agent_id != agent.agent_id {
            for capability in [
                AgentManagementCapability::Assign,
                AgentManagementCapability::Cancel,
                AgentManagementCapability::Configure,
                AgentManagementCapability::Close,
            ] {
                if self
                    .store
                    .has_agent_management(&caller.agent_id, &agent.agent_id, capability)?
                {
                    can_manage = true;
                    break;
                }
            }
        }
        Ok(json!({
            "agentId":agent.agent_id,
            "name":agent.name,
            "role":agent.role_id.as_deref().unwrap_or(agent.kind.as_str()),
            "status":if trace_pause.is_some() {"autonomy_paused"} else {agent.state.as_str()},
            "statusDetail":trace_pause.as_ref().map(|state| state.reason.as_str()),
            "capabilities":string_array(&agent.tool_grant),
            "taskPreview":latest
                .as_ref()
                .map(|assignment| crate::shared::foundation::text::truncate_str(&assignment.task, 512))
                .unwrap_or_default(),
            "owningSessionLabel":owning_session_label,
            "relationship":agent_relationship(caller, agent),
            "canMessage":agent.state != AgentInstanceState::Closed,
            "canManage":can_manage,
        }))
    }

    fn team_assignment_trace_pause(
        &self,
        assignment: &crate::domains::worker_kernel::persistence::AgentAssignmentRecord,
    ) -> Result<
        Option<crate::domains::worker_kernel::persistence::CoordinationTraceStateRecord>,
        String,
    > {
        let Some(execution) = self.store.execution_node(&assignment.execution_id)? else {
            return Ok(None);
        };
        Ok(self
            .store
            .coordination_trace_state(&execution.trace_id)?
            .filter(|state| state.paused))
    }

    pub(in crate::domains::worker_kernel::runtime) fn assignment_context_for_agent(
        &self,
        agent: &AgentInstanceRecord,
        mut context: Value,
    ) -> Result<Value, String> {
        let object = context
            .as_object_mut()
            .ok_or_else(|| "agent assignment context must be an object".to_owned())?;
        let (Some(role_id), Some(role_version)) =
            (agent.role_id.as_deref(), agent.role_version.as_deref())
        else {
            object.insert("roleResult".to_owned(), json!({"mode":"natural"}));
            return Ok(context);
        };
        let pinned = self.store.load_version(role_id, role_version)?;
        let Some(WorkerAgentRole::Enabled {
            collaboration_instructions,
            result_mode,
            ..
        }) = pinned.bundle.agent_role.as_ref()
        else {
            return Err(format!(
                "pinned agent role '{role_id}@{role_version}' has no enabled role declaration"
            ));
        };
        object.insert(
            "roleInstructions".to_owned(),
            Value::String(collaboration_instructions.clone()),
        );
        object.insert(
            "roleResult".to_owned(),
            json!({
                "mode":serde_json::to_value(result_mode).map_err(|error| error.to_string())?,
                "schema":pinned.bundle.output_schema,
                "roleVersion":role_version,
            }),
        );
        Ok(context)
    }
}
