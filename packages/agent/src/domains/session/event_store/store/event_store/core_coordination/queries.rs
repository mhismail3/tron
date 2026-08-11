//! Bounded model discovery and canonical client audit projections.

use super::*;

const MAX_PAGE_SIZE: usize = 200;

impl EventStore {
    pub(crate) fn discover_core_agents(&self, query: &AgentDiscoveryQuery) -> Result<AgentPage> {
        validate_identifier("discovery caller agent id", &query.caller_agent_id)?;
        let connection = self.conn()?;
        let caller = require_open_agent(&connection, &query.caller_agent_id)?;
        let mut statement = connection.prepare(&format!(
            "SELECT {AGENT_COLUMNS} FROM agents
             WHERE (?1=1 OR lifecycle!='closed')
             ORDER BY updated_at DESC,agent_id"
        ))?;
        let agents = statement
            .query_map([query.include_closed], map_agent)?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let needle = query
            .query
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_lowercase);
        let mut summaries = Vec::with_capacity(agents.len());
        for agent in agents {
            let summary = summarize_agent_in_tx(&connection, &caller, &agent, false)?;
            if query.status.is_some_and(|status| summary.status != status) {
                continue;
            }
            if needle.as_ref().is_some_and(|needle| {
                !summary.name.to_lowercase().contains(needle)
                    && !summary
                        .current_task
                        .as_deref()
                        .unwrap_or_default()
                        .to_lowercase()
                        .contains(needle)
            }) {
                continue;
            }
            summaries.push(summary);
        }
        page_agents(summaries, query.cursor.as_deref(), query.limit)
    }

    pub(crate) fn inspect_core_agent(
        &self,
        caller_agent_id: Option<&str>,
        agent_id: &str,
    ) -> Result<AgentInspection> {
        validate_identifier("inspect agent id", agent_id)?;
        if let Some(caller_agent_id) = caller_agent_id {
            validate_identifier("inspect caller agent id", caller_agent_id)?;
        }
        let connection = self.conn()?;
        let agent = query_agent(&connection, agent_id)?.ok_or_else(|| {
            EventStoreError::InvalidOperation(format!("agent '{agent_id}' was not found"))
        })?;
        let caller = caller_agent_id
            .map(|caller_id| {
                query_agent(&connection, caller_id)?.ok_or_else(|| {
                    EventStoreError::InvalidOperation(format!("agent '{caller_id}' was not found"))
                })
            })
            .transpose()?;
        let summary = summarize_agent_in_tx(
            &connection,
            caller.as_ref().unwrap_or(&agent),
            &agent,
            caller.is_none(),
        )?;
        let current_assignment = query_current_assignment_in_tx(&connection, agent_id)?;
        let assignment_count = connection.query_row(
            "SELECT COUNT(*) FROM agent_assignments WHERE agent_id=?1",
            [agent_id],
            |row| row.get::<_, u64>(0),
        )?;
        let message_count = connection.query_row(
            "SELECT COUNT(*) FROM agent_message_metadata
             WHERE source_agent_id=?1 OR target_agent_id=?1",
            [agent_id],
            |row| row.get::<_, u64>(0),
        )?;
        let child_count = connection.query_row(
            "SELECT COUNT(*) FROM agents WHERE parent_agent_id=?1",
            [agent_id],
            |row| row.get::<_, u64>(0),
        )?;
        Ok(AgentInspection {
            agent,
            summary,
            current_assignment,
            assignment_count,
            message_count,
            child_count,
        })
    }

    pub(crate) fn core_agent_assignments(
        &self,
        agent_id: &str,
        cursor: Option<&str>,
        limit: usize,
    ) -> Result<AssignmentPage> {
        validate_identifier("assignment history agent id", agent_id)?;
        let connection = self.conn()?;
        let _ = query_agent(&connection, agent_id)?.ok_or_else(|| {
            EventStoreError::InvalidOperation(format!("agent '{agent_id}' was not found"))
        })?;
        let offset = parse_page_cursor(cursor, "assignment_page")?;
        let limit = limit.clamp(1, MAX_PAGE_SIZE);
        let total = connection.query_row(
            "SELECT COUNT(*) FROM agent_assignments WHERE agent_id=?1",
            [agent_id],
            |row| row.get::<_, u64>(0),
        )?;
        let mut statement = connection.prepare(&format!(
            "SELECT {ASSIGNMENT_COLUMNS} FROM agent_assignments
             WHERE agent_id=?1 ORDER BY created_at DESC,assignment_id DESC
             LIMIT ?2 OFFSET ?3"
        ))?;
        let items = statement
            .query_map(
                params![
                    agent_id,
                    i64::try_from(limit).unwrap_or(i64::MAX),
                    i64::try_from(offset).unwrap_or(i64::MAX)
                ],
                map_assignment,
            )?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let next_offset = offset.saturating_add(items.len());
        Ok(AssignmentPage {
            items,
            next_cursor: (u64::try_from(next_offset).unwrap_or(u64::MAX) < total)
                .then(|| format!("assignment_page:{next_offset}")),
            total,
        })
    }

    pub(crate) fn core_agent_messages(
        &self,
        agent_id: &str,
        cursor: Option<&str>,
        limit: usize,
    ) -> Result<AgentMessagePage> {
        validate_identifier("message history agent id", agent_id)?;
        let connection = self.conn()?;
        let _ = query_agent(&connection, agent_id)?.ok_or_else(|| {
            EventStoreError::InvalidOperation(format!("agent '{agent_id}' was not found"))
        })?;
        let offset = parse_page_cursor(cursor, "message_page")?;
        let limit = limit.clamp(1, MAX_PAGE_SIZE);
        let total = connection.query_row(
            "SELECT COUNT(*) FROM agent_message_metadata
             WHERE source_agent_id=?1 OR target_agent_id=?1",
            [agent_id],
            |row| row.get::<_, u64>(0),
        )?;
        let mut statement = connection.prepare(
            "SELECT message_id,source_agent_id,target_agent_id,kind,authority,
                    assignment_id,reply_to_message_id,content_json,disposition,created_at
             FROM agent_message_metadata
             WHERE source_agent_id=?1 OR target_agent_id=?1
             ORDER BY created_at DESC,message_id DESC LIMIT ?2 OFFSET ?3",
        )?;
        let items = statement
            .query_map(
                params![
                    agent_id,
                    i64::try_from(limit).unwrap_or(i64::MAX),
                    i64::try_from(offset).unwrap_or(i64::MAX)
                ],
                |row| {
                    let content_json = row.get::<_, String>(7)?;
                    let content = serde_json::from_str::<Value>(&content_json)
                        .ok()
                        .and_then(|value| {
                            value
                                .get("text")
                                .and_then(Value::as_str)
                                .map(ToOwned::to_owned)
                        })
                        .unwrap_or(content_json);
                    Ok(AgentMessageAuditRecord {
                        message_id: row.get(0)?,
                        source_agent_id: row.get(1)?,
                        target_agent_id: row.get(2)?,
                        kind: row.get(3)?,
                        authority: row.get(4)?,
                        assignment_id: row.get(5)?,
                        reply_to_message_id: row.get(6)?,
                        content,
                        disposition: row.get(8)?,
                        created_at: row.get(9)?,
                    })
                },
            )?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let next_offset = offset.saturating_add(items.len());
        Ok(AgentMessagePage {
            items,
            next_cursor: (u64::try_from(next_offset).unwrap_or(u64::MAX) < total)
                .then(|| format!("message_page:{next_offset}")),
            total,
        })
    }
}

