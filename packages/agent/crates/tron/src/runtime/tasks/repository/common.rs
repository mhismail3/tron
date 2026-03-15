use rusqlite::types::ToSql;

use crate::runtime::tasks::errors::TaskError;
use crate::runtime::tasks::types::{
    Area, AreaStatus, Project, ProjectStatus, Task, TaskFilter, TaskPriority, TaskSource,
    TaskStatus, TaskUpdateParams,
};

pub(super) type SqlValue = Box<dyn ToSql>;

pub(super) fn generate_id(prefix: &str) -> String {
    format!("{prefix}-{}", uuid::Uuid::now_v7())
}

pub(super) fn now_iso() -> String {
    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

pub(super) fn parse_tags(json: &str) -> Vec<String> {
    serde_json::from_str(json).unwrap_or_else(|error| {
        tracing::warn!(error = %error, "corrupt tags JSON in task DB");
        Vec::new()
    })
}

pub(super) fn tags_to_json(tags: &[String]) -> String {
    serde_json::to_string(tags).unwrap_or_else(|_| "[]".to_string())
}

pub(super) fn parse_metadata(json: Option<String>) -> Option<serde_json::Value> {
    json.and_then(|value| {
        serde_json::from_str(&value).unwrap_or_else(|error| {
            tracing::warn!(error = %error, "corrupt metadata JSON in task DB");
            None
        })
    })
}

pub(super) fn build_update_sets(updates: &TaskUpdateParams) -> (Vec<String>, Vec<SqlValue>) {
    let mut sets = Vec::new();
    let mut values = Vec::new();

    if let Some(ref title) = updates.title {
        sets.push("title = ?".to_string());
        values.push(Box::new(title.clone()) as SqlValue);
    }
    if let Some(ref desc) = updates.description {
        sets.push("description = ?".to_string());
        values.push(Box::new(desc.clone()) as SqlValue);
    }
    if let Some(ref active_form) = updates.active_form {
        sets.push("active_form = ?".to_string());
        values.push(Box::new(active_form.clone()) as SqlValue);
    }
    if let Some(status) = updates.status {
        sets.push("status = ?".to_string());
        values.push(Box::new(status.as_sql().to_string()) as SqlValue);
    }
    if let Some(priority) = updates.priority {
        sets.push("priority = ?".to_string());
        values.push(Box::new(priority.as_sql().to_string()) as SqlValue);
    }

    let normalize = |value: &str| (!value.is_empty()).then(|| value.to_owned());

    if let Some(ref project_id) = updates.project_id {
        sets.push("project_id = ?".to_string());
        values.push(Box::new(normalize(project_id)) as SqlValue);
    }
    if let Some(ref parent_task_id) = updates.parent_task_id {
        sets.push("parent_task_id = ?".to_string());
        values.push(Box::new(normalize(parent_task_id)) as SqlValue);
    }
    if let Some(ref area_id) = updates.area_id {
        sets.push("area_id = ?".to_string());
        values.push(Box::new(normalize(area_id)) as SqlValue);
    }
    if let Some(ref due_date) = updates.due_date {
        sets.push("due_date = ?".to_string());
        values.push(Box::new(due_date.clone()) as SqlValue);
    }
    if let Some(ref deferred_until) = updates.deferred_until {
        sets.push("deferred_until = ?".to_string());
        values.push(Box::new(deferred_until.clone()) as SqlValue);
    }
    if let Some(estimated_minutes) = updates.estimated_minutes {
        sets.push("estimated_minutes = ?".to_string());
        values.push(Box::new(estimated_minutes) as SqlValue);
    }
    if let Some(ref last_session_id) = updates.last_session_id {
        sets.push("last_session_id = ?".to_string());
        values.push(Box::new(last_session_id.clone()) as SqlValue);
        sets.push("last_session_at = ?".to_string());
        values.push(Box::new(now_iso()) as SqlValue);
    }
    if let Some(ref metadata) = updates.metadata {
        sets.push("metadata = ?".to_string());
        values.push(
            Box::new(serde_json::to_string(metadata).unwrap_or_else(|_| "{}".to_string()))
                as SqlValue,
        );
    }

    (sets, values)
}

pub(super) fn build_task_where_clause(filter: &TaskFilter) -> (String, Vec<SqlValue>) {
    let mut conditions = Vec::new();
    let mut values = Vec::new();

    if let Some(status) = filter.status {
        conditions.push("status = ?".to_string());
        values.push(Box::new(status.as_sql().to_string()) as SqlValue);
    }
    if let Some(priority) = filter.priority {
        conditions.push("priority = ?".to_string());
        values.push(Box::new(priority.as_sql().to_string()) as SqlValue);
    }
    if let Some(ref project_id) = filter.project_id {
        conditions.push("project_id = ?".to_string());
        values.push(Box::new(project_id.clone()) as SqlValue);
    }
    if let Some(ref workspace_id) = filter.workspace_id {
        conditions.push("workspace_id = ?".to_string());
        values.push(Box::new(workspace_id.clone()) as SqlValue);
    }
    if let Some(ref area_id) = filter.area_id {
        conditions.push("area_id = ?".to_string());
        values.push(Box::new(area_id.clone()) as SqlValue);
    }
    if let Some(ref parent_task_id) = filter.parent_task_id {
        conditions.push("parent_task_id = ?".to_string());
        values.push(Box::new(parent_task_id.clone()) as SqlValue);
    }
    if let Some(ref due_before) = filter.due_before {
        conditions.push("due_date IS NOT NULL AND due_date <= ?".to_string());
        values.push(Box::new(due_before.clone()) as SqlValue);
    }

    if !filter.include_completed {
        conditions.push("status NOT IN ('completed', 'cancelled')".to_string());
    }
    if !filter.include_deferred {
        conditions
            .push("(deferred_until IS NULL OR deferred_until <= datetime('now'))".to_string());
    }
    if !filter.include_backlog {
        conditions.push("status != 'backlog'".to_string());
    }

    if let Some(ref tags) = filter.tags {
        for tag in tags {
            conditions.push(
                "EXISTS (SELECT 1 FROM json_each(tags) WHERE json_each.value = ?)".to_string(),
            );
            values.push(Box::new(tag.clone()) as SqlValue);
        }
    }

    let where_clause = if conditions.is_empty() {
        String::new()
    } else {
        format!("WHERE {}", conditions.join(" AND "))
    };

    (where_clause, values)
}

pub(super) fn build_simple_set_clause(
    updates: &TaskUpdateParams,
) -> Result<(Vec<String>, Vec<SqlValue>), TaskError> {
    let mut sets = Vec::new();
    let mut values = Vec::new();

    if let Some(ref title) = updates.title {
        sets.push("title = ?".to_string());
        values.push(Box::new(title.clone()) as SqlValue);
    }
    if let Some(ref desc) = updates.description {
        sets.push("description = ?".to_string());
        values.push(Box::new(desc.clone()) as SqlValue);
    }
    if let Some(status) = updates.status {
        sets.push("status = ?".to_string());
        values.push(Box::new(status.as_sql().to_string()) as SqlValue);

        if status == TaskStatus::InProgress {
            sets.push("started_at = COALESCE(started_at, ?)".to_string());
            values.push(Box::new(now_iso()) as SqlValue);
        }
        if status.is_terminal() {
            sets.push("completed_at = COALESCE(completed_at, ?)".to_string());
            values.push(Box::new(now_iso()) as SqlValue);
        }
        if !status.is_terminal() {
            sets.push("completed_at = NULL".to_string());
        }
    }
    if let Some(priority) = updates.priority {
        sets.push("priority = ?".to_string());
        values.push(Box::new(priority.as_sql().to_string()) as SqlValue);
    }
    if let Some(ref project_id) = updates.project_id {
        sets.push("project_id = ?".to_string());
        let normalized: Option<String> = (!project_id.is_empty()).then(|| project_id.clone());
        values.push(Box::new(normalized) as SqlValue);
    }
    if let Some(ref area_id) = updates.area_id {
        sets.push("area_id = ?".to_string());
        let normalized: Option<String> = (!area_id.is_empty()).then(|| area_id.clone());
        values.push(Box::new(normalized) as SqlValue);
    }

    if sets.is_empty() {
        return Err(TaskError::Validation("no fields to update".to_string()));
    }

    sets.push("updated_at = ?".to_string());
    values.push(Box::new(now_iso()) as SqlValue);

    Ok((sets, values))
}

pub(super) fn task_from_row(row: &rusqlite::Row<'_>) -> Task {
    let status_str: String = row.get_unwrap("status");
    let priority_str: String = row.get_unwrap("priority");
    let source_str: String = row.get_unwrap("source");
    let tags_json: String = row.get_unwrap("tags");
    let metadata_json: Option<String> = row.get_unwrap("metadata");

    Task {
        id: row.get_unwrap("id"),
        project_id: row.get_unwrap("project_id"),
        parent_task_id: row.get_unwrap("parent_task_id"),
        workspace_id: row.get_unwrap("workspace_id"),
        area_id: row.get_unwrap("area_id"),
        title: row.get_unwrap("title"),
        description: row.get_unwrap("description"),
        active_form: row.get_unwrap("active_form"),
        notes: row.get_unwrap("notes"),
        status: match status_str.as_str() {
            "backlog" => TaskStatus::Backlog,
            "in_progress" => TaskStatus::InProgress,
            "completed" => TaskStatus::Completed,
            "cancelled" => TaskStatus::Cancelled,
            _ => TaskStatus::Pending,
        },
        priority: match priority_str.as_str() {
            "low" => TaskPriority::Low,
            "high" => TaskPriority::High,
            "critical" => TaskPriority::Critical,
            _ => TaskPriority::Medium,
        },
        source: match source_str.as_str() {
            "user" => TaskSource::User,
            "skill" => TaskSource::Skill,
            "system" => TaskSource::System,
            _ => TaskSource::Agent,
        },
        tags: parse_tags(&tags_json),
        due_date: row.get_unwrap("due_date"),
        deferred_until: row.get_unwrap("deferred_until"),
        started_at: row.get_unwrap("started_at"),
        completed_at: row.get_unwrap("completed_at"),
        created_at: row.get_unwrap("created_at"),
        updated_at: row.get_unwrap("updated_at"),
        estimated_minutes: row.get_unwrap("estimated_minutes"),
        actual_minutes: row.get_unwrap("actual_minutes"),
        created_by_session_id: row.get_unwrap("created_by_session_id"),
        last_session_id: row.get_unwrap("last_session_id"),
        last_session_at: row.get_unwrap("last_session_at"),
        sort_order: row.get_unwrap("sort_order"),
        metadata: parse_metadata(metadata_json),
    }
}

pub(super) fn project_from_row(row: &rusqlite::Row<'_>) -> Project {
    let status_str: String = row.get_unwrap("status");
    let tags_json: String = row.get_unwrap("tags");
    let metadata_json: Option<String> = row.get_unwrap("metadata");

    Project {
        id: row.get_unwrap("id"),
        workspace_id: row.get_unwrap("workspace_id"),
        area_id: row.get_unwrap("area_id"),
        title: row.get_unwrap("title"),
        description: row.get_unwrap("description"),
        status: match status_str.as_str() {
            "paused" => ProjectStatus::Paused,
            "completed" => ProjectStatus::Completed,
            "archived" => ProjectStatus::Archived,
            _ => ProjectStatus::Active,
        },
        tags: parse_tags(&tags_json),
        created_at: row.get_unwrap("created_at"),
        updated_at: row.get_unwrap("updated_at"),
        completed_at: row.get_unwrap("completed_at"),
        metadata: parse_metadata(metadata_json),
    }
}

pub(super) fn area_from_row(row: &rusqlite::Row<'_>) -> Area {
    let status_str: String = row.get_unwrap("status");
    let tags_json: String = row.get_unwrap("tags");
    let metadata_json: Option<String> = row.get_unwrap("metadata");

    Area {
        id: row.get_unwrap("id"),
        workspace_id: row.get_unwrap("workspace_id"),
        title: row.get_unwrap("title"),
        description: row.get_unwrap("description"),
        status: match status_str.as_str() {
            "archived" => AreaStatus::Archived,
            _ => AreaStatus::Active,
        },
        tags: parse_tags(&tags_json),
        sort_order: row.get_unwrap("sort_order"),
        created_at: row.get_unwrap("created_at"),
        updated_at: row.get_unwrap("updated_at"),
        metadata: parse_metadata(metadata_json),
    }
}
