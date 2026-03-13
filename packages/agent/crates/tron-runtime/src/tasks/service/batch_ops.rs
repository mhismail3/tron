use rusqlite::Connection;
use serde_json::{Value, json};

use super::{
    ActivityAction, BatchResult, BatchTarget, LogActivityParams, TaskCreateParams, TaskError,
    TaskFilter, TaskRepository, TaskService, TaskUpdateParams,
};

enum ResolvedTarget<'a> {
    Ids(&'a [String]),
    Filter(TaskFilter),
}

impl TaskService {
    /// Batch delete tasks by IDs or filter. Transactional with activity logging.
    pub fn batch_delete_tasks(
        conn: &Connection,
        target: &BatchTarget,
        dry_run: bool,
        session_id: Option<&str>,
    ) -> Result<BatchResult, TaskError> {
        if target.ids.as_ref().is_some_and(std::vec::Vec::is_empty) {
            return Ok(BatchResult {
                affected: 0,
                dry_run,
            });
        }
        let resolved = Self::resolve_batch_target(target)?;

        if dry_run {
            let count = match &resolved {
                ResolvedTarget::Ids(ids) => TaskRepository::count_tasks_by_ids(conn, ids)?,
                ResolvedTarget::Filter(filter) => {
                    TaskRepository::count_tasks_by_filter(conn, filter)?
                }
            };
            return Ok(BatchResult {
                affected: count,
                dry_run: true,
            });
        }

        Self::with_immediate_txn(conn, |tx| {
            let tasks = match &resolved {
                ResolvedTarget::Ids(ids) => TaskRepository::get_tasks_by_ids(tx, ids)?,
                ResolvedTarget::Filter(filter) => TaskRepository::get_tasks_by_filter(tx, filter)?,
            };

            for task in &tasks {
                TaskRepository::log_activity(
                    tx,
                    &LogActivityParams {
                        task_id: task.id.clone(),
                        session_id: session_id.map(String::from),
                        event_id: None,
                        action: ActivityAction::Deleted,
                        old_value: Some(task.title.clone()),
                        new_value: None,
                        detail: None,
                        minutes_logged: None,
                    },
                )?;
            }

            let affected = match &resolved {
                ResolvedTarget::Ids(ids) => TaskRepository::delete_tasks_by_ids(tx, ids)?,
                ResolvedTarget::Filter(filter) => {
                    TaskRepository::delete_tasks_by_filter(tx, filter)?
                }
            };

            Ok(BatchResult {
                affected,
                dry_run: false,
            })
        })
    }

    /// Batch update tasks by IDs or filter. Transactional with activity logging.
    pub fn batch_update_tasks(
        conn: &Connection,
        target: &BatchTarget,
        updates: &TaskUpdateParams,
        dry_run: bool,
        session_id: Option<&str>,
    ) -> Result<BatchResult, TaskError> {
        if target.ids.as_ref().is_some_and(std::vec::Vec::is_empty) {
            return Ok(BatchResult {
                affected: 0,
                dry_run,
            });
        }
        let resolved = Self::resolve_batch_target(target)?;

        if dry_run {
            let count = match &resolved {
                ResolvedTarget::Ids(ids) => TaskRepository::count_tasks_by_ids(conn, ids)?,
                ResolvedTarget::Filter(filter) => {
                    TaskRepository::count_tasks_by_filter(conn, filter)?
                }
            };
            return Ok(BatchResult {
                affected: count,
                dry_run: true,
            });
        }

        Self::with_immediate_txn(conn, |tx| {
            let tasks_before = match &resolved {
                ResolvedTarget::Ids(ids) => TaskRepository::get_tasks_by_ids(tx, ids)?,
                ResolvedTarget::Filter(filter) => TaskRepository::get_tasks_by_filter(tx, filter)?,
            };

            let affected = match &resolved {
                ResolvedTarget::Ids(ids) => TaskRepository::update_tasks_by_ids(tx, ids, updates)?,
                ResolvedTarget::Filter(filter) => {
                    TaskRepository::update_tasks_by_filter(tx, filter, updates)?
                }
            };

            for task in &tasks_before {
                let action = if updates.status.is_some() {
                    ActivityAction::StatusChanged
                } else {
                    ActivityAction::Updated
                };
                TaskRepository::log_activity(
                    tx,
                    &LogActivityParams {
                        task_id: task.id.clone(),
                        session_id: session_id.map(String::from),
                        event_id: None,
                        action,
                        old_value: updates.status.map(|_| task.status.as_sql().to_string()),
                        new_value: updates.status.map(|status| status.as_sql().to_string()),
                        detail: None,
                        minutes_logged: None,
                    },
                )?;
            }

            Ok(BatchResult {
                affected,
                dry_run: false,
            })
        })
    }

