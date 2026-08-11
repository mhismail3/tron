//! Agent and role discovery plus atomic reusable-agent admission.

use super::*;

impl WorkerRuntime {
    /// Return bounded operational directory entries for agents and declared
    /// dynamic roles. Transcript/result content and storage identities are
    /// intentionally absent.
    pub(crate) async fn agent_discover(&self, invocation: &Invocation) -> Result<Value, String> {
        let (caller, _) = self.resolve_calling_agent(invocation).await?;
        let scope = invocation
            .payload
            .get("scope")
            .and_then(Value::as_str)
            .unwrap_or("all");
        let query = invocation
            .payload
            .get("query")
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or_default()
            .to_ascii_lowercase();
        let statuses = invocation
            .payload
            .get("status")
            .and_then(Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .filter_map(Value::as_str)
                    .collect::<BTreeSet<_>>()
            })
            .unwrap_or_default();
        let offset =
            decode_directory_cursor(invocation.payload.get("cursor").and_then(Value::as_str))?;
        let limit = invocation
            .payload
            .get("limit")
            .and_then(Value::as_u64)
            .and_then(|value| usize::try_from(value).ok())
            .unwrap_or(DEFAULT_DIRECTORY_LIMIT)
            .clamp(1, MAX_DIRECTORY_LIMIT);

