//! Quiescent agent configuration, role upgrade, closure, promotion, and subtree reads.
//!
//! Lifecycle mutations preserve immutable lineage and reject active custody.

use super::*;

impl WorkerStore {
    pub(crate) fn configure_agent(
        &self,
        request: &AgentConfigurationUpdate,
    ) -> Result<AgentInstanceRecord, String> {
        validate_write_scope_snapshot(&request.write_scopes, "agent write scopes")?;
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("start reusable agent configuration: {error}"))?;
        let agent = require_quiescent_agent(&transaction, &request.agent_id, "configure")?;
        if agent.kind == AgentInstanceKind::Root {
            return Err("visible root agents are configured through session settings".to_owned());
        }
        let now = chrono::Utc::now().to_rfc3339();
        transaction
            .execute(
                "UPDATE agent_instances
                 SET default_model=?2,default_reasoning_level=?3,tool_grant_json=?4,
                     write_scopes_json=?5,limits_json=?6,updated_at=?7
                 WHERE agent_id=?1 AND state='idle'",
                params![
                    request.agent_id,
                    request.model,
                    request.reasoning_level,
                    encode_json(&request.tool_grant)?,
                    encode_json(&request.write_scopes)?,
                    encode_json(&request.limits)?,
                    now,
                ],
            )
            .map_err(|error| format!("configure reusable agent: {error}"))?;
        let record = query_agent(&transaction, &request.agent_id)?
            .ok_or_else(|| "configured reusable agent disappeared".to_owned())?;
        transaction
            .commit()
            .map_err(|error| format!("commit reusable agent configuration: {error}"))?;
        Ok(record)
    }

    pub(crate) fn update_agent_role(
        &self,
        request: &AgentRoleUpdate,
    ) -> Result<AgentInstanceRecord, String> {
        validate_runtime_identifier(&request.role_id, "agent role id", 96)?;
        validate_runtime_identifier(&request.role_version, "agent role version", 96)?;
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("start reusable agent role update: {error}"))?;
        let agent = require_quiescent_agent(&transaction, &request.agent_id, "upgrade role")?;
        if agent.kind != AgentInstanceKind::Role {
            return Err("only named-role agents can upgrade role versions".to_owned());
        }
        let role_exists = transaction
            .query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM worker_versions WHERE worker_id=?1 AND version=?2
                 )",
                params![request.role_id, request.role_version],
                |row| row.get::<_, bool>(0),
            )
            .map_err(|error| format!("verify immutable agent role version: {error}"))?;
        if !role_exists {
            return Err(format!(
                "agent role '{}@{}' was not found",
                request.role_id, request.role_version
            ));
        }
        let now = chrono::Utc::now().to_rfc3339();
        transaction
            .execute(
                "UPDATE agent_instances
                 SET role_id=?2,role_version=?3,default_model=?4,
                     default_reasoning_level=?5,tool_grant_json=?6,
                     limits_json=?7,updated_at=?8
                 WHERE agent_id=?1 AND state='idle' AND kind='role'",
                params![
                    request.agent_id,
                    request.role_id,
                    request.role_version,
                    request.model,
                    request.reasoning_level,
                    encode_json(&request.tool_grant)?,
                    encode_json(&request.limits)?,
                    now,
                ],
            )
            .map_err(|error| format!("upgrade reusable agent role: {error}"))?;
        let record = query_agent(&transaction, &request.agent_id)?
            .ok_or_else(|| "upgraded role agent disappeared".to_owned())?;
        transaction
            .commit()
            .map_err(|error| format!("commit reusable agent role update: {error}"))?;
        Ok(record)
    }

    /// Close one idle nested agent and its entirely idle owned subtree. This
    /// does not rewrite immutable lineage or transcript identities.
    pub(crate) fn close_agent_subtree(&self, agent_id: &str) -> Result<Vec<String>, String> {
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("start reusable agent close: {error}"))?;
        let root = require_agent(&transaction, agent_id, "close target")?;
        if root.kind == AgentInstanceKind::Root {
            return Err("visible root agents cannot be closed by agent management".to_owned());
        }
        let agent_ids = owned_agent_subtree(&transaction, agent_id)?;
        if agent_ids.iter().all(|candidate| {
            query_agent(&transaction, candidate)
                .ok()
                .flatten()
                .is_some_and(|agent| agent.state == AgentInstanceState::Closed)
        }) {
            transaction
                .commit()
                .map_err(|error| format!("commit idempotent reusable agent close: {error}"))?;
            return Ok(agent_ids);
        }
        for candidate in &agent_ids {
            let candidate_agent = require_agent(&transaction, candidate, "close")?;
            if candidate_agent.state != AgentInstanceState::Closed {
                require_quiescent_agent(&transaction, candidate, "close")?;
            }
        }
        let now = chrono::Utc::now().to_rfc3339();
        for candidate in agent_ids.iter().rev() {
            transaction
                .execute(
                    "UPDATE agent_instances
                     SET state='closed',closed_at=?2,updated_at=?2
                     WHERE agent_id=?1 AND state='idle'",
                    params![candidate, now],
                )
                .map_err(|error| format!("close reusable agent '{candidate}': {error}"))?;
            transaction
                .execute(
                    "UPDATE agent_management_grants SET revoked_at=?2
                     WHERE (target_agent_id=?1 OR grantee_agent_id=?1) AND revoked_at IS NULL",
                    params![candidate, now],
                )
                .map_err(|error| format!("revoke closed agent management grants: {error}"))?;
            transaction
                .execute(
                    "INSERT OR IGNORE INTO agent_outbox(
                        outbox_id,deduplication_key,kind,agent_id,payload_json,created_at
                     ) VALUES (?1,?2,'projection',?3,?4,?5)",
                    params![
                        format!("agent_outbox_{}", uuid::Uuid::now_v7()),
                        format!("agent-closed:{candidate}"),
                        candidate,
                        encode_json(&json!({"agentId":candidate,"state":"closed"}))?,
                        now,
                    ],
                )
                .map_err(|error| format!("enqueue closed agent projection: {error}"))?;
        }
        transaction
            .commit()
            .map_err(|error| format!("commit reusable agent close: {error}"))?;
        Ok(agent_ids)
    }

    /// Detach one quiescent nested agent into the ordinary user-owned session
    /// index without changing its stable identity, transcript, or spawn
    /// lineage. The outbox makes the EventStore visibility update retryable.
    pub(crate) fn promote_agent(
        &self,
        agent_id: &str,
        idempotency_key: &str,
    ) -> Result<AgentInstanceRecord, String> {
        validate_runtime_identifier(idempotency_key, "agent promotion key", 256)?;
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("start reusable agent promotion: {error}"))?;
        let current = require_agent(&transaction, agent_id, "promotion target")?;
        if current.kind == AgentInstanceKind::Root {
            return Err("root agents are already user-owned and visible".to_owned());
        }
        let _ = require_quiescent_agent(&transaction, agent_id, "promote")?;
        let descendants = owned_agent_subtree(&transaction, agent_id)?;
        for descendant in descendants.iter().skip(1) {
            let descendant = require_agent(&transaction, descendant, "promotion descendant")?;
            if descendant.state != AgentInstanceState::Closed {
                require_quiescent_agent(&transaction, &descendant.agent_id, "promote")?;
            }
        }
        let now = chrono::Utc::now().to_rfc3339();
        // Promotion transfers lifecycle authority to the user. Revoke every
        // explicit management edge touching the promoted lineage so neither a
        // former peer nor an agent inside the detached subtree retains model-
        // level control across that boundary. Rows remain immutable audit
        // evidence through their revocation timestamp.
        for descendant_id in &descendants {
            transaction
                .execute(
                    "UPDATE agent_management_grants SET revoked_at=?2
                     WHERE revoked_at IS NULL AND (
                        target_agent_id=?1 OR grantee_agent_id=?1 OR granted_by_agent_id=?1
                     )",
                    params![descendant_id, now],
                )
                .map_err(|error| format!("revoke promoted lineage management grants: {error}"))?;
        }
        // Promotion makes this stable agent the lifecycle root of its visible
        // transcript. Re-home its idle owned subtree for future budgets and
        // discovery without touching immutable spawn lineage or historical
        // execution-node provenance.
        for descendant_id in &descendants {
            transaction
                .execute(
                    "UPDATE agent_instances SET root_session_id=?2,updated_at=?3
                     WHERE agent_id=?1",
                    params![descendant_id, current.session_id, now],
                )
                .map_err(|error| {
                    format!("transfer promoted agent subtree session ownership: {error}")
                })?;
        }
        transaction
            .execute(
                "UPDATE agent_instances
                 SET visibility='visible',management_owner_agent_id=NULL,updated_at=?2
                 WHERE agent_id=?1 AND visibility='nested' AND state='idle'",
                params![agent_id, now],
            )
            .map_err(|error| format!("detach promoted agent ownership: {error}"))?;
        let promoted = query_agent(&transaction, agent_id)?
            .ok_or_else(|| "promoted reusable agent disappeared".to_owned())?;
        transaction
            .execute(
                "INSERT OR IGNORE INTO agent_outbox(
                    outbox_id,deduplication_key,kind,agent_id,payload_json,created_at
                 ) VALUES (?1,?2,'projection',?3,?4,?5)",
                params![
                    format!("agent_outbox_{}", uuid::Uuid::now_v7()),
                    idempotency_key,
                    agent_id,
                    encode_json(&json!({
                        "kind":"promote_agent_session",
                        "agentId":agent_id,
                        "sessionId":promoted.session_id,
                    }))?,
                    now,
                ],
            )
            .map_err(|error| format!("enqueue promoted agent projection: {error}"))?;
        let outbox_matches = transaction
            .query_row(
                "SELECT agent_id FROM agent_outbox WHERE deduplication_key=?1",
                [idempotency_key],
                |row| row.get::<_, Option<String>>(0),
            )
            .map_err(|error| format!("verify agent promotion idempotency: {error}"))?;
        if outbox_matches.as_deref() != Some(agent_id) {
            return Err("agent promotion idempotency conflict".to_owned());
        }
        transaction
            .commit()
            .map_err(|error| format!("commit reusable agent promotion: {error}"))?;
        Ok(promoted)
    }

    /// Return the exact mixed causal subtree in parent-first order. The
    /// runtime uses this durable plan to invoke each subtype's canonical
    /// cancellation path rather than directly rewriting worker terminal truth.
    pub(crate) fn execution_subtree(
        &self,
        execution_id: &str,
    ) -> Result<Vec<ExecutionNodeRecord>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(&format!(
                "WITH RECURSIVE subtree(execution_id,depth) AS (
                    SELECT execution_id,0 FROM execution_nodes WHERE execution_id=?1
                    UNION ALL
                    SELECT child.execution_id,subtree.depth+1
                    FROM execution_nodes child
                    JOIN subtree ON child.parent_execution_id=subtree.execution_id
                 )
                 SELECT node.execution_id,node.kind,node.parent_execution_id,node.owner_agent_id,
                        node.root_session_id,node.trace_id,node.causal_depth,node.child_slot,
                        node.worker_invocation_id,
                        COALESCE(node.assignment_id,direct.assignment_id),node.created_at
                 FROM execution_nodes node JOIN subtree USING(execution_id)
                 LEFT JOIN direct_worker_agent_runs direct
                   ON direct.worker_invocation_id=node.worker_invocation_id
                 ORDER BY subtree.depth,node.created_at,node.execution_id"
            ))
            .map_err(|error| format!("prepare mixed execution subtree: {error}"))?;
        let records = statement
            .query_map([execution_id], map_execution)
            .map_err(|error| format!("query mixed execution subtree: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode mixed execution subtree: {error}"))?;
        if records.is_empty() {
            return Err(format!("execution '{execution_id}' was not found"));
        }
        Ok(records)
    }
}
