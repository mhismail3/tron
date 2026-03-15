use rusqlite::Connection;

use super::{
    Project, ProjectCreateParams, ProjectFilter, ProjectListResult, ProjectStatus,
    ProjectUpdateParams, ProjectWithTasks, TaskError, TaskFilter, TaskRepository, TaskService,
};

impl TaskService {
    /// Create a project.
    pub fn create_project(
        conn: &Connection,
        params: &ProjectCreateParams,
    ) -> Result<Project, TaskError> {
        if params.title.trim().is_empty() {
            return Err(TaskError::Validation(
                "Project title is required".to_string(),
            ));
        }
        TaskRepository::create_project(conn, params)
    }

    /// Update a project with auto-timestamps.
    pub fn update_project(
        conn: &Connection,
        id: &str,
        updates: &ProjectUpdateParams,
    ) -> Result<Project, TaskError> {
        let current = TaskRepository::get_project(conn, id)?
            .ok_or_else(|| TaskError::project_not_found(id))?;

        let _result = TaskRepository::update_project(conn, id, updates)?
            .ok_or_else(|| TaskError::project_not_found(id))?;

        if let Some(new_status) = updates.status {
            if new_status == ProjectStatus::Completed && current.status != ProjectStatus::Completed
            {
                let now = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                let _ = conn.execute(
                    "UPDATE projects SET completed_at = ?1 WHERE id = ?2",
                    rusqlite::params![now, id],
                )?;
            }
            if new_status != ProjectStatus::Completed && current.status == ProjectStatus::Completed
            {
                let _ = conn.execute(
                    "UPDATE projects SET completed_at = NULL WHERE id = ?1",
                    rusqlite::params![id],
                )?;
            }
        }

        TaskRepository::get_project(conn, id)?.ok_or_else(|| TaskError::project_not_found(id))
    }

    /// Get a project by ID.
    pub fn get_project(conn: &Connection, id: &str) -> Result<Project, TaskError> {
        TaskRepository::get_project(conn, id)?.ok_or_else(|| TaskError::project_not_found(id))
    }

    /// Get a project with its tasks.
    pub fn get_project_details(
        conn: &Connection,
        id: &str,
        limit: u32,
        offset: u32,
    ) -> Result<ProjectWithTasks, TaskError> {
        let project = Self::get_project(conn, id)?;
        let tasks = Self::list_tasks(
            conn,
            &TaskFilter {
                project_id: Some(id.to_string()),
                ..Default::default()
            },
            limit,
            offset,
        )?
        .tasks;

        Ok(ProjectWithTasks { project, tasks })
    }

    /// Delete a project.
    pub fn delete_project(conn: &Connection, id: &str) -> Result<bool, TaskError> {
        TaskRepository::delete_project(conn, id)
    }

    /// List projects with progress counts.
    pub fn list_projects(
        conn: &Connection,
        filter: &ProjectFilter,
        limit: u32,
        offset: u32,
    ) -> Result<ProjectListResult, TaskError> {
        TaskRepository::list_projects(conn, filter, limit, offset)
    }
}
