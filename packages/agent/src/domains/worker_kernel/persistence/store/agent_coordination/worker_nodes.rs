//! Mixed execution-node admission for worker invocations.
//!
//! Worker execution ancestry is recorded in the same canonical graph as agent assignments.

use super::*;

pub(crate) fn execution_id_for_worker_invocation(invocation_id: &str) -> String {
    format!("execution_{invocation_id}")
}

pub(crate) fn insert_worker_execution_node(
    transaction: &Transaction<'_>,
    invocation_id: &str,
    parent_worker_invocation_id: Option<&str>,
    parent_agent_execution_id: Option<&str>,
    owner_agent_id: Option<&str>,
    root_session_id: Option<&str>,
    trace_id: &str,
    causal_depth: u32,
    child_slot: Option<u32>,
    created_at: &str,
    max_child_executions: u32,
    max_execution_nodes: u32,
) -> Result<String, String> {
    let execution_id = execution_id_for_worker_invocation(invocation_id);
    if parent_worker_invocation_id.is_some() && parent_agent_execution_id.is_some() {
        return Err(
            "worker execution cannot have both worker and agent immediate parents".to_owned(),
        );
    }
    let parent_execution_id = parent_worker_invocation_id
        .map(execution_id_for_worker_invocation)
        .or_else(|| parent_agent_execution_id.map(ToOwned::to_owned));
    let parent = parent_execution_id
        .as_deref()
        .map(|parent_id| query_execution(transaction, parent_id))
        .transpose()?
        .flatten();
    if parent_execution_id.is_some() && parent.is_none() {
        return Err(format!(
            "parent execution '{}' was not found",
            parent_execution_id.as_deref().unwrap_or_default()
        ));
    }
    if let Some(parent) = parent.as_ref()
        && (parent.trace_id != trace_id || causal_depth != parent.causal_depth.saturating_add(1))
    {
        return Err("worker execution parent does not match its causal trace".to_owned());
    }
    let effective_owner = match owner_agent_id.or_else(|| {
        parent
            .as_ref()
            .and_then(|record| record.owner_agent_id.as_deref())
    }) {
        Some(agent_id) => Some(agent_id.to_owned()),
        None => root_session_id
            .map(|session_id| {
                transaction
                    .query_row(
                        "SELECT agent_id FROM agent_instances WHERE session_id=?1",
                        [session_id],
                        |row| row.get::<_, String>(0),
                    )
                    .optional()
                    .map_err(|error| format!("resolve worker execution owner: {error}"))
            })
            .transpose()?
            .flatten(),
    };
    let effective_root_session_id = parent
        .as_ref()
        .and_then(|record| record.root_session_id.as_deref())
        .or(root_session_id);
    enforce_execution_node_ceiling(transaction, trace_id, max_execution_nodes)?;
    enforce_direct_child_execution_ceiling(
        transaction,
        trace_id,
        parent_execution_id.as_deref(),
        max_child_executions,
    )?;
    transaction
        .execute(
            "INSERT OR IGNORE INTO execution_nodes(
                execution_id,kind,parent_execution_id,owner_agent_id,root_session_id,
                trace_id,causal_depth,child_slot,worker_invocation_id,assignment_id,created_at
             ) VALUES (?1,'worker',?2,?3,?4,?5,?6,?7,?8,NULL,?9)",
            params![
                execution_id,
                parent_execution_id,
                effective_owner,
                effective_root_session_id,
                trace_id,
                causal_depth,
                child_slot,
                invocation_id,
                created_at,
            ],
        )
        .map_err(|error| format!("insert worker execution node: {error}"))?;
    Ok(execution_id)
}