    fn resolve_batch_target(target: &BatchTarget) -> Result<ResolvedTarget<'_>, TaskError> {
        if let Some(ids) = &target.ids {
            return Ok(ResolvedTarget::Ids(ids));
        }
        if let Some(filter) = &target.filter {
            let mut resolved = filter.clone();
            resolved.include_completed = true;
            resolved.include_deferred = true;
            resolved.include_backlog = true;
            return Ok(ResolvedTarget::Filter(resolved));
        }
        Err(TaskError::Validation("ids or filter required".into()))
    }

    /// Batch create tasks atomically. Returns JSON with affected count and created IDs.
    pub fn batch_create_tasks(
        conn: &Connection,
        items: &[TaskCreateParams],
        session_id: Option<&str>,
    ) -> Result<Value, TaskError> {
        if items.is_empty() {
            return Ok(json!({ "affected": 0, "dryRun": false, "ids": [] }));
        }

        for (index, item) in items.iter().enumerate() {
            if item.title.trim().is_empty() {
                return Err(TaskError::Validation(format!(
                    "item[{index}]: title is required"
                )));
            }
        }

        Self::with_immediate_txn(conn, |tx| {
            let mut created_ids = Vec::with_capacity(items.len());

            for item in items {
                let task = TaskRepository::create_task(tx, item)?;
                TaskRepository::log_activity(
                    tx,
                    &LogActivityParams {
                        task_id: task.id.clone(),
                        session_id: session_id.map(String::from),
                        event_id: None,
                        action: ActivityAction::Created,
                        old_value: None,
                        new_value: Some(task.title.clone()),
                        detail: None,
                        minutes_logged: None,
                    },
                )?;
                created_ids.push(task.id);
            }

            Ok(json!({
                "affected": created_ids.len(),
                "dryRun": false,
                "ids": created_ids,
            }))
        })
    }

    /// Batch delete projects by IDs.
    pub fn batch_delete_projects(
        conn: &Connection,
        ids: &[String],
        dry_run: bool,
    ) -> Result<BatchResult, TaskError> {
        if ids.is_empty() {
            return Ok(BatchResult {
                affected: 0,
                dry_run,
            });
        }
        if dry_run {
            return Ok(BatchResult {
                affected: count_rows_by_ids(conn, "projects", ids)?,
                dry_run: true,
            });
        }
        let affected = TaskRepository::delete_projects_by_ids(conn, ids)?;
        Ok(BatchResult {
            affected,
            dry_run: false,
        })
    }

    /// Batch delete areas by IDs.
    pub fn batch_delete_areas(
        conn: &Connection,
        ids: &[String],
        dry_run: bool,
    ) -> Result<BatchResult, TaskError> {
        if ids.is_empty() {
            return Ok(BatchResult {
                affected: 0,
                dry_run,
            });
        }
        if dry_run {
            return Ok(BatchResult {
                affected: count_rows_by_ids(conn, "areas", ids)?,
                dry_run: true,
            });
        }
        let affected = TaskRepository::delete_areas_by_ids(conn, ids)?;
        Ok(BatchResult {
            affected,
            dry_run: false,
        })
    }
}

fn count_rows_by_ids(conn: &Connection, table: &str, ids: &[String]) -> Result<u32, TaskError> {
    let placeholders = ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
    let sql = format!("SELECT COUNT(*) FROM {table} WHERE id IN ({placeholders})");
    let params: Vec<&dyn rusqlite::types::ToSql> = ids
        .iter()
        .map(|id| id as &dyn rusqlite::types::ToSql)
        .collect();
    conn.query_row(&sql, params.as_slice(), |row| row.get(0))
        .map_err(Into::into)
}