fn page_agents(items: Vec<AgentSummary>, cursor: Option<&str>, limit: usize) -> Result<AgentPage> {
    let total = u64::try_from(items.len()).unwrap_or(u64::MAX);
    let offset = parse_page_cursor(cursor, "agent_page")?;
    let limit = limit.clamp(1, MAX_PAGE_SIZE);
    let page = items
        .into_iter()
        .skip(offset)
        .take(limit)
        .collect::<Vec<_>>();
    let next_offset = offset.saturating_add(page.len());
    Ok(AgentPage {
        items: page,
        next_cursor: (u64::try_from(next_offset).unwrap_or(u64::MAX) < total)
            .then(|| format!("agent_page:{next_offset}")),
        total,
    })
}

fn parse_page_cursor(cursor: Option<&str>, namespace: &str) -> Result<usize> {
    let Some(cursor) = cursor else {
        return Ok(0);
    };
    let offset = cursor
        .strip_prefix(namespace)
        .and_then(|suffix| suffix.strip_prefix(':'))
        .and_then(|suffix| suffix.parse::<usize>().ok())
        .ok_or_else(|| EventStoreError::InvalidOperation("invalid agent page cursor".to_owned()))?;
    Ok(offset)
}

fn summarize_agent_in_tx(
    connection: &rusqlite::Connection,
    caller: &AgentRecord,
    agent: &AgentRecord,
    operator: bool,
) -> Result<AgentSummary> {
    let current = query_current_assignment_in_tx(connection, &agent.agent_id)?;
    let status = runtime_status(agent, current.as_ref(), connection)?;
    let relationship = if operator || caller.agent_id == agent.agent_id {
        AgentRelationship::SelfAgent
    } else if let Some(depth) =
        lineage_distance_in_tx(connection, &caller.agent_id, &agent.agent_id)?
    {
        if agent.visibility == AgentVisibility::Visible {
            AgentRelationship::PromotedChild
        } else if depth == 1 {
            AgentRelationship::Child
        } else {
            AgentRelationship::Descendant
        }
    } else if let Some(depth) =
        lineage_distance_in_tx(connection, &agent.agent_id, &caller.agent_id)?
    {
        if depth == 1 {
            AgentRelationship::Parent
        } else {
            AgentRelationship::Ancestor
        }
    } else if agent.management_owner_agent_id.as_deref() == Some(caller.agent_id.as_str()) {
        AgentRelationship::Managed
    } else if agents_have_corresponded_in_tx(connection, &caller.agent_id, &agent.agent_id)? {
        AgentRelationship::Correspondent
    } else {
        AgentRelationship::Unrelated
    };
    let depth = lineage_distance_in_tx(connection, &caller.agent_id, &agent.agent_id)?.or(
        lineage_distance_in_tx(connection, &agent.agent_id, &caller.agent_id)?,
    );
    let can_manage = operator
        || (agent.lifecycle == AgentLifecycle::Open
            && agent.visibility == AgentVisibility::Nested
            && caller.agent_id != agent.agent_id
            && agent_manages_in_tx(connection, &caller.agent_id, &agent.agent_id)?);
    let last_message_at = connection
        .query_row(
            "SELECT MAX(created_at) FROM agent_message_metadata
             WHERE source_agent_id=?1 OR target_agent_id=?1",
            [&agent.agent_id],
            |row| row.get::<_, Option<String>>(0),
        )?
        .unwrap_or_default();
    let last_activity_at = [
        agent.updated_at.as_str(),
        current
            .as_ref()
            .map(|assignment| assignment.updated_at.as_str())
            .unwrap_or_default(),
        last_message_at.as_str(),
    ]
    .into_iter()
    .max()
    .unwrap_or(agent.updated_at.as_str())
    .to_owned();
    Ok(AgentSummary {
        agent_id: agent.agent_id.clone(),
        name: agent.name.clone(),
        relationship,
        depth,
        status,
        current_task: current.as_ref().map(|assignment| assignment.task.clone()),
        current_assignment_id: current.map(|assignment| assignment.assignment_id),
        last_activity_at,
        can_message: agent.lifecycle == AgentLifecycle::Open && caller.agent_id != agent.agent_id,
        can_manage,
    })
}

