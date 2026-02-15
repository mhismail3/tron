use std::collections::HashMap;
use std::sync::Arc;

use chrono::Utc;
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};

use tron_core::events::PersistenceEventType;
use tron_core::ids::{EventId, SessionId, WorkspaceId};
use tron_core::messages::Message;

use crate::database::Database;
use crate::error::StoreError;

/// A stored event row.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct EventRow {
    pub id: EventId,
    pub session_id: SessionId,
    pub parent_id: Option<EventId>,
    pub sequence: i64,
    pub depth: i64,
    pub event_type: String,
    pub timestamp: String,
    pub payload: serde_json::Value,
    pub workspace_id: WorkspaceId,
}

/// Per-session append lock for event linearization.
/// Ensures the parent chain is maintained atomically.
struct SessionLocks {
    locks: HashMap<String, Arc<Mutex<()>>>,
}

impl SessionLocks {
    fn new() -> Self {
        Self {
            locks: HashMap::new(),
        }
    }

    fn get(&mut self, session_id: &str) -> Arc<Mutex<()>> {
        self.locks
            .entry(session_id.to_string())
            .or_insert_with(|| Arc::new(Mutex::new(())))
            .clone()
    }
}

pub struct EventRepo {
    db: Database,
    session_locks: Mutex<SessionLocks>,
}

impl EventRepo {
    pub fn new(db: Database) -> Self {
        Self {
            db,
            session_locks: Mutex::new(SessionLocks::new()),
        }
    }

    /// Append an event to a session. Atomically:
    /// 1. Acquires per-session lock
    /// 2. Reads current head
    /// 3. Inserts event with parent_id = current head
    /// 4. Updates session head_event_id
    pub fn append(
        &self,
        session_id: &SessionId,
        workspace_id: &WorkspaceId,
        event_type: PersistenceEventType,
        payload: serde_json::Value,
    ) -> Result<EventRow, StoreError> {
        self.append_with_depth(session_id, workspace_id, event_type, payload, 0)
    }

    /// Append an event with a specific depth (for sub-agent events).
    pub fn append_with_depth(
        &self,
        session_id: &SessionId,
        workspace_id: &WorkspaceId,
        event_type: PersistenceEventType,
        payload: serde_json::Value,
        depth: i64,
    ) -> Result<EventRow, StoreError> {
        let lock = self.session_locks.lock().get(session_id.as_str());
        let _guard = lock.lock();

        self.db.with_conn(|conn| {
            // Get current head and max sequence
            let (head_event_id, max_seq): (Option<String>, i64) = conn
                .query_row(
                    "SELECT head_event_id, COALESCE((SELECT MAX(sequence) FROM events WHERE session_id = ?1), -1)
                     FROM sessions WHERE id = ?1",
                    [session_id.as_str()],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .map_err(|_| StoreError::NotFound(format!("session {session_id}")))?;

            let event_id = EventId::new();
            let now = Utc::now().to_rfc3339();
            let sequence = max_seq + 1;
            let type_str = event_type.to_string();

            let parent_id = head_event_id.as_deref();

            // Insert event
            conn.execute(
                "INSERT INTO events (id, session_id, parent_id, sequence, depth, type, timestamp, payload, workspace_id)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                rusqlite::params![
                    event_id.as_str(),
                    session_id.as_str(),
                    parent_id,
                    sequence,
                    depth,
                    type_str,
                    now,
                    serde_json::to_string(&payload)?,
                    workspace_id.as_str(),
                ],
            )?;

            // Update session head (and root if this is the first event)
            if head_event_id.is_none() {
                conn.execute(
                    "UPDATE sessions SET head_event_id = ?1, root_event_id = ?1, updated_at = ?2 WHERE id = ?3",
                    rusqlite::params![event_id.as_str(), now, session_id.as_str()],
                )?;
            } else {
                conn.execute(
                    "UPDATE sessions SET head_event_id = ?1, updated_at = ?2 WHERE id = ?3",
                    rusqlite::params![event_id.as_str(), now, session_id.as_str()],
                )?;
            }

            Ok(EventRow {
                id: event_id,
                session_id: session_id.clone(),
                parent_id: head_event_id.map(EventId::from_raw),
                sequence,
                depth,
                event_type: type_str,
                timestamp: now,
                payload,
                workspace_id: workspace_id.clone(),
            })
        })
    }

