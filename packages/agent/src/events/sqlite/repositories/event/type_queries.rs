use super::*;

impl EventRepo {
    /// Get events of specific types within a session.
    pub fn get_by_types(
        conn: &Connection,
        session_id: &str,
        types: &[&str],
        limit: Option<i64>,
    ) -> Result<Vec<EventRow>> {
        if types.is_empty() {
            return Ok(Vec::new());
        }

        // Build the type placeholders starting after session_id (?1)
        let placeholders: Vec<String> = (2..=types.len() + 1).map(|i| format!("?{i}")).collect();
        let mut sql = format!(
            "SELECT {EVENT_COLUMNS} FROM events WHERE session_id = ?1 AND type IN ({}) ORDER BY sequence ASC",
            placeholders.join(", ")
        );
        if let Some(limit) = limit {
            use std::fmt::Write;
            let _ = write!(sql, " LIMIT {limit}");
        }

        let mut stmt = conn.prepare_cached(&sql)?;
        let mut param_values = Vec::with_capacity(1 + types.len());
        param_values.push(session_id.to_string());
        param_values.extend(types.iter().map(std::string::ToString::to_string));

        let rows = stmt
            .query_map(
                rusqlite::params_from_iter(param_values.iter()),
                Self::map_row,
            )?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Get the latest event of a specific type within a session.
    pub fn get_latest_by_type(
        conn: &Connection,
        session_id: &str,
        event_type: &str,
    ) -> Result<Option<EventRow>> {
        let sql = format!(
            "SELECT {EVENT_COLUMNS} FROM events WHERE session_id = ?1 AND type = ?2 ORDER BY sequence DESC LIMIT 1"
        );
        Ok(conn
            .query_row(&sql, params![session_id, event_type], Self::map_row)
            .optional()?)
    }

    /// Count events of a specific type in a session.
    pub fn count_by_type(conn: &Connection, session_id: &str, event_type: &str) -> Result<i64> {
        let count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM events WHERE session_id = ?1 AND type = ?2",
            params![session_id, event_type],
            |row| row.get(0),
        )?;
        Ok(count)
    }

    /// Get events of specific types across multiple sessions.
    ///
    /// Results are ordered by `session_id`, then by sequence ascending within each session.
    pub fn get_by_sessions_and_types(
        conn: &Connection,
        session_ids: &[&str],
        types: &[&str],
    ) -> Result<Vec<EventRow>> {
        if session_ids.is_empty() || types.is_empty() {
            return Ok(Vec::new());
        }

        let max_chunk_size = SQLITE_BIND_LIMIT.saturating_sub(types.len()).max(1);
        let mut all_rows = Vec::new();

        for session_chunk in session_ids.chunks(max_chunk_size) {
            let session_placeholders: Vec<String> =
                (1..=session_chunk.len()).map(|i| format!("?{i}")).collect();
            let type_placeholders: Vec<String> = (0..types.len())
                .map(|i| format!("?{}", session_chunk.len() + i + 1))
                .collect();
            let sql = format!(
                "SELECT {EVENT_COLUMNS}
                 FROM events
                 WHERE session_id IN ({})
                   AND type IN ({})
                 ORDER BY session_id ASC, sequence ASC",
                session_placeholders.join(", "),
                type_placeholders.join(", ")
            );

            let mut stmt = conn.prepare_cached(&sql)?;
            let mut param_values = Vec::with_capacity(session_chunk.len() + types.len());
            param_values.extend(session_chunk.iter().map(std::string::ToString::to_string));
            param_values.extend(types.iter().map(std::string::ToString::to_string));

            let rows = stmt
                .query_map(
                    rusqlite::params_from_iter(param_values.iter()),
                    Self::map_row,
                )?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            all_rows.extend(rows);
        }

        Ok(all_rows)
    }

