//! SQL data access layer for tasks.
//!
//! All methods take a `&Connection` parameter and are stateless — pure functions
//! that translate between Rust types and SQL.

mod activity;
mod common;
mod summary;
mod tasks;

use rusqlite::Connection;

use super::errors::TaskError;
use super::types::{
    ActiveTaskSummary, LogActivityParams, Task, TaskActivity, TaskCreateParams, TaskFilter,
    TaskListResult, TaskUpdateParams,
};

/// Task repository for SQL CRUD operations.
pub struct TaskRepository;

impl TaskRepository {
    pub fn create_task(conn: &Connection, params: &TaskCreateParams) -> Result<Task, TaskError> {
        tasks::create_task(conn, params)
    }

    pub fn get_task(conn: &Connection, id: &str) -> Result<Option<Task>, TaskError> {
        tasks::get_task(conn, id)
    }

    pub fn update_task(
        conn: &Connection,
        id: &str,
        updates: &TaskUpdateParams,
    ) -> Result<Option<Task>, TaskError> {
        tasks::update_task(conn, id, updates)
    }

    pub fn delete_task(conn: &Connection, id: &str) -> Result<bool, TaskError> {
        tasks::delete_task(conn, id)
    }

    pub fn list_tasks(
        conn: &Connection,
        filter: &TaskFilter,
        limit: u32,
        offset: u32,
    ) -> Result<TaskListResult, TaskError> {
        tasks::list_tasks(conn, filter, limit, offset)
    }

    pub fn get_subtasks(
        conn: &Connection,
        parent_task_id: &str,
    ) -> Result<Vec<Task>, TaskError> {
        tasks::get_subtasks(conn, parent_task_id)
    }

    pub fn search_tasks(
        conn: &Connection,
        query: &str,
        limit: u32,
    ) -> Result<Vec<Task>, TaskError> {
        tasks::search_tasks(conn, query, limit)
    }

    pub fn mark_stale_tasks(
        conn: &Connection,
        session_id: &str,
    ) -> Result<usize, TaskError> {
        tasks::mark_stale_tasks(conn, session_id)
    }

    pub fn log_activity(
        conn: &Connection,
        params: &LogActivityParams,
    ) -> Result<(), TaskError> {
        activity::log_activity(conn, params)
    }

    pub fn get_activity(
        conn: &Connection,
        task_id: &str,
        limit: u32,
    ) -> Result<Vec<TaskActivity>, TaskError> {
        activity::get_activity(conn, task_id, limit)
    }

    pub fn get_active_task_summary(
        conn: &Connection,
    ) -> Result<ActiveTaskSummary, TaskError> {
        summary::get_active_task_summary(conn)
    }
}