        let include_agents = matches!(scope, "agents" | "all");
        let include_roles = matches!(scope, "roles" | "all");
        let current_root_grant = self.inheritable_tool_names().await?;
        let status_values = statuses
            .iter()
            .map(|status| (*status).to_owned())
            .collect::<Vec<_>>();
        let agent_total = if include_agents {
            self.store
                .agent_instance_directory_page(false, &status_values, &query, 0, 1)?
                .total
        } else {
            0
        };
        let mut role_entries = Vec::<Value>::new();
        if include_roles {
            for summary in self.store.list(false)? {
                if !is_discoverable_agent_role(&summary) {
                    continue;
                }
                let active = self.store.load_indexed_active(&summary.worker_id)?;
                if !is_executable_agent_role(&active.summary, active.bundle.agent_role.as_ref()) {
                    continue;
                }
                let WorkerAgentRole::Enabled {
                    display_name,
                    summary: role_summary,
                    discoverable: true,
                    tool_ceiling,
                    limits,
                    ..
                } = active
                    .bundle
                    .agent_role
                    .as_ref()
                    .unwrap_or(&WorkerAgentRole::Disabled)
                else {
                    continue;
                };
                let haystack = format!(
                    "{} {} {} {}",
                    summary.worker_id,
                    display_name,
                    role_summary,
                    active.bundle.routing.intents.join(" ")
                )
                .to_ascii_lowercase();
                if !query.is_empty() && !haystack.contains(&query) {
                    continue;
                }
                role_entries.push(json!({
                    "roleId":summary.worker_id,
                    "name":display_name,
                    "description":role_summary,
                    "available":true,
                    "capabilities":tool_ceiling,
                    "limits":limits,
                    "workerVersion":summary.active_version,
                }));
            }
        }
        role_entries.sort_by(|left, right| {
            left.get("name")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_ascii_lowercase()
                .cmp(
                    &right
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_ascii_lowercase(),
                )
        });
        let role_total = role_entries.len();
        // `all` is a deterministic concatenation of the stable agent section
        // followed by the much smaller immutable-role section. This lets the
        // agent directory own filtering/count/paging in SQLite instead of
        // truncating at 200 and trying to merge an incomplete in-memory list.
        let agent_total_usize = usize::try_from(agent_total).unwrap_or(usize::MAX);
        let mut agents = Vec::new();
        let mut roles = Vec::new();
        let mut remaining = limit;
        if include_agents && offset < agent_total_usize {
            let page = self.store.agent_instance_directory_page(
                false,
                &status_values,
                &query,
                offset,
                remaining,
            )?;
            for agent in page.items {
                agents.push(self.agent_discovery_projection(
                    &caller,
                    &agent,
                    &current_root_grant,
                )?);
            }
            remaining = remaining.saturating_sub(agents.len());
        }
        if include_roles && remaining > 0 {
            let role_offset = offset.saturating_sub(agent_total_usize);
            roles.extend(role_entries.into_iter().skip(role_offset).take(remaining));
        }
        let returned = agents.len().saturating_add(roles.len());
        let total = agent_total_usize.saturating_add(if include_roles { role_total } else { 0 });
        let next_offset = offset.saturating_add(returned);
        Ok(json!({
            "scope":scope,
            "agents":agents,
            "roles":roles,
            "returned":returned,
            "nextCursor":(next_offset < total).then(|| format!("offset:{next_offset}")),
        }))
    }

    fn agent_discovery_projection(
        &self,
        caller: &AgentInstanceRecord,
        agent: &AgentInstanceRecord,
        current_root_grant: &[String],
    ) -> Result<Value, String> {
        let latest = self
            .store
            .agent_assignment_history_page(&agent.agent_id, 0, 1)?
            .items
            .into_iter()
            .next();
        let relationship = agent_relationship(caller, agent);
        let owning_session_label = self
            .event_store
            .get_session(&agent.root_session_id)
            .map_err(|error| error.to_string())?
            .and_then(|session| session.title)
            .filter(|title| !title.trim().is_empty())
            .unwrap_or_else(|| "Untitled task".to_owned());
        let task_preview = latest
            .as_ref()
            .map(|assignment| {
                crate::shared::foundation::text::truncate_str(&assignment.task, 512).to_owned()
            })
            .unwrap_or_default();
        let role = agent
            .role_id
            .clone()
            .unwrap_or_else(|| agent.kind.as_str().to_owned());
        let can_manage = caller.agent_id != agent.agent_id
            && self.store.has_agent_management(
                &caller.agent_id,
                &agent.agent_id,
                AgentManagementCapability::Assign,
            )?;
        Ok(json!({
            "agentId":agent.agent_id,
            "name":agent.name,
            "role":role,
            "owningSessionLabel":owning_session_label,
            "relationship":relationship,
            "status":agent.state.as_str(),
            "capabilities":if agent.kind == AgentInstanceKind::Root {
                current_root_grant.to_vec()
            } else {
                string_array(&agent.tool_grant)
            },
            "taskPreview":task_preview,
            "canMessage":agent.state != AgentInstanceState::Closed,
            "canManage":can_manage,
        }))
    }

    /// Admit a nested reusable agent and provision its durable hidden
    /// transcript through the workers-to-session outbox boundary.
    pub(crate) async fn agent_spawn(&self, invocation: &Invocation) -> Result<Value, String> {
        let (caller, source_session) = self.resolve_calling_agent(invocation).await?;
        let coordination = self
            .settings_runtime
            .current()
            .settings
            .agent
            .coordination
            .clone();
        let causal_depth = child_execution_depth(invocation);
        let task = required_coordination_string(&invocation.payload, "task")?;
        let requested_role = invocation
            .payload
            .get("role")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|role| !role.is_empty())
            .unwrap_or("general");
        let requested_model = optional_coordination_string(&invocation.payload, "model")?;
        let requested_reasoning =
            optional_coordination_string(&invocation.payload, "reasoningLevel")?;
        let requested_tools = optional_string_array(&invocation.payload, "tools")?;
        let tools_were_requested = requested_tools.is_some();
        let requested_scopes = optional_string_array(&invocation.payload, "writeScopes")?
            .unwrap_or_default()
            .into_iter()
            .map(|scope| canonical_write_scope(&scope))
            .collect::<Result<Vec<_>, _>>()?;
        if caller.kind != AgentInstanceKind::Root {
            let parent_scopes = string_array(&caller.write_scopes);
            if requested_scopes.iter().any(|scope| {
                !parent_scopes
                    .iter()
                    .any(|parent| scope_is_within(scope, parent))
            }) {
                return Err(
                    "agent write scopes must remain within the parent's immutable grant".to_owned(),
                );
            }
        }
        let profile_limits = self.default_agent_limits();
        let requested_limits = invocation
            .payload
            .get("limits")
            .cloned()
            .unwrap_or_else(|| profile_limits.clone());
        // A visible root may explicitly delegate any source-declared
        // delegable function. Ordinary general children inherit only the
        // `Inherit` subset by default; `Explicit` functions enter a grant only
        // through an explicit requested subset or a reviewed named-role
        // ceiling. Nested agents can never grow beyond their immutable grant.
        let parent_grant = self
            .delegation_ceiling_for_agent(&caller)
            .await?
            .into_iter()
            .collect::<BTreeSet<_>>();
        let inherited_general_ceiling = if caller.kind == AgentInstanceKind::Root {
            self.inheritable_tool_names()
                .await?
                .into_iter()
                .collect::<BTreeSet<_>>()
        } else {
            parent_grant.clone()
        };

        let mut role_id = None;
        let mut role_version = None;
        let mut role_name = "General agent".to_owned();
        let mut role_summary = "General reusable Tron agent".to_owned();
        let mut role_instructions = None;
        let mut role_model = None;
        let mut role_reasoning = None;
        let mut role_limits = profile_limits.clone();
        let mut role_ceiling = if tools_were_requested {
            parent_grant.clone()
        } else {
            inherited_general_ceiling
        };
        let mut role_result = json!({"mode":"natural"});
        let kind = if requested_role == "general" {
            AgentInstanceKind::General
        } else {
            let active = self.store.load_indexed_active(requested_role)?;
            if !is_executable_agent_role(&active.summary, active.bundle.agent_role.as_ref()) {
                return Err(format!(
                    "agent role '{requested_role}' is not an active healthy agent runner"
                ));
            }
            let Some(WorkerAgentRole::Enabled {
                display_name,
                summary,
                discoverable: true,
                collaboration_instructions,
                default_model,
                default_reasoning_level,
                tool_ceiling,
                limits,
                result_mode,
                ..
            }) = active.bundle.agent_role.as_ref()
            else {
                return Err(format!(
                    "worker '{requested_role}' has no discoverable enabled agentRole declaration"
                ));
            };
            role_id = Some(active.summary.worker_id.clone());
            role_version = Some(active.summary.active_version.clone());
            role_name = display_name.clone();
            role_summary = summary.clone();
            role_instructions = Some(collaboration_instructions.clone());
            role_model = default_model.clone();
            role_reasoning = default_reasoning_level.clone();
            role_limits = serde_json::to_value(limits).map_err(|error| error.to_string())?;
            role_ceiling = tool_ceiling.iter().cloned().collect();
            role_result = json!({
                "mode":serde_json::to_value(result_mode).map_err(|error| error.to_string())?,
                "schema":active.bundle.output_schema.clone(),
                "roleVersion":active.summary.active_version.clone(),
            });
            AgentInstanceKind::Role
        };
        let allowed = parent_grant
            .intersection(&role_ceiling)
            .cloned()
            .collect::<BTreeSet<_>>();
        let effective_tools = requested_tools.map_or_else(
            || allowed.iter().cloned().collect::<Vec<_>>(),
            |requested| {
                requested
                    .into_iter()
                    .filter(|tool| allowed.contains(tool))
                    .collect::<Vec<_>>()
            },
        );
        let inherited_model = if caller.kind == AgentInstanceKind::Root {
            // A root identity is installed lazily and may outlive later model
            // changes on its visible session. Root delegation follows the
            // model of this source turn; nested reusable agents deliberately
            // retain their pinned configurable default across assignments.
            source_session.latest_model.clone()
        } else {
            caller
                .default_model
                .clone()
                .unwrap_or_else(|| source_session.latest_model.clone())
        };
        let model = requested_model.or(role_model).unwrap_or(inherited_model);
        let reasoning_level = requested_reasoning
            .or(role_reasoning)
            .or_else(|| caller.default_reasoning_level.clone());
        validate_agent_model_reasoning(
            Some(&model),
            reasoning_level.as_deref(),
            &crate::shared::foundation::paths::auth_path_for_home(self.store.home()),
        )?;
        let limits = tighten_limits(&profile_limits, &role_limits, &requested_limits)?;
        let name = invocation
            .payload
            .get("name")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .map(ToOwned::to_owned)
            .unwrap_or_else(|| role_name.clone());
        let context = json!({
            "reference":invocation.payload.get("context").cloned(),
            "roleInstructions":role_instructions,
            "roleResult":role_result,
        });
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
        let admission = self.store.admit_agent(&NewAgentAdmission {
            admission_key: format!("agent-spawn:{}", invocation.id),
            root_session_id: caller.root_session_id.clone(),
            workspace_id: caller.workspace_id.clone(),
            spawned_by_agent_id: caller.agent_id.clone(),
            management_owner_agent_id: caller.agent_id.clone(),
            kind,
            role_id: role_id.clone(),
            role_version: role_version.clone(),
            name,
            task: task.clone(),
            context,
            assignment_kind: AgentAssignmentKind::Instruction,
            requester_agent_id: Some(caller.agent_id.clone()),
            delegator_agent_id: Some(caller.agent_id.clone()),
            parent_execution_id,
            trace_id: invocation.causal_context.trace_id.as_str().to_owned(),
            causal_depth,
            child_slot: invocation.causal_context.origin_worker_tool_ordinal(),
            model: Some(model.clone()),
            reasoning_level: reasoning_level.clone(),
            tool_grant: json!(effective_tools),
            resource_snapshot: json!({"workspaceEffect":"claimed"}),
            write_scopes: json!(requested_scopes),
            limits: limits.clone(),
            retry_of_assignment_id: None,
            deadline_at,
            max_active_children: coordination.max_active_children,
            max_child_executions,
            max_execution_nodes: coordination.max_execution_nodes,
            max_causal_depth: coordination.max_causal_depth,
            autonomous_hop: invocation
                .causal_context
                .autonomous_wake_hop()
                .saturating_add(1),
        })?;
        // Admission commits the stable agent/session/assignment identities and
        // provisioning effect together. The dispatcher importer is the sole
        // owner of cross-database transcript creation and message delivery.
        let _ = self.import_agent_coordination_outbox().await;
        self.delivery_maintenance.notify_one();
        Ok(json!({
            "agentId":admission.agent.agent_id,
            "assignmentId":admission.assignment.assignment_id,
            "executionId":admission.execution.execution_id,
            "status":admission.assignment.status.as_str(),
            "effectiveRole":{
                "roleId":role_id.unwrap_or_else(|| "general".to_owned()),
                "workerVersion":role_version,
                "name":role_name,
                "summary":role_summary,
            },
            "effectiveGrant":{
                "tools":admission.agent.tool_grant,
                "writeScopes":admission.agent.write_scopes,
            },
            "effectiveLimits":limits,
        }))
    }
}
