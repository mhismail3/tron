use super::*;
use super::extractors::*;

impl EventRepo {
    /// Insert a single event, extracting denormalized fields from the payload.
    pub fn insert(conn: &Connection, event: &SessionEvent) -> Result<()> {
        let role = extract_role(event);
        let tool_name = extract_tool_name(event);
        let tool_call_id = extract_str(&event.payload, "toolCallId");
        let turn = extract_i64(&event.payload, "turn");
        let depth = Self::compute_depth(conn, event.parent_id.as_deref())?;

        // Extract token usage from payload.tokenUsage or payload directly
        let (input_tokens, output_tokens, cache_read, cache_create) =
            extract_tokens(&event.payload);

        // Extract v002 per-turn metadata
        let model = extract_str(&event.payload, "model");
        let latency_ms = extract_i64(&event.payload, "latency");
        let stop_reason = extract_str(&event.payload, "stopReason");
        let has_thinking = extract_bool_as_int(&event.payload, "hasThinking");
        let provider_type = extract_str(&event.payload, "providerType");
        let cost = event.payload.get("cost").and_then(Value::as_f64);

        let payload_str = serde_json::to_string(&event.payload)?;

        let sql = format!(
            "INSERT INTO events ({EVENT_COLUMNS})
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
                     ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25)"
        );
        let mut stmt = conn.prepare_cached(&sql)?;
        let _ = stmt.execute(params![
            event.id,
            event.session_id,
            event.parent_id,
            event.sequence,
            depth,
            event.event_type.as_str(),
            event.timestamp,
            payload_str,
            Option::<String>::None, // content_blob_id
            event.workspace_id,
            role,
            tool_name,
            tool_call_id,
            turn,
            input_tokens,
            output_tokens,
            cache_read,
            cache_create,
            event.checksum,
            model,
            latency_ms,
            stop_reason,
            has_thinking,
            provider_type,
            cost,
        ])?;
        Ok(())
    }

    /// Get a single event by ID.
    pub fn get_by_id(conn: &Connection, event_id: &str) -> Result<Option<EventRow>> {
        let sql = format!("SELECT {EVENT_COLUMNS} FROM events WHERE id = ?1");
        let mut stmt = conn.prepare_cached(&sql)?;
        let row = stmt
            .query_row(params![event_id], Self::map_row)
            .optional()?;
        Ok(row)
    }

    /// Get the latest event for a session.
    pub fn get_latest(conn: &Connection, session_id: &str) -> Result<Option<EventRow>> {
        let sql = format!(
            "SELECT {EVENT_COLUMNS} FROM events WHERE session_id = ?1 ORDER BY sequence DESC LIMIT 1"
        );
        let row = conn
            .query_row(&sql, params![session_id], Self::map_row)
            .optional()?;
        Ok(row)
    }

    /// Check if event exists.
    pub fn exists(conn: &Connection, event_id: &str) -> Result<bool> {
        let exists: bool = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM events WHERE id = ?1)",
            params![event_id],
            |row| row.get(0),
        )?;
        Ok(exists)
    }

    /// Total event count across all sessions.
    pub fn count(conn: &Connection) -> Result<i64> {
        let count: i64 = conn.query_row("SELECT COUNT(*) FROM events", [], |row| row.get(0))?;
        Ok(count)
    }

    /// Delete a single event.
    pub fn delete(conn: &Connection, event_id: &str) -> Result<bool> {
        let changed = conn.execute("DELETE FROM events WHERE id = ?1", params![event_id])?;
        Ok(changed > 0)
    }

    /// Delete all events for a session. Returns count deleted.
    pub fn delete_by_session(conn: &Connection, session_id: &str) -> Result<usize> {
        let changed = conn.execute(
            "DELETE FROM events WHERE session_id = ?1",
            params![session_id],
        )?;
        Ok(changed)
    }

    /// Batch-fetch events by IDs.
    ///
    /// Returns a map of `event_id → EventRow`. Missing IDs are silently omitted.
    pub fn get_by_ids(
        conn: &Connection,
        event_ids: &[&str],
    ) -> Result<std::collections::HashMap<String, EventRow>> {
        let mut result = std::collections::HashMap::new();
        if event_ids.is_empty() {
            return Ok(result);
        }

        let placeholders: Vec<String> = (1..=event_ids.len()).map(|i| format!("?{i}")).collect();
        let sql = format!(
            "SELECT {EVENT_COLUMNS} FROM events WHERE id IN ({})",
            placeholders.join(", ")
        );

        let mut stmt = conn.prepare_cached(&sql)?;
        let params: Vec<&dyn rusqlite::types::ToSql> = event_ids
            .iter()
            .map(|s| s as &dyn rusqlite::types::ToSql)
            .collect();
        let rows = stmt
            .query_map(params.as_slice(), Self::map_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;

        for row in rows {
            let _ = result.insert(row.id.clone(), row);
        }
        Ok(result)
    }
}
