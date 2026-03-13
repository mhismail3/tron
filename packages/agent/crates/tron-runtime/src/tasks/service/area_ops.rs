use rusqlite::Connection;

use super::{
    Area, AreaCreateParams, AreaFilter, AreaListResult, AreaUpdateParams, TaskError,
    TaskRepository, TaskService,
};

impl TaskService {
    /// Create an area.
    pub fn create_area(conn: &Connection, params: &AreaCreateParams) -> Result<Area, TaskError> {
        if params.title.trim().is_empty() {
            return Err(TaskError::Validation("Area title is required".to_string()));
        }
        TaskRepository::create_area(conn, params)
    }

    /// Get an area by ID.
    pub fn get_area(conn: &Connection, id: &str) -> Result<Area, TaskError> {
        TaskRepository::get_area(conn, id)?.ok_or_else(|| TaskError::area_not_found(id))
    }

    /// Update an area.
    pub fn update_area(
        conn: &Connection,
        id: &str,
        updates: &AreaUpdateParams,
    ) -> Result<Area, TaskError> {
        TaskRepository::update_area(conn, id, updates)?.ok_or_else(|| TaskError::area_not_found(id))
    }

    /// Delete an area.
    pub fn delete_area(conn: &Connection, id: &str) -> Result<bool, TaskError> {
        TaskRepository::delete_area(conn, id)
    }

    /// List areas with counts.
    pub fn list_areas(
        conn: &Connection,
        filter: &AreaFilter,
        limit: u32,
        offset: u32,
    ) -> Result<AreaListResult, TaskError> {
        TaskRepository::list_areas(conn, filter, limit, offset)
    }
}
