//! Stable root/child agent identity and transcript admission.

use super::*;

impl EventStore {
    /// Lazily install the deterministic stable identity for one visible root
    /// session. Replays return the original row without rewriting defaults.
    pub(crate) fn ensure_core_root_agent(&self, request: &EnsureRootAgent) -> Result<AgentRecord> {
        validate_identifier("root transcript session id", &request.transcript_session_id)?;
        validate_name(&request.name)?;
        validate_defaults(&request.defaults)?;
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            if let Some(existing) =
                query_agent_by_session(&transaction, &request.transcript_session_id)?
            {
                if existing.parent_agent_id.is_some()
                    || existing.visibility != AgentVisibility::Visible
                {
                    return Err(EventStoreError::InvalidOperation(
                        "root session is already owned by a nested agent".to_owned(),
                    ));
                }
                transaction.commit()?;
                return Ok(existing);
            }
            let session = SessionRepo::get_by_id(&transaction, &request.transcript_session_id)?
                .ok_or_else(|| {
                    EventStoreError::SessionNotFound(request.transcript_session_id.clone())
                })?;
            if session.is_internal_session() {
                return Err(EventStoreError::InvalidOperation(
                    "a visible root agent cannot own an internal transcript".to_owned(),
                ));
            }
            let agent_id = stable_id("agent_root", &[&request.transcript_session_id]);
            let now = chrono::Utc::now().to_rfc3339();
            let mut defaults = request.defaults.clone();
            if defaults.model.is_none() {
                defaults.model = Some(session.latest_model.clone());
            }
            insert_agent_in_tx(
                &transaction,
                &AgentRecord {
                    agent_id: agent_id.clone(),
                    transcript_session_id: session.id,
                    root_agent_id: agent_id,
                    workspace_id: session.workspace_id,
                    parent_agent_id: None,
                    management_owner_agent_id: None,
                    name: request.name.clone(),
                    visibility: AgentVisibility::Visible,
                    lifecycle: AgentLifecycle::Open,
                    defaults,
                    created_at: now.clone(),
                    updated_at: now,
                    closed_at: None,
                },
            )?;
            let record = query_agent_by_session(&transaction, &request.transcript_session_id)?
                .ok_or_else(|| EventStoreError::Internal("root agent disappeared".to_owned()))?;
            transaction.commit()?;
            Ok(record)
        })
    }

    /// Atomically create a hidden persistent transcript, stable child, and its
    /// first queued assignment. The admission key identifies the whole unit.
    pub(crate) fn spawn_core_agent(&self, request: &SpawnAgent) -> Result<AgentAdmission> {
        validate_admission_key(&request.admission_key)?;
        validate_identifier("parent agent id", &request.parent_agent_id)?;
        validate_name(&request.name)?;
        validate_task(&request.task)?;
        validate_json_size("spawn context", &request.context, MAX_CONTEXT_BYTES)?;
        validate_defaults(&request.defaults)?;
        validate_optional_timestamp("deadline", request.deadline_at.as_deref())?;
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            if let Some(existing) =
                query_assignment_by_admission_key(&transaction, &request.admission_key)?
            {
                let agent = query_agent(&transaction, &existing.agent_id)?.ok_or_else(|| {
                    EventStoreError::Internal("spawned agent disappeared".to_owned())
                })?;
                validate_spawn_replay(&agent, &existing, request)?;
                transaction.commit()?;
                return Ok(AgentAdmission {
                    agent,
                    assignment: existing,
                    created: false,
                });
            }
            let parent = require_open_agent(&transaction, &request.parent_agent_id)?;
            let parent_session =
                SessionRepo::get_by_id(&transaction, &parent.transcript_session_id)?.ok_or_else(
                    || EventStoreError::SessionNotFound(parent.transcript_session_id.clone()),
                )?;
            validate_parent_assignment(
                &transaction,
                request.parent_assignment_id.as_deref(),
                Some(&parent.agent_id),
            )?;
            let mut defaults = request.defaults.clone();
            if defaults.model.is_none() {
                defaults.model = parent
                    .defaults
                    .model
                    .clone()
                    .or(Some(parent_session.latest_model));
            }
            let tags = vec![AGENT_SESSION_TAG.to_owned()];
            let transcript = create_session_in_tx(
                &transaction,
                &CreateSessionInTxOptions {
                    model: defaults.model.as_deref().unwrap_or("unknown"),
                    workspace_path: &parent_session.working_directory,
                    title: Some(&request.name),
                    provider: None,
                    tags: Some(&tags),
                },
            )?;
            let agent_id = stable_id("agent", &[&request.admission_key]);
            let now = chrono::Utc::now().to_rfc3339();
            let agent = AgentRecord {
                agent_id: agent_id.clone(),
                transcript_session_id: transcript.session.id,
                root_agent_id: parent.root_agent_id,
                workspace_id: parent.workspace_id,
                parent_agent_id: Some(parent.agent_id.clone()),
                management_owner_agent_id: Some(parent.agent_id.clone()),
                name: request.name.clone(),
                visibility: AgentVisibility::Nested,
                lifecycle: AgentLifecycle::Open,
                defaults: defaults.clone(),
                created_at: now.clone(),
                updated_at: now,
                closed_at: None,
            };
            insert_agent_in_tx(&transaction, &agent)?;
            let assignment = admit_assignment_in_tx(
                &transaction,
                &NewAssignment {
                    admission_key: request.admission_key.clone(),
                    agent_id,
                    requested_by_agent_id: Some(parent.agent_id),
                    parent_assignment_id: request.parent_assignment_id.clone(),
                    retry_of_assignment_id: None,
                    kind: AssignmentKind::Instruction,
                    task: request.task.clone(),
                    context: request.context.clone(),
                    trace_id: request.trace_id.clone(),
                    autonomous_hop: request.autonomous_hop,
                    model: defaults.model.clone(),
                    reasoning_level: defaults.reasoning_level.clone(),
                    capability_grant: Some(defaults.capability_grant.clone()),
                    write_scopes: Some(defaults.write_scopes.clone()),
                    limits: Some(defaults.limits.clone()),
                    deadline_at: request.deadline_at.clone(),
                },
            )?;
            transaction.commit()?;
            Ok(AgentAdmission {
                agent,
                assignment,
                created: true,
            })
        })
    }
}
