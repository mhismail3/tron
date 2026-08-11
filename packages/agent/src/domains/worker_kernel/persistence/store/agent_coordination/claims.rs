//! Durable scoped-write and whole-workspace process claims.
//!
//! Claim scheduling, process gates, recovery, and cancellation preserve FIFO ownership.

use super::*;

impl WorkerStore {
    pub(crate) fn request_workspace_claim(
        &self,
        request: &NewWorkspaceClaim,
    ) -> Result<WorkspaceClaimRecord, String> {
        validate_runtime_identifier(&request.idempotency_key, "workspace claim key", 256)?;
        validate_runtime_identifier(&request.workspace_id, "workspace id", 256)?;
        let canonical_scope = validate_canonical_scope(request.kind, &request.canonical_scope)?;
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("start workspace claim request: {error}"))?;
        let (execution_id, agent_id, holder_session_id) = match &request.holder {
            WorkspaceClaimHolder::AgentExecution {
                execution_id,
                agent_id,
            } => {
                validate_runtime_identifier(execution_id, "workspace claim execution", 256)?;
                validate_runtime_identifier(agent_id, "workspace claim agent", 256)?;
                let execution = query_execution(&transaction, execution_id)?
                    .ok_or_else(|| format!("execution '{execution_id}' was not found"))?;
                if execution.owner_agent_id.as_deref() != Some(agent_id.as_str()) {
                    return Err("workspace claim agent does not own the execution".to_owned());
                }
                (Some(execution_id.as_str()), Some(agent_id.as_str()), None)
            }
            WorkspaceClaimHolder::Session { session_id } => {
                validate_runtime_identifier(session_id, "workspace claim session", 256)?;
                (None, None, Some(session_id.as_str()))
            }
        };
        reject_ambiguous_case_scope(&transaction, &request.workspace_id, &canonical_scope)?;
        let now = chrono::Utc::now().to_rfc3339();
        transaction
            .execute(
                "INSERT OR IGNORE INTO agent_write_claims(
                    claim_id,idempotency_key,execution_id,agent_id,holder_session_id,
                    workspace_id,kind,canonical_scope,state,requested_at
                 ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,'queued',?9)",
                params![
                    format!("agent_claim_{}", uuid::Uuid::now_v7()),
                    request.idempotency_key,
                    execution_id,
                    agent_id,
                    holder_session_id,
                    request.workspace_id,
                    request.kind.as_str(),
                    canonical_scope,
                    now,
                ],
            )
            .map_err(|error| format!("insert workspace claim: {error}"))?;
        let existing = query_claim_by_key(&transaction, &request.idempotency_key)?
            .ok_or_else(|| "workspace claim disappeared".to_owned())?;
        if existing.execution_id.as_deref() != execution_id
            || existing.agent_id.as_deref() != agent_id
            || existing.holder_session_id.as_deref() != holder_session_id
            || existing.workspace_id != request.workspace_id
            || existing.kind != request.kind
            || existing.canonical_scope != canonical_scope
        {
            return Err("workspace claim idempotency conflict".to_owned());
        }
        promote_workspace_claims_in_tx(&transaction, &request.workspace_id, &now)?;
        let record = query_claim_by_key(&transaction, &request.idempotency_key)?
            .ok_or_else(|| "scheduled workspace claim disappeared".to_owned())?;
        transaction
            .commit()
            .map_err(|error| format!("commit workspace claim request: {error}"))?;
        Ok(record)
    }

    pub(crate) fn release_workspace_claim(
        &self,
        claim_id: &str,
        cancelled: bool,
    ) -> Result<Vec<WorkspaceClaimRecord>, String> {
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("start workspace claim release: {error}"))?;
        let claim = query_claim(&transaction, claim_id)?
            .ok_or_else(|| format!("workspace claim '{claim_id}' was not found"))?;
        let now = chrono::Utc::now().to_rfc3339();
        if !matches!(
            claim.state,
            WorkspaceClaimState::Released | WorkspaceClaimState::Cancelled
        ) {
            transaction
                .execute(
                    "UPDATE agent_write_claims SET state=?2,released_at=?3
                     WHERE claim_id=?1 AND state IN ('queued','held')",
                    params![
                        claim_id,
                        if cancelled { "cancelled" } else { "released" },
                        now,
                    ],
                )
                .map_err(|error| format!("release workspace claim: {error}"))?;
        }
        let promoted = promote_workspace_claims_in_tx(&transaction, &claim.workspace_id, &now)?;
        transaction
            .commit()
            .map_err(|error| format!("commit workspace claim release: {error}"))?;
        Ok(promoted)
    }

    /// Read one durable claim while an async caller is parked. Rechecking the
    /// row after registering its process-local notification closes the normal
    /// completion-before-wait race; bounded polling remains the lost-signal
    /// and restart fallback.
    pub(crate) fn workspace_claim(
        &self,
        claim_id: &str,
    ) -> Result<Option<WorkspaceClaimRecord>, String> {
        validate_runtime_identifier(claim_id, "workspace claim id", 256)?;
        let connection = self.connection()?;
        query_claim(&connection, claim_id)
    }

    /// Bind the exact spawned direct-child/process-group id to a held process
    /// claim. Its OS-reported process birth identity is captured in the same
    /// durable row; startup recovery re-reads and matches that identity before
    /// signalling an exact process group, preventing PID reuse from targeting
    /// unrelated local work.
    pub(crate) fn bind_workspace_process_claim(
        &self,
        claim_id: &str,
        process_id: u32,
    ) -> Result<WorkspaceClaimRecord, String> {
        if process_id == 0 || process_id > i32::MAX as u32 {
            return Err("workspace process id must be a positive signed process id".to_owned());
        }
        let process_identity = workspace_process_identity(process_id)?
            .ok_or_else(|| "workspace process disappeared before durable binding".to_owned())?;
        let connection = self.connection()?;
        let changed = connection
            .execute(
                "UPDATE agent_write_claims SET process_id=?2,process_identity=?3
                 WHERE claim_id=?1 AND kind='workspace_process' AND state='held'
                   AND (process_id IS NULL
                        OR (process_id=?2 AND process_identity=?3))",
                params![claim_id, i64::from(process_id), process_identity],
            )
            .map_err(|error| format!("bind workspace process claim: {error}"))?;
        if changed == 0 {
            let existing = query_claim(&connection, claim_id)?
                .ok_or_else(|| format!("workspace claim '{claim_id}' was not found"))?;
            if existing.kind != WorkspaceClaimKind::WorkspaceProcess
                || existing.state != WorkspaceClaimState::Held
                || existing.process_id != Some(process_id)
                || existing.process_identity.as_deref() != Some(process_identity.as_str())
            {
                return Err("workspace process claim is not held by this process".to_owned());
            }
            return Ok(existing);
        }
        query_claim(&connection, claim_id)?
            .ok_or_else(|| "bound workspace process claim disappeared".to_owned())
    }

    /// Create a private, claim-specific admission gate before spawning a
    /// workspace process. The child waits on this gate and therefore cannot
    /// execute user code during the spawn-to-durable-bind crash window.
    pub(crate) fn prepare_workspace_process_gate(
        &self,
        claim_id: &str,
    ) -> Result<std::path::PathBuf, String> {
        validate_workspace_process_gate_id(claim_id)?;
        let connection = self.connection()?;
        let claim = query_claim(&connection, claim_id)?
            .ok_or_else(|| format!("workspace claim '{claim_id}' was not found"))?;
        if claim.kind != WorkspaceClaimKind::WorkspaceProcess
            || claim.state != WorkspaceClaimState::Held
            || claim.process_id.is_some()
        {
            return Err("workspace process gate requires an unbound held process claim".to_owned());
        }
        drop(connection);
        let root = self
            .home
            .join(crate::shared::foundation::paths::dirs::INTERNAL)
            .join(crate::shared::foundation::paths::dirs::RUN)
            .join(WORKSPACE_PROCESS_GATE_DIRECTORY);
        std::fs::create_dir_all(&root)
            .map_err(|error| format!("create workspace process gate root: {error}"))?;
        crate::shared::foundation::home::set_private_directory_permissions(&root)
            .map_err(|error| format!("secure workspace process gate root: {error}"))?;
        let gate = root.join(claim_id);
        std::fs::create_dir(&gate).map_err(|error| {
            format!("create workspace process gate {}: {error}", gate.display())
        })?;
        crate::shared::foundation::home::set_private_directory_permissions(&gate).map_err(
            |error| format!("secure workspace process gate {}: {error}", gate.display()),
        )?;
        Ok(gate)
    }

    /// Open a prepared process gate only after PID and birth identity are
    /// durable. The create-new marker makes duplicate releases fail closed.
    pub(crate) fn allow_workspace_process_gate(&self, claim_id: &str) -> Result<(), String> {
        validate_workspace_process_gate_id(claim_id)?;
        let connection = self.connection()?;
        let claim = query_claim(&connection, claim_id)?
            .ok_or_else(|| format!("workspace claim '{claim_id}' was not found"))?;
        if claim.kind != WorkspaceClaimKind::WorkspaceProcess
            || claim.state != WorkspaceClaimState::Held
            || claim.process_id.is_none()
            || claim.process_identity.is_none()
        {
            return Err("workspace process gate requires a durably bound process claim".to_owned());
        }
        drop(connection);
        let gate = self.workspace_process_gate_path(claim_id);
        if !gate.is_dir() {
            return Err("workspace process admission gate disappeared before release".to_owned());
        }
        let marker = gate.join("go");
        let mut file = std::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&marker)
            .map_err(|error| format!("open workspace process admission gate: {error}"))?;
        use std::io::Write as _;
        file.write_all(b"go\n")
            .map_err(|error| format!("write workspace process admission gate: {error}"))?;
        file.sync_all()
            .map_err(|error| format!("sync workspace process admission gate: {error}"))?;
        Ok(())
    }

    /// Close a process admission gate. A helper still waiting for durable
    /// binding observes the missing directory and exits without running user
    /// code.
    pub(crate) fn abort_workspace_process_gate(&self, claim_id: &str) -> Result<(), String> {
        validate_workspace_process_gate_id(claim_id)?;
        let gate = self.workspace_process_gate_path(claim_id);
        match std::fs::remove_dir_all(&gate) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(format!(
                "remove workspace process gate {}: {error}",
                gate.display()
            )),
        }
    }

    fn workspace_process_gate_path(&self, claim_id: &str) -> std::path::PathBuf {
        self.home
            .join(crate::shared::foundation::paths::dirs::INTERNAL)
            .join(crate::shared::foundation::paths::dirs::RUN)
            .join(WORKSPACE_PROCESS_GATE_DIRECTORY)
            .join(claim_id)
    }

    /// Bounded authoritative resource view. At least one of `agent_id` or
    /// `workspace_id` must be supplied so client inspection cannot accidentally
    /// turn into an unbounded profile scan.
    pub(crate) fn list_workspace_claims(
        &self,
        agent_id: Option<&str>,
        workspace_id: Option<&str>,
        include_terminal: bool,
        limit: usize,
    ) -> Result<Vec<WorkspaceClaimRecord>, String> {
        if agent_id.is_none() && workspace_id.is_none() {
            return Err("workspace claim inspection requires agentId or workspaceId".to_owned());
        }
        if let Some(agent_id) = agent_id {
            validate_runtime_identifier(agent_id, "agent id", 256)?;
        }
        if let Some(workspace_id) = workspace_id {
            validate_runtime_identifier(workspace_id, "workspace id", 256)?;
        }
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(&format!(
                "SELECT {CLAIM_COLUMNS} FROM agent_write_claims
                 WHERE (?1 IS NULL OR agent_id=?1 OR holder_session_id=(
                        SELECT session_id FROM agent_instances WHERE agent_id=?1
                       ))
                   AND (?2 IS NULL OR workspace_id=?2)
                   AND (?3=1 OR state IN ('queued','held'))
                 ORDER BY CASE state WHEN 'held' THEN 0 WHEN 'queued' THEN 1 ELSE 2 END,
                          requested_at,claim_id LIMIT ?4"
            ))
            .map_err(|error| format!("prepare workspace claim inspection: {error}"))?;
        statement
            .query_map(
                params![
                    agent_id,
                    workspace_id,
                    include_terminal,
                    i64::try_from(limit.clamp(1, 200)).unwrap_or(200),
                ],
                map_claim,
            )
            .map_err(|error| format!("query workspace claim inspection: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode workspace claim inspection: {error}"))
    }

    /// Cancel claims whose in-process owners cannot survive server restart.
    /// For a captured process, signal only an exact process group whose live
    /// OS birth identity still matches the durable spawn evidence. A missing
    /// or mismatched process is treated as already gone; PID reuse is never
    /// signalled.
    pub(in crate::domains::worker_kernel::persistence::store) fn recover_interrupted_workspace_claims(
        &self,
    ) -> Result<u64, String> {
        let connection = self.connection()?;
        let active = {
            let mut statement = connection
                .prepare(&format!(
                    "SELECT {CLAIM_COLUMNS} FROM agent_write_claims
                     WHERE state IN ('queued','held') ORDER BY requested_at,claim_id"
                ))
                .map_err(|error| format!("prepare interrupted workspace claims: {error}"))?;
            statement
                .query_map([], map_claim)
                .map_err(|error| format!("query interrupted workspace claims: {error}"))?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(|error| format!("decode interrupted workspace claims: {error}"))?
        };
        for claim in &active {
            if claim.kind == WorkspaceClaimKind::WorkspaceProcess {
                // Removing a closed gate makes an unbound helper exit without
                // executing user code. A bound process may already have
                // crossed the gate, so it additionally requires exact
                // birth-identity-checked process-group cancellation.
                self.abort_workspace_process_gate(&claim.claim_id)?;
                if claim.state == WorkspaceClaimState::Held
                    && let Some(process_id) = claim.process_id
                    && let Some(process_identity) = claim.process_identity.as_deref()
                {
                    cancel_captured_workspace_process(process_id, process_identity);
                }
            }
        }
        if active.is_empty() {
            return Ok(0);
        }
        let now = chrono::Utc::now().to_rfc3339();
        let changed = connection
            .execute(
                "UPDATE agent_write_claims
                 SET state='cancelled',released_at=?1
                 WHERE state IN ('queued','held')",
                [now],
            )
            .map_err(|error| format!("cancel interrupted workspace claims: {error}"))?;
        Ok(u64::try_from(changed).unwrap_or(u64::MAX))
    }

    /// Return every live assignment in an owned management subtree without a
    /// presentation-page cap. Structured cancellation uses this exact set;
    /// historical rows must never push current work beyond an arbitrary UI
    /// limit. Descendants are returned before their owners so callers can
    /// terminalize leaves before parents.
    pub(crate) fn nonterminal_agent_assignments_for_owned_subtree(
        &self,
        agent_id: &str,
    ) -> Result<Vec<AgentAssignmentRecord>, String> {
        validate_runtime_identifier(agent_id, "agent id", 256)?;
        let connection = self.connection()?;
        if query_agent(&connection, agent_id)?.is_none() {
            return Err(format!("agent '{agent_id}' was not found"));
        }
        let mut statement = connection
            .prepare(&format!(
                "WITH RECURSIVE subtree(agent_id,depth) AS (
                    SELECT agent_id,0 FROM agent_instances WHERE agent_id=?1
                    UNION ALL
                    SELECT child.agent_id,subtree.depth+1
                    FROM agent_instances child
                    JOIN subtree ON child.management_owner_agent_id=subtree.agent_id
                 )
                 SELECT {ASSIGNMENT_COLUMNS}
                 FROM agent_assignments
                 WHERE agent_id IN (SELECT agent_id FROM subtree)
                   AND status IN ('offered','accepted','queued','running','waiting')
                 ORDER BY (
                    SELECT depth FROM subtree
                    WHERE subtree.agent_id=agent_assignments.agent_id
                 ) DESC,
                 queue_ordinal,created_at,assignment_id"
            ))
            .map_err(|error| format!("prepare owned subtree assignments: {error}"))?;
        statement
            .query_map([agent_id], map_assignment)
            .map_err(|error| format!("query owned subtree assignments: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode owned subtree assignments: {error}"))
    }

    /// Repair process-local custody without replacing stable agent/session or
    /// assignment identities. Workspace claims are reconciled first because a
    /// blocking mutation future or captured process tree cannot remain owned by
    /// the restarted runtime.
    pub(in crate::domains::worker_kernel::persistence::store) fn recover_interrupted_agent_coordination(
        &self,
    ) -> Result<(), String> {
        let recovered_claims = self.recover_interrupted_workspace_claims()?;
        if recovered_claims > 0 {
            metrics::counter!("agent_workspace_claim_recoveries_total").increment(recovered_claims);
        }
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("start interrupted agent coordination recovery: {error}"))?;
        let recovery_instant = chrono::Utc::now();
        let now = recovery_instant.to_rfc3339();
        let outbox_now = coordination_outbox_timestamp(recovery_instant);
        let recovered_attempts = transaction
            .execute(
                "UPDATE agent_assignment_attempts
                 SET status='interrupted',completed_at=?1,
                     error=COALESCE(error,'engine restarted during agent attempt')
                 WHERE status='running'",
                [&now],
            )
            .map_err(|error| format!("recover interrupted agent attempts: {error}"))?;
        let recovered_assignments = transaction
            .execute(
                "UPDATE agent_assignments SET status='queued',updated_at=?1
                 WHERE status='running'",
                [&now],
            )
            .map_err(|error| format!("requeue interrupted agent assignments: {error}"))?;
        let recovered_outbox = transaction
            .execute(
                "UPDATE agent_outbox
                 SET disposition='pending',processed_at=NULL,next_attempt_at=?1
                 WHERE disposition='importing'",
                [&outbox_now],
            )
            .map_err(|error| format!("recover claimed agent outbox rows: {error}"))?;
        transaction
            .execute(
                "UPDATE agent_instances
                 SET state='active',updated_at=?1
                 WHERE state NOT IN ('provisioning','closing','closed')
                   AND EXISTS(
                    SELECT 1 FROM agent_assignments assignment
                    WHERE assignment.agent_id=agent_instances.agent_id
                      AND assignment.status IN ('accepted','queued','running')
                 )",
                [now],
            )
            .map_err(|error| format!("recover reusable agent state: {error}"))?;
        transaction
            .commit()
            .map_err(|error| format!("commit interrupted agent coordination recovery: {error}"))?;
        if recovered_attempts > 0 {
            metrics::counter!(
                "agent_coordination_recoveries_total",
                "kind" => "assignment_attempt"
            )
            .increment(recovered_attempts as u64);
        }
        if recovered_assignments > 0 {
            metrics::counter!(
                "agent_coordination_recoveries_total",
                "kind" => "assignment"
            )
            .increment(recovered_assignments as u64);
        }
        if recovered_outbox > 0 {
            metrics::counter!(
                "agent_coordination_recoveries_total",
                "kind" => "outbox_claim"
            )
            .increment(recovered_outbox as u64);
        }
        Ok(())
    }
}