    /// Get a single event by ID.
    pub fn get(&self, event_id: &EventId) -> Result<EventRow, StoreError> {
        self.db.with_conn(|conn| {
            conn.query_row(
                "SELECT id, session_id, parent_id, sequence, depth, type, timestamp, payload, workspace_id
                 FROM events WHERE id = ?1",
                [event_id.as_str()],
                |row| Ok(row_to_event(row)),
            )
            .map_err(|_| StoreError::NotFound(format!("event {event_id}")))
        })
    }

    /// List events for a session, ordered by sequence.
    pub fn list(
        &self,
        session_id: &SessionId,
        limit: Option<u32>,
        offset: Option<u32>,
    ) -> Result<Vec<EventRow>, StoreError> {
        self.db.with_conn(|conn| {
            let limit = limit.unwrap_or(1000);
            let offset = offset.unwrap_or(0);
            let mut stmt = conn.prepare(
                "SELECT id, session_id, parent_id, sequence, depth, type, timestamp, payload, workspace_id
                 FROM events WHERE session_id = ?1
                 ORDER BY sequence ASC
                 LIMIT ?2 OFFSET ?3",
            )?;
            let rows = stmt
                .query_map(
                    rusqlite::params![session_id.as_str(), limit, offset],
                    |row| Ok(row_to_event(row)),
                )?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
    }

    /// List events for sync (events after a given sequence number).
    pub fn list_after_sequence(
        &self,
        session_id: &SessionId,
        after_sequence: i64,
        limit: u32,
    ) -> Result<Vec<EventRow>, StoreError> {
        self.db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT id, session_id, parent_id, sequence, depth, type, timestamp, payload, workspace_id
                 FROM events WHERE session_id = ?1 AND sequence > ?2
                 ORDER BY sequence ASC
                 LIMIT ?3",
            )?;
            let rows = stmt
                .query_map(
                    rusqlite::params![session_id.as_str(), after_sequence, limit],
                    |row| Ok(row_to_event(row)),
                )?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
    }

    /// Reconstruct messages from events for a session.
    /// Walks events in order, applying compaction boundaries:
    /// - Events before a compact_boundary are skipped
    /// - compact_summary provides the summary message
    /// - message_user, message_assistant, tool_result events become messages
    pub fn reconstruct_messages(
        &self,
        session_id: &SessionId,
    ) -> Result<Vec<Message>, StoreError> {
        let events = self.list(session_id, None, None)?;
        reconstruct_from_events(&events)
    }

    /// Count events for a session.
    pub fn count(&self, session_id: &SessionId) -> Result<i64, StoreError> {
        self.db.with_conn(|conn| {
            conn.query_row(
                "SELECT COUNT(*) FROM events WHERE session_id = ?1",
                [session_id.as_str()],
                |row| row.get(0),
            )
            .map_err(|e| StoreError::Database(e.to_string()))
        })
    }
}

/// Reconstruct messages from a list of events.
/// Public so it can be used in tests and by the engine.
pub fn reconstruct_from_events(events: &[EventRow]) -> Result<Vec<Message>, StoreError> {
    let mut messages = Vec::new();

    // Find the last compact_boundary — skip everything before it
    let start_idx = events
        .iter()
        .rposition(|e| e.event_type == "compact_boundary")
        .map(|i| i + 1)
        .unwrap_or(0);

    for event in &events[start_idx..] {
        match event.event_type.as_str() {
            "message_user" | "message_assistant" | "tool_result" => {
                if let Ok(msg) = serde_json::from_value::<Message>(event.payload.clone()) {
                    messages.push(msg);
                }
            }
            "compact_summary" => {
                if let Some(summary) = event.payload.get("summary").and_then(|s| s.as_str()) {
                    messages.push(Message::user_text(format!(
                        "[Context from earlier in this conversation]\n\n{summary}"
                    )));
                    messages.push(Message::assistant_text(
                        "I understand. I'll keep this context in mind as we continue.",
                    ));
                }
            }
            _ => {
                // Other event types (tool_call, stream_turn_start, etc.) don't produce messages
            }
        }
    }

    Ok(messages)
}

fn row_to_event(row: &rusqlite::Row<'_>) -> EventRow {
    let payload_str: String = row.get(7).unwrap();
    EventRow {
        id: EventId::from_raw(row.get::<_, String>(0).unwrap()),
        session_id: SessionId::from_raw(row.get::<_, String>(1).unwrap()),
        parent_id: row
            .get::<_, Option<String>>(2)
            .unwrap()
            .map(EventId::from_raw),
        sequence: row.get(3).unwrap(),
        depth: row.get(4).unwrap(),
        event_type: row.get(5).unwrap(),
        timestamp: row.get(6).unwrap(),
        payload: serde_json::from_str(&payload_str).unwrap_or(serde_json::Value::Null),
        workspace_id: WorkspaceId::from_raw(row.get::<_, String>(8).unwrap()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sessions::SessionRepo;
    use crate::workspaces::WorkspaceRepo;
    use serde_json::json;
    use tron_core::ids::ToolCallId;

    fn setup() -> (Database, SessionId, WorkspaceId) {
        let db = Database::in_memory().unwrap();
        let ws_repo = WorkspaceRepo::new(db.clone());
        let ws = ws_repo.get_or_create("/test", "test").unwrap();
        let sess_repo = SessionRepo::new(db.clone());
        let session = sess_repo
            .create(&ws.id, "claude-opus-4-6", "anthropic", "/tmp")
            .unwrap();
        (db, session.id, ws.id)
    }

    #[test]
    fn append_event() {
        let (db, sess_id, ws_id) = setup();
        let repo = EventRepo::new(db);
        let evt = repo
            .append(
                &sess_id,
                &ws_id,
                PersistenceEventType::MessageUser,
                json!({"role": "user", "content": [{"type": "text", "text": "hello"}]}),
            )
            .unwrap();
        assert!(evt.id.as_str().starts_with("evt_"));
        assert_eq!(evt.sequence, 0);
        assert!(evt.parent_id.is_none()); // First event has no parent
    }

    #[test]
    fn append_builds_parent_chain() {
        let (db, sess_id, ws_id) = setup();
        let repo = EventRepo::new(db);

        let e1 = repo
            .append(&sess_id, &ws_id, PersistenceEventType::MessageUser, json!({"msg": "1"}))
            .unwrap();
        let e2 = repo
            .append(&sess_id, &ws_id, PersistenceEventType::MessageAssistant, json!({"msg": "2"}))
            .unwrap();
        let e3 = repo
            .append(&sess_id, &ws_id, PersistenceEventType::MessageUser, json!({"msg": "3"}))
            .unwrap();

        assert!(e1.parent_id.is_none());
        assert_eq!(e2.parent_id.as_ref().unwrap(), &e1.id);
        assert_eq!(e3.parent_id.as_ref().unwrap(), &e2.id);

        assert_eq!(e1.sequence, 0);
        assert_eq!(e2.sequence, 1);
        assert_eq!(e3.sequence, 2);
    }

    #[test]
    fn append_updates_session_head() {
        let (db, sess_id, ws_id) = setup();
        let repo = EventRepo::new(db.clone());
        let sess_repo = SessionRepo::new(db);

        let e1 = repo
            .append(&sess_id, &ws_id, PersistenceEventType::MessageUser, json!({}))
            .unwrap();

        let session = sess_repo.get(&sess_id).unwrap();
        assert_eq!(session.head_event_id.as_ref().unwrap(), &e1.id);
        assert_eq!(session.root_event_id.as_ref().unwrap(), &e1.id);

        let e2 = repo
            .append(&sess_id, &ws_id, PersistenceEventType::MessageAssistant, json!({}))
            .unwrap();

        let session = sess_repo.get(&sess_id).unwrap();
        assert_eq!(session.head_event_id.as_ref().unwrap(), &e2.id);
        // Root stays at first event
        assert_eq!(session.root_event_id.as_ref().unwrap(), &e1.id);
    }

    #[test]
    fn get_event() {
        let (db, sess_id, ws_id) = setup();
        let repo = EventRepo::new(db);
        let evt = repo
            .append(&sess_id, &ws_id, PersistenceEventType::MessageUser, json!({"text": "hi"}))
            .unwrap();

        let fetched = repo.get(&evt.id).unwrap();
        assert_eq!(fetched.id, evt.id);
        assert_eq!(fetched.payload["text"], "hi");
    }

    #[test]
    fn list_events() {
        let (db, sess_id, ws_id) = setup();
        let repo = EventRepo::new(db);

        for i in 0..5 {
            repo.append(
                &sess_id,
                &ws_id,
                PersistenceEventType::MessageUser,
                json!({"n": i}),
            )
            .unwrap();
        }

        let all = repo.list(&sess_id, None, None).unwrap();
        assert_eq!(all.len(), 5);
        // Verify ordering
        for (i, evt) in all.iter().enumerate() {
            assert_eq!(evt.sequence, i as i64);
        }
    }

    #[test]
    fn list_after_sequence() {
        let (db, sess_id, ws_id) = setup();
        let repo = EventRepo::new(db);

        for i in 0..5 {
            repo.append(
                &sess_id,
                &ws_id,
                PersistenceEventType::MessageUser,
                json!({"n": i}),
            )
            .unwrap();
        }

        let after_2 = repo.list_after_sequence(&sess_id, 2, 100).unwrap();
        assert_eq!(after_2.len(), 2); // sequence 3 and 4
        assert_eq!(after_2[0].sequence, 3);
        assert_eq!(after_2[1].sequence, 4);
    }

    #[test]
    fn count_events() {
        let (db, sess_id, ws_id) = setup();
        let repo = EventRepo::new(db);

        assert_eq!(repo.count(&sess_id).unwrap(), 0);

        for _ in 0..3 {
            repo.append(&sess_id, &ws_id, PersistenceEventType::MessageUser, json!({}))
                .unwrap();
        }

        assert_eq!(repo.count(&sess_id).unwrap(), 3);
    }

    #[test]
    fn reconstruct_simple_conversation() {
        let (db, sess_id, ws_id) = setup();
        let repo = EventRepo::new(db);

        // User message
        repo.append(
            &sess_id,
            &ws_id,
            PersistenceEventType::MessageUser,
            serde_json::to_value(Message::user_text("hello")).unwrap(),
        )
        .unwrap();

        // Assistant message
        repo.append(
            &sess_id,
            &ws_id,
            PersistenceEventType::MessageAssistant,
            serde_json::to_value(Message::assistant_text("hi there")).unwrap(),
        )
        .unwrap();

        // Tool call event (not a message — skipped)
        repo.append(
            &sess_id,
            &ws_id,
            PersistenceEventType::ToolCall,
            json!({"tool": "Read", "args": {}}),
        )
        .unwrap();

        // Tool result message
        let tc_id = ToolCallId::new();
        repo.append(
            &sess_id,
            &ws_id,
            PersistenceEventType::ToolResult,
            serde_json::to_value(Message::tool_result(tc_id, "file contents")).unwrap(),
        )
        .unwrap();

        let messages = repo.reconstruct_messages(&sess_id).unwrap();
        assert_eq!(messages.len(), 3); // user, assistant, tool_result (tool_call event is not a message)
    }

    #[test]
    fn reconstruct_with_compaction() {
        let (db, sess_id, ws_id) = setup();
        let repo = EventRepo::new(db);

        // Old messages (pre-compaction)
        repo.append(
            &sess_id,
            &ws_id,
            PersistenceEventType::MessageUser,
            serde_json::to_value(Message::user_text("old message 1")).unwrap(),
        )
        .unwrap();
        repo.append(
            &sess_id,
            &ws_id,
            PersistenceEventType::MessageAssistant,
            serde_json::to_value(Message::assistant_text("old response 1")).unwrap(),
        )
        .unwrap();

        // Compact boundary
        repo.append(
            &sess_id,
            &ws_id,
            PersistenceEventType::CompactBoundary,
            json!({"reason": "context_limit"}),
        )
        .unwrap();

        // Compact summary (right after boundary in sequence)
        repo.append(
            &sess_id,
            &ws_id,
            PersistenceEventType::CompactSummary,
            json!({"summary": "The user asked about X and I explained Y."}),
        )
        .unwrap();

        // New messages (post-compaction)
        repo.append(
            &sess_id,
            &ws_id,
            PersistenceEventType::MessageUser,
            serde_json::to_value(Message::user_text("new question")).unwrap(),
        )
        .unwrap();
        repo.append(
            &sess_id,
            &ws_id,
            PersistenceEventType::MessageAssistant,
            serde_json::to_value(Message::assistant_text("new answer")).unwrap(),
        )
        .unwrap();

        let messages = repo.reconstruct_messages(&sess_id).unwrap();
        // Should have: compact_summary (user+assistant pair) + new question + new answer = 4
        assert_eq!(messages.len(), 4);

        // First message should be the compaction context
        let first_text = match &messages[0] {
            Message::User(u) => match &u.content[0] {
                tron_core::messages::UserContent::Text { text } => text.clone(),
                _ => panic!("expected text"),
            },
            _ => panic!("expected user message"),
        };
        assert!(first_text.contains("Context from earlier"));
        assert!(first_text.contains("The user asked about X"));
    }

    #[test]
    fn reconstruct_empty_session() {
        let (db, sess_id, _) = setup();
        let repo = EventRepo::new(db);
        let messages = repo.reconstruct_messages(&sess_id).unwrap();
        assert!(messages.is_empty());
    }

    #[test]
    fn append_with_depth() {
        let (db, sess_id, ws_id) = setup();
        let repo = EventRepo::new(db);

        let evt = repo
            .append_with_depth(
                &sess_id,
                &ws_id,
                PersistenceEventType::MessageUser,
                json!({}),
                1,
            )
            .unwrap();
        assert_eq!(evt.depth, 1);
    }

    #[test]
    fn concurrent_appends_linearized() {
        // This test verifies that concurrent appends to the same session
        // produce a valid parent chain (no gaps, no duplicates).
        let (db, sess_id, ws_id) = setup();
        let repo = Arc::new(EventRepo::new(db));

        let mut handles = vec![];
        for i in 0..10 {
            let repo = repo.clone();
            let sid = sess_id.clone();
            let wid = ws_id.clone();
            handles.push(std::thread::spawn(move || {
                repo.append(
                    &sid,
                    &wid,
                    PersistenceEventType::MessageUser,
                    json!({"thread": i}),
                )
                .unwrap()
            }));
        }

        let events: Vec<EventRow> = handles.into_iter().map(|h| h.join().unwrap()).collect();

        // All should have unique sequences
        let mut seqs: Vec<i64> = events.iter().map(|e| e.sequence).collect();
        seqs.sort();
        seqs.dedup();
        assert_eq!(seqs.len(), 10);

        // Parent chain should be valid
        let all_events = repo.list(&sess_id, None, None).unwrap();
        for (i, evt) in all_events.iter().enumerate() {
            if i == 0 {
                assert!(evt.parent_id.is_none());
            } else {
                assert_eq!(
                    evt.parent_id.as_ref().unwrap(),
                    &all_events[i - 1].id,
                    "broken parent chain at sequence {}",
                    evt.sequence
                );
            }
        }
    }
}
