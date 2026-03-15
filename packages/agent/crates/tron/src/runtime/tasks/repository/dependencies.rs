use std::collections::{HashSet, VecDeque};

use rusqlite::{Connection, params};

use crate::runtime::tasks::errors::TaskError;
use crate::runtime::tasks::types::{DependencyRelationship, TaskDependency};

pub(super) fn add_dependency(
    conn: &Connection,
    blocking_task_id: &str,
    waiting_task_id: &str,
    relationship: DependencyRelationship,
) -> Result<(), TaskError> {
    let _ = conn.execute(
        "INSERT OR IGNORE INTO task_dependencies \
         (blocker_task_id, blocked_task_id, relationship) \
         VALUES (?1, ?2, ?3)",
        params![blocking_task_id, waiting_task_id, relationship.as_sql()],
    )?;
    Ok(())
}

pub(super) fn remove_dependency(
    conn: &Connection,
    blocking_task_id: &str,
    waiting_task_id: &str,
) -> Result<bool, TaskError> {
    Ok(conn.execute(
        "DELETE FROM task_dependencies \
         WHERE blocker_task_id = ?1 AND blocked_task_id = ?2",
        params![blocking_task_id, waiting_task_id],
    )? > 0)
}

pub(super) fn get_blocked_by(
    conn: &Connection,
    task_id: &str,
) -> Result<Vec<TaskDependency>, TaskError> {
    let mut stmt = conn.prepare(
        "SELECT blocker_task_id, blocked_task_id, relationship, created_at \
         FROM task_dependencies WHERE blocked_task_id = ?1",
    )?;
    let dependencies = stmt
        .query_map(params![task_id], |row| {
            Ok(TaskDependency {
                blocker_task_id: row.get(0)?,
                blocked_task_id: row.get(1)?,
                relationship: DependencyRelationship::from_sql(&row.get::<_, String>(2)?),
                created_at: row.get(3)?,
            })
        })?
        .filter_map(Result::ok)
        .collect();
    Ok(dependencies)
}

pub(super) fn get_blocks(
    conn: &Connection,
    task_id: &str,
) -> Result<Vec<TaskDependency>, TaskError> {
    let mut stmt = conn.prepare(
        "SELECT blocker_task_id, blocked_task_id, relationship, created_at \
         FROM task_dependencies WHERE blocker_task_id = ?1",
    )?;
    let dependencies = stmt
        .query_map(params![task_id], |row| {
            Ok(TaskDependency {
                blocker_task_id: row.get(0)?,
                blocked_task_id: row.get(1)?,
                relationship: DependencyRelationship::from_sql(&row.get::<_, String>(2)?),
                created_at: row.get(3)?,
            })
        })?
        .filter_map(Result::ok)
        .collect();
    Ok(dependencies)
}

pub(super) fn has_circular_dependency(
    conn: &Connection,
    upstream_task_id: &str,
    downstream_task_id: &str,
) -> Result<bool, TaskError> {
    let mut visited = HashSet::new();
    let mut queue = VecDeque::new();
    queue.push_back(downstream_task_id.to_string());

    while let Some(current) = queue.pop_front() {
        if current == upstream_task_id {
            return Ok(true);
        }
        if !visited.insert(current.clone()) {
            continue;
        }

        let mut stmt = conn.prepare(
            "SELECT blocked_task_id FROM task_dependencies \
             WHERE blocker_task_id = ?1 AND relationship = 'blocks'",
        )?;
        let children: Vec<String> = stmt
            .query_map(params![current], |row| row.get(0))?
            .filter_map(Result::ok)
            .collect();
        queue.extend(children);
    }

    Ok(false)
}

pub(super) fn get_blocked_task_count(
    conn: &Connection,
    workspace_id: Option<&str>,
) -> Result<u32, TaskError> {
    let count = if let Some(workspace_id) = workspace_id {
        conn.query_row(
            "SELECT COUNT(DISTINCT td.blocked_task_id) \
             FROM task_dependencies td \
             JOIN tasks t ON t.id = td.blocked_task_id \
             WHERE td.relationship = 'blocks' \
             AND t.status NOT IN ('completed', 'cancelled') \
             AND t.workspace_id = ?1",
            params![workspace_id],
            |row| row.get(0),
        )?
    } else {
        conn.query_row(
            "SELECT COUNT(DISTINCT td.blocked_task_id) \
             FROM task_dependencies td \
             JOIN tasks t ON t.id = td.blocked_task_id \
             WHERE td.relationship = 'blocks' \
             AND t.status NOT IN ('completed', 'cancelled')",
            [],
            |row| row.get(0),
        )?
    };
    Ok(count)
}
