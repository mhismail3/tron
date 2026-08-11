//! Shared active-assignment, wake absorption, and dependency-topology helpers.

use super::*;

pub(super) fn set_active_assignment_state_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    assignment: &AssignmentRecord,
    target: AssignmentStatus,
    now: &str,
) -> Result<()> {
    if !matches!(
        target,
        AssignmentStatus::Running | AssignmentStatus::Waiting
    ) {
        return Err(EventStoreError::Internal(
            "active assignment state helper received a terminal state".to_owned(),
        ));
    }
    let current = query_assignment(transaction, &assignment.assignment_id)?
        .ok_or_else(|| EventStoreError::Internal("active assignment disappeared".to_owned()))?;
    if current.status == target {
        return Ok(());
    }
    if !matches!(
        current.status,
        AssignmentStatus::Running | AssignmentStatus::Waiting
    ) {
        return Err(EventStoreError::InvalidOperation(format!(
            "cannot move assignment from {} to {}",
            current.status.as_str(),
            target.as_str()
        )));
    }
    transaction.execute(
        "UPDATE agent_assignments SET status=?2,updated_at=?3
         WHERE assignment_id=?1 AND status=?4",
        params![
            current.assignment_id,
            target.as_str(),
            now,
            current.status.as_str()
        ],
    )?;
    transaction.execute(
        "UPDATE agent_assignment_attempts SET status=?2
         WHERE assignment_id=?1 AND completed_at IS NULL",
        params![current.assignment_id, target.as_str()],
    )?;
    Ok(())
}

pub(super) fn absorb_core_wait_wakes_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    wait_id: &str,
    owner_agent_id: &str,
    now: &str,
) -> Result<usize> {
    transaction
        .execute(
            "UPDATE agent_wake_intents
             SET disposition='cancelled',lease_id=NULL,cancelled_at=?3,
                 last_error='absorbed by explicit coordination wait'
             WHERE target_agent_id=?2 AND disposition IN ('pending','leased')
               AND (
                 (cause_kind='assignment_result' AND EXISTS(
                    SELECT 1 FROM coordination_wait_members member
                    WHERE member.wait_id=?1
                      AND member.target_kind='agent_assignment'
                      AND member.target_id=agent_wake_intents.cause_id
                      AND member.disposition='satisfied'
                 ))
                 OR
                 (cause_kind='wait_result' AND cause_id=?1 AND EXISTS(
                    SELECT 1 FROM coordination_wait_inline_results inline_result
                    WHERE inline_result.wait_id=?1
                 ))
               )",
            params![wait_id, owner_agent_id, now],
        )
        .map_err(EventStoreError::from)
}

pub(super) fn query_core_wait_satisfied_targets_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    wait_id: &str,
) -> Result<Vec<WaitTarget>> {
    let mut statement = transaction.prepare(
        "SELECT target_kind,target_id FROM coordination_wait_members
         WHERE wait_id=?1 AND disposition='satisfied' ORDER BY ordinal",
    )?;
    statement
        .query_map([wait_id], |row| {
            let kind = row.get::<_, String>(0)?;
            let id = row.get::<_, String>(1)?;
            match kind.as_str() {
                "agent_assignment" => Ok(WaitTarget::Assignment(id)),
                "reply" => Ok(WaitTarget::Reply(id)),
                _ => Err(rusqlite::Error::FromSqlConversionFailure(
                    0,
                    rusqlite::types::Type::Text,
                    Box::new(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "core agent wait contains a non-core target",
                    )),
                )),
            }
        })?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(EventStoreError::from)
}
pub(super) fn agent_is_ancestor_in_tx(
    connection: &rusqlite::Connection,
    possible_ancestor_id: &str,
    agent_id: &str,
) -> Result<bool> {
    connection
        .query_row(
            "WITH RECURSIVE lineage(agent_id) AS (
                SELECT parent_agent_id FROM agents WHERE agent_id=?2
                UNION ALL
                SELECT parent.parent_agent_id FROM agents parent
                JOIN lineage child ON parent.agent_id=child.agent_id
                WHERE child.agent_id IS NOT NULL
             )
             SELECT EXISTS(SELECT 1 FROM lineage WHERE agent_id=?1)",
            params![possible_ancestor_id, agent_id],
            |row| row.get(0),
        )
        .map_err(EventStoreError::from)
}

/// Current management follows mutable ownership edges, not immutable spawn
/// lineage. Promotion cuts this chain while preserving audit parentage.
pub(super) fn agent_manages_in_tx(
    connection: &rusqlite::Connection,
    manager_agent_id: &str,
    target_agent_id: &str,
) -> Result<bool> {
    connection
        .query_row(
            "WITH RECURSIVE managed(agent_id) AS (
                SELECT agent_id FROM agents WHERE agent_id=?1
                UNION ALL
                SELECT agent.agent_id FROM agents agent
                JOIN managed ON agent.management_owner_agent_id=managed.agent_id
                WHERE agent.lifecycle!='closed'
             )
             SELECT EXISTS(SELECT 1 FROM managed WHERE agent_id=?2)",
            params![manager_agent_id, target_agent_id],
            |row| row.get(0),
        )
        .map_err(EventStoreError::from)
}

pub(super) fn collect_assignment_topology(
    connection: &rusqlite::Connection,
    assignment_id: &str,
    edges: &mut BTreeSet<CoordinationDependencyEdge>,
) -> Result<()> {
    let mut current_id = assignment_id.to_owned();
    let mut visited = HashSet::new();
    loop {
        if !visited.insert(current_id.clone()) {
            return Err(EventStoreError::Internal(
                "assignment lineage contains a cycle".to_owned(),
            ));
        }
        let assignment = query_assignment(connection, &current_id)?.ok_or_else(|| {
            EventStoreError::InvalidOperation(format!(
                "assignment '{current_id}' was not found while resolving wait topology"
            ))
        })?;
        let _ = edges.insert(CoordinationDependencyEdge {
            source_dependency_id: assignment_dependency(&assignment.assignment_id),
            target_dependency_id: agent_dependency(&assignment.agent_id),
            kind: CoordinationDependencyEdgeKind::Executor,
        });
        let Some(parent_id) = assignment.parent_assignment_id else {
            break;
        };
        let _ = edges.insert(CoordinationDependencyEdge {
            source_dependency_id: assignment_dependency(&parent_id),
            target_dependency_id: assignment_dependency(&assignment.assignment_id),
            kind: CoordinationDependencyEdgeKind::Causal,
        });
        current_id = parent_id;
        if visited.len() > 17 {
            return Err(EventStoreError::Internal(
                "assignment lineage exceeds the hard causal depth".to_owned(),
            ));
        }
    }
    Ok(())
}

pub(super) fn agent_dependency(agent_id: &str) -> String {
    format!("core_agent:{agent_id}")
}

pub(super) fn assignment_dependency(assignment_id: &str) -> String {
    format!("core_assignment:{assignment_id}")
}
