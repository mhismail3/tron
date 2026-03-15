use rusqlite::types::ToSql;

use crate::runtime::tasks::types::{Task, TaskFilter, TaskStatus, TaskUpdateParams};

pub(super) type SqlValue = Box<dyn ToSql>;

pub(super) fn generate_id(prefix: &str) -> String {
    format!("{prefix}-{}", uuid::Uuid::now_v7())
}

pub(super) fn now_iso() -> String {
    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
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

    let normalize = |value: &str| (!value.is_empty()).then(|| value.to_owned());

    if let Some(ref parent_task_id) = updates.parent_task_id {
        sets.push("parent_task_id = ?".to_string());
        values.push(Box::new(normalize(parent_task_id)) as SqlValue);
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
    if let Some(ref parent_task_id) = filter.parent_task_id {
        conditions.push("parent_task_id = ?".to_string());
        values.push(Box::new(parent_task_id.clone()) as SqlValue);
    }

    if !filter.include_completed {
        conditions.push("status NOT IN ('completed', 'cancelled')".to_string());
    }

    let where_clause = if conditions.is_empty() {
        String::new()
    } else {
        format!("WHERE {}", conditions.join(" AND "))
    };

    (where_clause, values)
}


pub(super) fn task_from_row(row: &rusqlite::Row<'_>) -> Task {
    let status_str: String = row.get_unwrap("status");
    let metadata_json: Option<String> = row.get_unwrap("metadata");

    Task {
        id: row.get_unwrap("id"),
        parent_task_id: row.get_unwrap("parent_task_id"),
        title: row.get_unwrap("title"),
        description: row.get_unwrap("description"),
        active_form: row.get_unwrap("active_form"),
        notes: row.get_unwrap("notes"),
        status: TaskStatus::from_sql(&status_str),
        started_at: row.get_unwrap("started_at"),
        completed_at: row.get_unwrap("completed_at"),
        created_at: row.get_unwrap("created_at"),
        updated_at: row.get_unwrap("updated_at"),
        created_by_session_id: row.get_unwrap("created_by_session_id"),
        last_session_id: row.get_unwrap("last_session_id"),
        last_session_at: row.get_unwrap("last_session_at"),
        metadata: parse_metadata(metadata_json),
    }
}