fn query_current_assignment_in_tx(
    connection: &rusqlite::Connection,
    agent_id: &str,
) -> Result<Option<AssignmentRecord>> {
    connection
        .query_row(
            &format!(
                "SELECT {ASSIGNMENT_COLUMNS} FROM agent_assignments
                 WHERE agent_id=?1 AND status IN ('running','waiting','queued','offered')
                 ORDER BY CASE status
                    WHEN 'running' THEN 0 WHEN 'waiting' THEN 1
                    WHEN 'queued' THEN 2 ELSE 3 END,
                    queue_ordinal,created_at,assignment_id LIMIT 1"
            ),
            [agent_id],
            map_assignment,
        )
        .optional()
        .map_err(EventStoreError::from)
}

fn runtime_status(
    agent: &AgentRecord,
    current: Option<&AssignmentRecord>,
    connection: &rusqlite::Connection,
) -> Result<AgentRuntimeStatus> {
    if agent.lifecycle == AgentLifecycle::Closed {
        return Ok(AgentRuntimeStatus::Closed);
    }
    if agent.lifecycle == AgentLifecycle::Closing {
        return Ok(AgentRuntimeStatus::Closing);
    }
    if let Some(current) = current {
        if coordination_trace_is_paused_in_tx(connection, &current.trace_id)? {
            return Ok(AgentRuntimeStatus::AutonomyPaused);
        }
        return Ok(match current.status {
            AssignmentStatus::Running => AgentRuntimeStatus::Active,
            AssignmentStatus::Waiting => AgentRuntimeStatus::Waiting,
            AssignmentStatus::Queued | AssignmentStatus::Offered => AgentRuntimeStatus::Queued,
            _ => AgentRuntimeStatus::Idle,
        });
    }
    let queued = connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM agent_assignments
         WHERE agent_id=?1 AND status IN ('offered','queued'))",
        [&agent.agent_id],
        |row| row.get::<_, bool>(0),
    )?;
    Ok(if queued {
        AgentRuntimeStatus::Queued
    } else {
        AgentRuntimeStatus::Idle
    })
}

fn lineage_distance_in_tx(
    connection: &rusqlite::Connection,
    ancestor_agent_id: &str,
    descendant_agent_id: &str,
) -> Result<Option<u8>> {
    connection
        .query_row(
            "WITH RECURSIVE lineage(agent_id,depth) AS (
                SELECT parent_agent_id,1 FROM agents WHERE agent_id=?2
                UNION ALL
                SELECT agent.parent_agent_id,lineage.depth+1
                FROM agents agent JOIN lineage ON agent.agent_id=lineage.agent_id
                WHERE lineage.agent_id IS NOT NULL AND lineage.depth<16
             )
             SELECT depth FROM lineage WHERE agent_id=?1 LIMIT 1",
            params![ancestor_agent_id, descendant_agent_id],
            |row| row.get::<_, u8>(0),
        )
        .optional()
        .map_err(EventStoreError::from)
}

fn agents_have_corresponded_in_tx(
    connection: &rusqlite::Connection,
    left_agent_id: &str,
    right_agent_id: &str,
) -> Result<bool> {
    connection
        .query_row(
            "SELECT EXISTS(
                SELECT 1 FROM agent_message_metadata
                WHERE (source_agent_id=?1 AND target_agent_id=?2)
                   OR (source_agent_id=?2 AND target_agent_id=?1)
             )",
            params![left_agent_id, right_agent_id],
            |row| row.get(0),
        )
        .map_err(EventStoreError::from)
}
