use rusqlite::params;

use super::*;

impl InMemoryEngineResourceStore {
    /// List resource events that belong to one trace.
    pub fn events_by_trace(
        &self,
        trace_id: &str,
        limit: usize,
    ) -> Result<Vec<EngineResourceEvent>> {
        if limit == 0 {
            return Err(EngineError::PolicyViolation(
                "resource event list limit must be greater than zero".to_owned(),
            ));
        }
        let mut events = self
            .events_by_resource
            .values()
            .flatten()
            .filter(|event| event.trace_id.as_str() == trace_id)
            .cloned()
            .collect::<Vec<_>>();
        events.sort_by_key(|event| event.occurred_at);
        events.truncate(limit.min(500));
        Ok(events)
    }
}

impl SqliteEngineResourceStore {
    /// List resource events that belong to one trace.
    pub fn events_by_trace(
        &self,
        trace_id: &str,
        limit: usize,
    ) -> Result<Vec<EngineResourceEvent>> {
        if limit == 0 {
            return Err(EngineError::PolicyViolation(
                "resource event list limit must be greater than zero".to_owned(),
            ));
        }
        let mut stmt = self
            .conn
            .prepare(
                "SELECT event_id, resource_id, event_type, payload_json, invocation_id, trace_id,
                        occurred_at
                 FROM engine_resource_events
                 WHERE trace_id = ?1
                 ORDER BY occurred_at ASC
                 LIMIT ?2",
            )
            .map_err(|err| sqlite_err("resource.events_by_trace.prepare", err.to_string()))?;
        let rows = stmt
            .query_map(
                params![trace_id, limit.min(500) as i64],
                row_to_resource_event,
            )
            .map_err(|err| sqlite_err("resource.events_by_trace.query", err.to_string()))?;
        collect_rows(rows, "resource.events_by_trace.row")
    }
}
