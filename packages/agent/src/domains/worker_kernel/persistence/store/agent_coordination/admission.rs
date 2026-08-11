//! Root, reusable-agent, and direct-worker admission.
//!
//! Admission owns idempotent identity, assignment, execution-node, and outbox creation.

use super::*;

impl WorkerStore {
    /// Lazily install the stable directory identity for a visible root session.
    pub(crate) fn ensure_root_agent(
        &self,
        request: &NewRootAgent,
    ) -> Result<AgentInstanceRecord, String> {
        validate_runtime_identifier(&request.session_id, "root session id", 256)?;
        validate_runtime_identifier(&request.workspace_id, "workspace id", 256)?;
        validate_name(&request.name)?;
        let digest = Sha256::digest(request.session_id.as_bytes());
        let agent_id = format!("agent_root_{}", hex::encode(&digest[..16]));
        let now = chrono::Utc::now().to_rfc3339();
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("start root agent identity transaction: {error}"))?;
        transaction
            .execute(
                "INSERT OR IGNORE INTO agent_instances(
                    agent_id,session_id,root_session_id,workspace_id,
                    spawned_by_agent_id,management_owner_agent_id,kind,
                    role_id,role_version,name,visibility,state,default_model,
                    default_reasoning_level,tool_grant_json,write_scopes_json,
                    limits_json,created_at,updated_at
                 ) VALUES (?1,?2,?2,?3,NULL,NULL,'root',NULL,NULL,?4,
                           'visible','idle',?5,?6,?7,'[]',?8,?9,?9)",
                params![
                    agent_id,
                    request.session_id,
                    request.workspace_id,
                    request.name,
                    request.model,
                    request.reasoning_level,
                    encode_json(&request.tool_grant)?,
                    encode_json(&request.limits)?,
                    now,
                ],
            )
            .map_err(|error| format!("insert root agent identity: {error}"))?;
        let record = query_agent_by_session(&transaction, &request.session_id)?
            .ok_or_else(|| "root agent identity disappeared".to_owned())?;
        if record.workspace_id != request.workspace_id || record.kind != AgentInstanceKind::Root {
            return Err(format!(
                "session '{}' is already linked to an incompatible agent identity",
                request.session_id
            ));
        }
        transaction
            .commit()
            .map_err(|error| format!("commit root agent identity: {error}"))?;
        Ok(record)
    }

    /// Atomically admit one nested reusable agent, its first assignment, mixed
    /// execution node, initial evidence event, and provisioning outbox row.
    pub(crate) fn admit_agent(
        &self,
        request: &NewAgentAdmission,
    ) -> Result<AgentAdmission, String> {
        validate_admission(request)?;
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("start agent admission transaction: {error}"))?;
        if let Some(existing) =
            query_assignment_by_admission_key(&transaction, &request.admission_key)?
        {
            if existing.task != request.task
                || existing.kind != request.assignment_kind
                || existing.retry_of_assignment_id != request.retry_of_assignment_id
            {
                return Err("agent admission idempotency conflict".to_owned());
            }
            let agent = query_agent(&transaction, &existing.agent_id)?
                .ok_or_else(|| "idempotent agent admission lost its agent".to_owned())?;
            if agent.kind != request.kind
                || agent.role_id != request.role_id
                || agent.role_version != request.role_version
                || agent.root_session_id != request.root_session_id
                || agent.workspace_id != request.workspace_id
                || agent.spawned_by_agent_id.as_deref() != Some(&request.spawned_by_agent_id)
                || agent.management_owner_agent_id.as_deref()
                    != Some(&request.management_owner_agent_id)
                || agent.name != request.name
                || agent.default_model != request.model
                || agent.default_reasoning_level != request.reasoning_level
                || agent.tool_grant != request.tool_grant
                || agent.write_scopes != request.write_scopes
                || agent.limits != request.limits
                || existing.requester_agent_id != request.requester_agent_id
                || existing.delegator_agent_id != request.delegator_agent_id
                || existing.context != request.context
                || existing.model != request.model
                || existing.reasoning_level != request.reasoning_level
                || existing.authority_snapshot != request.tool_grant
                || existing.resource_snapshot != request.resource_snapshot
                || existing.write_scopes_snapshot != request.write_scopes
                || existing.limits_snapshot != request.limits
            {
                return Err("agent admission idempotency conflict".to_owned());
            }
            let execution = query_execution(&transaction, &existing.execution_id)?
                .ok_or_else(|| "idempotent agent admission lost its execution".to_owned())?;
            if execution.parent_execution_id != request.parent_execution_id
                || execution.trace_id != request.trace_id
                || execution.causal_depth != request.causal_depth
                || execution.child_slot != request.child_slot
            {
                return Err("agent admission idempotency conflict".to_owned());
            }
            let spawner = require_agent(
                &transaction,
                &request.spawned_by_agent_id,
                "idempotent spawning agent",
            )?;
            let mut expected_provision = agent_provision_payload(
                request,
                &spawner,
                &agent.agent_id,
                &agent.session_id,
                &existing.assignment_id,
                &existing.execution_id,
            );
            expected_provision["expiresAt"] = serde_json::to_value(&existing.deadline_at)
                .map_err(|error| format!("encode durable admission deadline: {error}"))?;
            let provision = query_assignment_outbox(
                &transaction,
                &existing.assignment_id,
                AgentOutboxKind::Provision,
            )?
            .ok_or_else(|| "idempotent agent admission lost its provisioning outbox".to_owned())?;
            if provision.payload != expected_provision {
                return Err("agent admission provisioning idempotency conflict".to_owned());
            }
            transaction
                .commit()
                .map_err(|error| format!("commit idempotent agent admission read: {error}"))?;
            return Ok(AgentAdmission {
                agent,
                assignment: existing,
                execution,
                created: false,
            });
        }

        let spawner = require_agent(&transaction, &request.spawned_by_agent_id, "spawning agent")?;
        if spawner.root_session_id != request.root_session_id
            || spawner.workspace_id != request.workspace_id
        {
            return Err(
                "spawned agent must remain in its parent's owning session/workspace".to_owned(),
            );
        }
        if request.management_owner_agent_id != request.spawned_by_agent_id {
            return Err("a new agent's initial management owner must be its spawner".to_owned());
        }
        if request.kind == AgentInstanceKind::Role {
            let role_exists = transaction
                .query_row(
                    "SELECT EXISTS(
                        SELECT 1 FROM worker_versions WHERE worker_id=?1 AND version=?2
                     )",
                    params![request.role_id, request.role_version],
                    |row| row.get::<_, bool>(0),
                )
                .map_err(|error| format!("verify immutable spawned agent role: {error}"))?;
            if !role_exists {
                return Err("spawned named-agent role version was not found".to_owned());
            }
        }
        require_agent(
            &transaction,
            &request.management_owner_agent_id,
            "management owner",
        )?;
        if let Some(requester) = request.requester_agent_id.as_deref() {
            require_agent(&transaction, requester, "assignment requester")?;
        }
        if let Some(delegator) = request.delegator_agent_id.as_deref() {
            require_agent(&transaction, delegator, "assignment delegator")?;
        }
        if let Some(parent_execution_id) = request.parent_execution_id.as_deref() {
            let parent = query_execution(&transaction, parent_execution_id)?
                .ok_or_else(|| format!("parent execution '{parent_execution_id}' was not found"))?;
            if parent.trace_id != request.trace_id
                || request.causal_depth != parent.causal_depth.saturating_add(1)
            {
                return Err("agent assignment parent does not match its causal trace".to_owned());
            }
            if parent.owner_agent_id.as_deref() != Some(spawner.agent_id.as_str())
                || parent.root_session_id.as_deref() != Some(request.root_session_id.as_str())
            {
                return Err(
                    "agent spawn parent execution is outside the spawner's causal ownership"
                        .to_owned(),
                );
            }
        } else if request.causal_depth != 1 {
            return Err("a root-level agent spawn must begin at causal depth 1".to_owned());
        }
        if request.retry_of_assignment_id.is_some() {
            return Err("assignment retries must reuse the existing stable agent".to_owned());
        }
        if request.causal_depth > request.max_causal_depth {
            return Err("agent causal depth exceeds the configured ceiling".to_owned());
        }
        enforce_active_agent_ceiling(
            &transaction,
            &request.root_session_id,
            None,
            request.max_active_children,
        )?;
        enforce_execution_node_ceiling(
            &transaction,
            &request.trace_id,
            request.max_execution_nodes,
        )?;
        enforce_direct_child_execution_ceiling(
            &transaction,
            &request.trace_id,
            request.parent_execution_id.as_deref(),
            request.max_child_executions,
        )?;

        let agent_id = format!("agent_{}", uuid::Uuid::now_v7());
        let session_id = format!("agent_session_{}", uuid::Uuid::now_v7());
        let assignment_id = format!("assignment_{}", uuid::Uuid::now_v7());
        let execution_id = format!("execution_{}", uuid::Uuid::now_v7());
        let outbox_id = format!("agent_outbox_{}", uuid::Uuid::now_v7());
        let event_id = format!("agent_execution_event_{}", uuid::Uuid::now_v7());
        let now = chrono::Utc::now().to_rfc3339();
        let queue_ordinal = transaction
            .query_row(
                "SELECT COALESCE(MAX(queue_ordinal),-1)+1 FROM agent_assignments WHERE agent_id=?1",
                [&agent_id],
                |row| row.get::<_, u64>(0),
            )
            .map_err(|error| format!("allocate agent assignment queue ordinal: {error}"))?;
        let (role_id, role_version) = match request.kind {
            AgentInstanceKind::Role => {
                (request.role_id.as_deref(), request.role_version.as_deref())
            }
            _ => (None, None),
        };
        transaction
            .execute(
                "INSERT INTO agent_instances(
                    agent_id,session_id,root_session_id,workspace_id,spawned_by_agent_id,
                    management_owner_agent_id,kind,role_id,role_version,name,visibility,
                    state,default_model,default_reasoning_level,tool_grant_json,
                    write_scopes_json,limits_json,created_at,updated_at
                 ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,'nested','provisioning',
                           ?11,?12,?13,?14,?15,?16,?16)",
                params![
                    agent_id,
                    session_id,
                    request.root_session_id,
                    request.workspace_id,
                    request.spawned_by_agent_id,
                    request.management_owner_agent_id,
                    request.kind.as_str(),
                    role_id,
                    role_version,
                    request.name,
                    request.model,
                    request.reasoning_level,
                    encode_json(&request.tool_grant)?,
                    encode_json(&request.write_scopes)?,
                    encode_json(&request.limits)?,
                    now,
                ],
            )
            .map_err(|error| format!("insert reusable agent: {error}"))?;
        transaction
            .execute(
                "INSERT INTO execution_nodes(
                    execution_id,kind,parent_execution_id,owner_agent_id,root_session_id,
                    trace_id,causal_depth,child_slot,worker_invocation_id,assignment_id,created_at
                 ) VALUES (?1,'agent_assignment',?2,?3,?4,?5,?6,?7,NULL,?8,?9)",
                params![
                    execution_id,
                    request.parent_execution_id,
                    agent_id,
                    request.root_session_id,
                    request.trace_id,
                    request.causal_depth,
                    request.child_slot,
                    assignment_id,
                    now,
                ],
            )
            .map_err(|error| format!("insert agent execution node: {error}"))?;
        transaction
            .execute(
                "INSERT INTO agent_assignments(
                    assignment_id,execution_id,agent_id,requester_agent_id,delegator_agent_id,
                    kind,status,admission_key,queue_ordinal,task,context_json,model,
                    reasoning_level,authority_snapshot_json,resource_snapshot_json,
                    write_scopes_snapshot_json,limits_snapshot_json,retry_of_assignment_id,
                    deadline_at,created_at,accepted_at,updated_at
                 ) VALUES (?1,?2,?3,?4,?5,?6,'accepted',?7,?8,?9,?10,?11,?12,
                           ?13,?14,?15,?16,?17,?18,?19,?19,?19)",
                params![
                    assignment_id,
                    execution_id,
                    agent_id,
                    request.requester_agent_id,
                    request.delegator_agent_id,
                    request.assignment_kind.as_str(),
                    request.admission_key,
                    queue_ordinal,
                    request.task,
                    encode_json(&request.context)?,
                    request.model,
                    request.reasoning_level,
                    encode_json(&request.tool_grant)?,
                    encode_json(&request.resource_snapshot)?,
                    encode_json(&request.write_scopes)?,
                    encode_json(&request.limits)?,
                    request.retry_of_assignment_id,
                    request.deadline_at,
                    now,
                ],
            )
            .map_err(|error| format!("insert first agent assignment: {error}"))?;
        transaction
            .execute(
                "INSERT INTO agent_execution_events(
                    event_id,execution_id,sequence,kind,details_json,occurred_at
                 ) VALUES (?1,?2,0,'accepted',?3,?4)",
                params![
                    event_id,
                    execution_id,
                    encode_json(&json!({"status":"accepted"}))?,
                    now,
                ],
            )
            .map_err(|error| format!("record agent admission event: {error}"))?;
        let provision_payload = agent_provision_payload(
            request,
            &spawner,
            &agent_id,
            &session_id,
            &assignment_id,
            &execution_id,
        );
        transaction
            .execute(
                "INSERT INTO agent_outbox(
                    outbox_id,deduplication_key,kind,agent_id,assignment_id,
                    execution_id,payload_json,created_at
                 ) VALUES (?1,?2,'provision',?3,?4,?5,?6,?7)",
                params![
                    outbox_id,
                    format!("provision:{assignment_id}"),
                    agent_id,
                    assignment_id,
                    execution_id,
                    encode_json(&provision_payload)?,
                    now,
                ],
            )
            .map_err(|error| format!("enqueue agent provisioning: {error}"))?;

        let agent = query_agent(&transaction, &agent_id)?
            .ok_or_else(|| "admitted agent disappeared".to_owned())?;
        let assignment = query_assignment(&transaction, &assignment_id)?
            .ok_or_else(|| "admitted assignment disappeared".to_owned())?;
        let execution = query_execution(&transaction, &execution_id)?
            .ok_or_else(|| "admitted execution disappeared".to_owned())?;
        transaction
            .commit()
            .map_err(|error| format!("commit agent admission: {error}"))?;
        record_agent_assignment_admission_metrics(&assignment);
        Ok(AgentAdmission {
            agent,
            assignment,
            execution,
            created: true,
        })
    }

    /// Bind one agent-runner worker invocation to the shared agent execution
    /// service. Admission owns the stable transcript identity, single
    /// assignment, worker/agent mapping, exact grant snapshot, and provisioning
    /// outbox in one transaction. Replay returns those same identities.
    pub(crate) fn admit_direct_worker_agent(
        &self,
        request: &NewDirectWorkerAgentAdmission,
    ) -> Result<AgentAdmission, String> {
        validate_runtime_identifier(&request.invocation_id, "direct worker invocation id", 256)?;
        validate_name(&request.name)?;
        validate_task(&request.task)?;
        if request.workspace_path.trim().is_empty() {
            return Err("direct worker workspace path must not be empty".to_owned());
        }
        if !request.tool_grant.is_array() || !request.limits.is_object() {
            return Err("direct worker grant/limits snapshots have invalid shapes".to_owned());
        }
        if !(1..=8).contains(&request.max_active_children) {
            return Err("max active child agents must be within 1..=8".to_owned());
        }
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("start direct worker agent admission: {error}"))?;
        let invocation = transaction
            .query_row(
                "SELECT worker_id,worker_version,status,trace_id,causal_depth,
                        origin_session_id,agent_session_id
                 FROM worker_invocations WHERE invocation_id=?1",
                [&request.invocation_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, u32>(4)?,
                        row.get::<_, Option<String>>(5)?,
                        row.get::<_, Option<String>>(6)?,
                    ))
                },
            )
            .optional()
            .map_err(|error| format!("load direct worker invocation: {error}"))?
            .ok_or_else(|| {
                format!(
                    "worker invocation '{}' was not found",
                    request.invocation_id
                )
            })?;
        if !matches!(invocation.2.as_str(), "queued" | "running") {
            return Err(format!(
                "worker invocation '{}' cannot admit an agent while {}",
                request.invocation_id, invocation.2
            ));
        }
        if let Some((agent_id, assignment_id)) = transaction
            .query_row(
                "SELECT agent_id,assignment_id FROM direct_worker_agent_runs
                 WHERE worker_invocation_id=?1",
                [&request.invocation_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()
            .map_err(|error| format!("load direct worker agent mapping: {error}"))?
        {
            let agent = require_agent(&transaction, &agent_id, "direct worker replay")?;
            let assignment = query_assignment(&transaction, &assignment_id)?
                .ok_or_else(|| "direct worker replay lost its assignment".to_owned())?;
            if agent.kind != AgentInstanceKind::DirectWorker
                || agent.name != request.name
                || agent.default_model.as_deref() != Some(request.model.as_str())
                || agent.default_reasoning_level != request.reasoning_level
                || agent.tool_grant != request.tool_grant
                || agent.limits != request.limits
                || assignment.task != request.task
                || assignment.context != request.context
                || assignment.model.as_deref() != Some(request.model.as_str())
                || assignment.reasoning_level != request.reasoning_level
                || assignment.authority_snapshot != request.tool_grant
                || assignment.limits_snapshot != request.limits
            {
                return Err("direct worker agent admission idempotency conflict".to_owned());
            }
            let execution = query_execution(&transaction, &assignment.execution_id)?
                .ok_or_else(|| "direct worker replay lost its execution".to_owned())?;
            transaction
                .commit()
                .map_err(|error| format!("commit direct worker replay: {error}"))?;
            return Ok(AgentAdmission {
                agent,
                assignment,
                execution,
                created: false,
            });
        }
        let mut execution = transaction
            .query_row(
                &format!(
                    "SELECT {EXECUTION_COLUMNS} FROM execution_nodes
                     WHERE worker_invocation_id=?1"
                ),
                [&request.invocation_id],
                map_execution,
            )
            .optional()
            .map_err(|error| format!("load direct worker execution: {error}"))?
            .ok_or_else(|| "direct worker invocation lost its execution node".to_owned())?;
        let session_id = format!("agent_session_direct_{}", request.invocation_id);
        let workspace_id = format!("workspace_direct_{}", request.invocation_id);
        let agent_id = format!("agent_direct_{}", request.invocation_id);
        let assignment_id = format!("assignment_direct_{}", request.invocation_id);
        let root_event_id = format!("event_direct_{}", request.invocation_id);
        for (value, label) in [
            (&session_id, "direct worker session id"),
            (&workspace_id, "direct worker workspace id"),
            (&agent_id, "direct worker agent id"),
            (&assignment_id, "direct worker assignment id"),
            (&root_event_id, "direct worker root event id"),
        ] {
            validate_runtime_identifier(value, label, 512)?;
        }
        let management_owner = execution.owner_agent_id.clone().or_else(|| {
            invocation
                .5
                .as_deref()
                .and_then(|session_id| query_agent_by_session(&transaction, session_id).ok())
                .flatten()
                .map(|agent| agent.agent_id)
        });
        let root_session_id = execution
            .root_session_id
            .clone()
            .or_else(|| invocation.5.clone())
            .unwrap_or_else(|| session_id.clone());
        enforce_active_agent_ceiling(
            &transaction,
            &root_session_id,
            None,
            request.max_active_children,
        )?;
        if let Some(existing_session_id) = invocation.6.as_deref()
            && existing_session_id != session_id
        {
            return Err("direct worker invocation is linked to another transcript".to_owned());
        }
        let now = chrono::Utc::now().to_rfc3339();
        transaction
            .execute(
                "UPDATE worker_invocations SET agent_session_id=?2
                 WHERE invocation_id=?1 AND (agent_session_id IS NULL OR agent_session_id=?2)",
                params![request.invocation_id, session_id],
            )
            .map_err(|error| format!("link direct worker transcript: {error}"))?;
        transaction
            .execute(
                "UPDATE execution_nodes
                 SET owner_agent_id=COALESCE(owner_agent_id,?2),
                     root_session_id=COALESCE(root_session_id,?3)
                 WHERE execution_id=?1",
                params![execution.execution_id, management_owner, root_session_id],
            )
            .map_err(|error| format!("bind direct worker execution ownership: {error}"))?;
        transaction
            .execute(
                "INSERT INTO agent_instances(
                    agent_id,session_id,root_session_id,workspace_id,spawned_by_agent_id,
                    management_owner_agent_id,kind,name,visibility,state,default_model,
                    default_reasoning_level,tool_grant_json,write_scopes_json,limits_json,
                    created_at,updated_at
                 ) VALUES (?1,?2,?3,?4,?5,?5,'direct_worker',?6,'nested','provisioning',
                           ?7,?8,?9,?10,?11,?12,?12)",
                params![
                    agent_id,
                    session_id,
                    root_session_id,
                    workspace_id,
                    management_owner,
                    request.name,
                    request.model,
                    request.reasoning_level,
                    encode_json(&request.tool_grant)?,
                    encode_json(&json!(["."]))?,
                    encode_json(&request.limits)?,
                    now,
                ],
            )
            .map_err(|error| format!("insert direct worker agent: {error}"))?;
        transaction
            .execute(
                "UPDATE execution_nodes SET owner_agent_id=?2 WHERE execution_id=?1",
                params![execution.execution_id, agent_id],
            )
            .map_err(|error| format!("transfer direct worker execution ownership: {error}"))?;
        transaction
            .execute(
                "INSERT INTO agent_assignments(
                    assignment_id,execution_id,agent_id,kind,status,admission_key,
                    queue_ordinal,task,context_json,model,reasoning_level,
                    authority_snapshot_json,resource_snapshot_json,
                    write_scopes_snapshot_json,limits_snapshot_json,deadline_at,
                    created_at,accepted_at,updated_at
                 ) VALUES (?1,?2,?3,'direct_worker','accepted',?4,0,?5,?6,?7,?8,
                           ?9,?10,?11,?12,?13,?14,?14,?14)",
                params![
                    assignment_id,
                    execution.execution_id,
                    agent_id,
                    format!("direct-worker:{}", request.invocation_id),
                    request.task,
                    encode_json(&request.context)?,
                    request.model,
                    request.reasoning_level,
                    encode_json(&request.tool_grant)?,
                    encode_json(&json!({
                        "workerInvocationId":request.invocation_id,
                        "workerId":invocation.0,
                        "workerVersion":invocation.1,
                    }))?,
                    encode_json(&json!(["."]))?,
                    encode_json(&request.limits)?,
                    request.deadline_at,
                    now,
                ],
            )
            .map_err(|error| format!("insert direct worker assignment: {error}"))?;
        transaction
            .execute(
                "INSERT INTO direct_worker_agent_runs(
                    worker_invocation_id,agent_id,assignment_id,created_at
                 ) VALUES (?1,?2,?3,?4)",
                params![request.invocation_id, agent_id, assignment_id, now],
            )
            .map_err(|error| format!("map direct worker agent assignment: {error}"))?;
        let channel_id = canonical_agent_channel_id(&agent_id, &agent_id);
        transaction
            .execute(
                "INSERT INTO agent_outbox(
                    outbox_id,deduplication_key,kind,agent_id,assignment_id,
                    execution_id,payload_json,created_at
                 ) VALUES (?1,?2,'provision',?3,?4,?5,?6,?7)",
                params![
                    format!("agent_outbox_direct_{}", request.invocation_id),
                    format!("direct-worker-provision:{}", request.invocation_id),
                    agent_id,
                    assignment_id,
                    execution.execution_id,
                    encode_json(&json!({
                        "messagePurpose":"assignment_admission",
                        "directWorker":true,
                        "agentId":agent_id,
                        "sessionId":session_id,
                        "rootEventId":root_event_id,
                        "rootSessionId":root_session_id,
                        "workspaceId":workspace_id,
                        "workspacePath":request.workspace_path,
                        "assignmentId":assignment_id,
                        "executionId":execution.execution_id,
                        "name":request.name,
                        "task":request.task,
                        "context":request.context,
                        "model":request.model,
                        "reasoningLevel":request.reasoning_level,
                        "messageId":format!("agent_message_direct_{assignment_id}"),
                        "channelId":channel_id,
                        "kind":"instruction",
                        "authority":"engine",
                        "text":request.task,
                        "sourceAgentId":agent_id,
                        "sourceSessionId":session_id,
                        "sourceName":"Tron Worker Engine",
                        "targetAgentId":agent_id,
                        "targetSessionId":session_id,
                        "replyTo":null,
                        "traceId":invocation.3,
                        "causalDepth":invocation.4,
                        "autonomousHop":0,
                        "actionable":true,
                        "expiresAt":request.deadline_at,
                    }))?,
                    now,
                ],
            )
            .map_err(|error| format!("enqueue direct worker provisioning: {error}"))?;
        append_execution_event_in_tx(
            &transaction,
            &execution.execution_id,
            "direct_worker_admitted",
            &json!({"agentId":agent_id,"assignmentId":assignment_id}),
            &now,
        )?;
        let agent = require_agent(&transaction, &agent_id, "admitted direct worker")?;
        let assignment = query_assignment(&transaction, &assignment_id)?
            .ok_or_else(|| "admitted direct worker assignment disappeared".to_owned())?;
        execution.owner_agent_id = Some(agent_id.clone());
        execution.assignment_id = Some(assignment_id.clone());
        transaction
            .commit()
            .map_err(|error| format!("commit direct worker agent admission: {error}"))?;
        record_agent_assignment_admission_metrics(&assignment);
        Ok(AgentAdmission {
            agent,
            assignment,
            execution,
            created: true,
        })
    }
}