    /// Get events by workspace and types (cross-session).
    pub fn get_by_workspace_and_types(
        conn: &Connection,
        workspace_id: &str,
        types: &[&str],
        limit: Option<i64>,
        offset: Option<i64>,
    ) -> Result<Vec<EventRow>> {
        if types.is_empty() {
            return Ok(Vec::new());
        }

        let placeholders: Vec<String> = (2..=types.len() + 1).map(|i| format!("?{i}")).collect();
        let mut sql = format!(
            "SELECT {EVENT_COLUMNS} FROM events WHERE workspace_id = ?1 AND type IN ({}) ORDER BY timestamp DESC",
            placeholders.join(", ")
        );
        if let Some(limit) = limit {
            use std::fmt::Write;
            let _ = write!(sql, " LIMIT {limit}");
        }
        if let Some(offset) = offset {
            use std::fmt::Write;
            let _ = write!(sql, " OFFSET {offset}");
        }

        let mut stmt = conn.prepare_cached(&sql)?;
        let mut param_values = Vec::with_capacity(1 + types.len());
        param_values.push(workspace_id.to_string());
        param_values.extend(types.iter().map(std::string::ToString::to_string));

        let rows = stmt
            .query_map(
                rusqlite::params_from_iter(param_values.iter()),
                Self::map_row,
            )?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Count events by workspace and types.
    pub fn count_by_workspace_and_types(
        conn: &Connection,
        workspace_id: &str,
        types: &[&str],
    ) -> Result<i64> {
        if types.is_empty() {
            return Ok(0);
        }

        let placeholders: Vec<String> = (2..=types.len() + 1).map(|i| format!("?{i}")).collect();
        let sql = format!(
            "SELECT COUNT(*) FROM events WHERE workspace_id = ?1 AND type IN ({})",
            placeholders.join(", ")
        );

        let mut stmt = conn.prepare_cached(&sql)?;
        let mut param_values = Vec::with_capacity(1 + types.len());
        param_values.push(workspace_id.to_string());
        param_values.extend(types.iter().map(std::string::ToString::to_string));

        let count: i64 = stmt
            .query_row(rusqlite::params_from_iter(param_values.iter()), |row| {
                row.get(0)
            })?;
        Ok(count)
    }

    /// Get events across multiple workspaces by types (cross-session, cross-workspace).
    pub fn get_by_workspaces_and_types(
        conn: &Connection,
        workspace_ids: &[&str],
        types: &[&str],
        limit: Option<i64>,
        offset: Option<i64>,
    ) -> Result<Vec<EventRow>> {
        if workspace_ids.is_empty() || types.is_empty() {
            return Ok(Vec::new());
        }

        let ws_placeholders: Vec<String> =
            (1..=workspace_ids.len()).map(|i| format!("?{i}")).collect();
        let type_start = workspace_ids.len() + 1;
        let type_placeholders: Vec<String> = (type_start..type_start + types.len())
            .map(|i| format!("?{i}"))
            .collect();

        let mut sql = format!(
            "SELECT {EVENT_COLUMNS} FROM events WHERE workspace_id IN ({}) AND type IN ({}) ORDER BY timestamp DESC",
            ws_placeholders.join(", "),
            type_placeholders.join(", ")
        );
        if let Some(limit) = limit {
            use std::fmt::Write;
            let _ = write!(sql, " LIMIT {limit}");
        }
        if let Some(offset) = offset {
            use std::fmt::Write;
            let _ = write!(sql, " OFFSET {offset}");
        }

        let mut stmt = conn.prepare_cached(&sql)?;
        let mut param_values = Vec::with_capacity(workspace_ids.len() + types.len());
        param_values.extend(workspace_ids.iter().map(std::string::ToString::to_string));
        param_values.extend(types.iter().map(std::string::ToString::to_string));

        let rows = stmt
            .query_map(
                rusqlite::params_from_iter(param_values.iter()),
                Self::map_row,
            )?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Get events of specific types across ALL workspaces (global query).
    pub fn get_all_by_types(
        conn: &Connection,
        types: &[&str],
        limit: Option<i64>,
        offset: Option<i64>,
    ) -> Result<Vec<EventRow>> {
        if types.is_empty() {
            return Ok(Vec::new());
        }

        let placeholders: Vec<String> = (1..=types.len()).map(|i| format!("?{i}")).collect();
        let mut sql = format!(
            "SELECT {EVENT_COLUMNS} FROM events WHERE type IN ({}) ORDER BY timestamp DESC",
            placeholders.join(", ")
        );
        if let Some(limit) = limit {
            use std::fmt::Write;
            let _ = write!(sql, " LIMIT {limit}");
        }
        if let Some(offset) = offset {
            use std::fmt::Write;
            let _ = write!(sql, " OFFSET {offset}");
        }

        let mut stmt = conn.prepare_cached(&sql)?;
        let param_values: Vec<String> =
            types.iter().map(std::string::ToString::to_string).collect();

        let rows = stmt
            .query_map(
                rusqlite::params_from_iter(param_values.iter()),
                Self::map_row,
            )?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Count events of specific types across ALL workspaces (global query).
    pub fn count_all_by_types(conn: &Connection, types: &[&str]) -> Result<i64> {
        if types.is_empty() {
            return Ok(0);
        }

        let placeholders: Vec<String> = (1..=types.len()).map(|i| format!("?{i}")).collect();
        let sql = format!(
            "SELECT COUNT(*) FROM events WHERE type IN ({})",
            placeholders.join(", ")
        );

        let mut stmt = conn.prepare_cached(&sql)?;
        let param_values: Vec<String> =
            types.iter().map(std::string::ToString::to_string).collect();

        let count: i64 = stmt
            .query_row(rusqlite::params_from_iter(param_values.iter()), |row| {
                row.get(0)
            })?;
        Ok(count)
    }

    /// Count events across multiple workspaces by types.
    pub fn count_by_workspaces_and_types(
        conn: &Connection,
        workspace_ids: &[&str],
        types: &[&str],
    ) -> Result<i64> {
        if workspace_ids.is_empty() || types.is_empty() {
            return Ok(0);
        }

        let ws_placeholders: Vec<String> =
            (1..=workspace_ids.len()).map(|i| format!("?{i}")).collect();
        let type_start = workspace_ids.len() + 1;
        let type_placeholders: Vec<String> = (type_start..type_start + types.len())
            .map(|i| format!("?{i}"))
            .collect();

        let sql = format!(
            "SELECT COUNT(*) FROM events WHERE workspace_id IN ({}) AND type IN ({})",
            ws_placeholders.join(", "),
            type_placeholders.join(", ")
        );

        let mut stmt = conn.prepare_cached(&sql)?;
        let mut param_values = Vec::with_capacity(workspace_ids.len() + types.len());
        param_values.extend(workspace_ids.iter().map(std::string::ToString::to_string));
        param_values.extend(types.iter().map(std::string::ToString::to_string));

        let count: i64 = stmt
            .query_row(rusqlite::params_from_iter(param_values.iter()), |row| {
                row.get(0)
            })?;
        Ok(count)
    }

    /// Aggregate token usage across all events in a session.
    pub fn get_token_usage_summary(
        conn: &Connection,
        session_id: &str,
    ) -> Result<TokenTotals> {
        let summary = conn.query_row(
            "SELECT COALESCE(SUM(input_tokens), 0),
                    COALESCE(SUM(output_tokens), 0),
                    COALESCE(SUM(cache_read_tokens), 0),
                    COALESCE(SUM(cache_creation_tokens), 0)
             FROM events WHERE session_id = ?1",
            params![session_id],
            |row| {
                Ok(TokenTotals {
                    input_tokens: row.get(0)?,
                    output_tokens: row.get(1)?,
                    cache_read_tokens: row.get(2)?,
                    cache_creation_tokens: row.get(3)?,
                })
            },
        )?;
        Ok(summary)
    }
}
