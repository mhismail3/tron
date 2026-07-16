//! Crash recovery — recovers partial LLM output from orphaned streaming journals.
//!
//! On server startup (before accepting client connections), `recover_incomplete_turns`
//! scans for orphaned journal files left by turns that were interrupted by a crash.
//! For each orphaned journal:
//!
//! 1. If that turn already has a durable `turn.failed` → treat the failure as
//!    authoritative and delete the stale journal without replaying it.
//! 2. If the session still exists in the DB → persist recovered content as a partial
//!    assistant message and a turn-end event, then delete the journal.
//! 3. If the session was deleted → log cleanup details and delete the journal.
//! 4. If the journal is empty or corrupted → log and delete.
//!
//! Recovery events use `sequence: None`; the event store assigns the next
//! sequence because the runtime counter is not initialized during startup recovery.
//!
//! ## Double-recovery safety
//!
//! Events are persisted before the journal is deleted. If the server crashes
//! between persist and delete, the next startup will re-process the same journal,
//! creating duplicate events. This is acceptable: duplicates carry `recovered: true`
//! and can be identified/deduped. Data loss (deleting journal before persist) would
//! be worse than duplication.

use std::fs;
use std::sync::Arc;

use serde_json::json;
use tracing::{debug, info, warn};

use crate::domains::agent::r#loop::orchestrator::streaming_journal::StreamingJournal;
use crate::domains::agent::r#loop::pipeline::persistence;
use crate::domains::session::event_store::{AppendOptions, EventStore, EventType};

/// Recover incomplete turns from orphaned streaming journals.
///
/// Returns the list of session IDs that had content recovered.
/// Called from server startup before accepting client connections.
pub fn recover_incomplete_turns(event_store: &Arc<EventStore>) -> Vec<String> {
    let incomplete = match StreamingJournal::scan_incomplete() {
        Ok(list) => list,
        Err(e) => {
            warn!(error = %e, "failed to scan for incomplete journals, skipping recovery");
            return Vec::new();
        }
    };

    if incomplete.is_empty() {
        return Vec::new();
    }

    info!(
        count = incomplete.len(),
        "found orphaned journals, starting crash recovery"
    );

    let mut recovered_sessions = Vec::new();

    for (session_id, turn) in incomplete {
        match recover_single_turn(event_store, &session_id, turn) {
            Ok(true) => {
                recovered_sessions.push(session_id);
            }
            Ok(false) => {
                // Journal was empty or session was deleted — already cleaned up
            }
            Err(e) => {
                warn!(
                    session_id,
                    turn,
                    error = %e,
                    "failed to recover turn, leaving journal for manual inspection"
                );
            }
        }
    }

    if !recovered_sessions.is_empty() {
        info!(
            count = recovered_sessions.len(),
            sessions = ?recovered_sessions,
            "crash recovery completed"
        );
    }

    recovered_sessions
}

/// Recover a single turn from its journal.
/// Returns Ok(true) if content was recovered, Ok(false) if journal was empty/session deleted.
fn recover_single_turn(
    event_store: &Arc<EventStore>,
    session_id: &str,
    turn: u32,
) -> Result<bool, Box<dyn std::error::Error>> {
    let journal_path = StreamingJournal::journal_path(session_id, turn);
    recover_single_turn_from_path(event_store, session_id, turn, &journal_path)
}

fn recover_single_turn_from_path(
    event_store: &Arc<EventStore>,
    session_id: &str,
    turn: u32,
    journal_path: &std::path::Path,
) -> Result<bool, Box<dyn std::error::Error>> {
    // Check if session still exists
    let session_exists = event_store.get_session(session_id)?.is_some();
    if !session_exists {
        info!(
            session_id,
            turn, "removed orphaned journal for deleted session"
        );
        fs::remove_file(&journal_path)?;
        cleanup_empty_session_dir(&journal_path);
        return Ok(false);
    }

    let has_durable_failure = event_store
        .get_events_by_type(session_id, &[EventType::TurnFailed.as_str()], None)?
        .into_iter()
        .any(|row| {
            serde_json::from_str::<serde_json::Value>(&row.payload)
                .ok()
                .and_then(|payload| payload.get("turn").and_then(serde_json::Value::as_u64))
                == Some(u64::from(turn))
        });
    if has_durable_failure {
        info!(
            session_id,
            turn, "removed stale streaming journal for durably failed turn"
        );
        fs::remove_file(journal_path)?;
        cleanup_empty_session_dir(journal_path);
        return Ok(false);
    }

    // Load recovery data
    let recovered = match StreamingJournal::load_recovery_from_path(journal_path, session_id, turn)?
    {
        Some(r) => r,
        None => {
            debug!(session_id, turn, "journal empty or corrupted, deleting");
            fs::remove_file(&journal_path)?;
            cleanup_empty_session_dir(&journal_path);
            return Ok(false);
        }
    };

    // Build canonical assistant content blocks for the partial message. The
    // journal preserves stream order, including capability positions from the
    // first draft marker rather than recovery-time bucket order.
    let content = persistence::build_content_json(&recovered.content);

    if content.is_empty() {
        debug!(
            session_id,
            turn, "recovered journal had no content, skipping persist"
        );
        fs::remove_file(&journal_path)?;
        cleanup_empty_session_dir(&journal_path);
        return Ok(false);
    }

    // Persist recovered content as a partial assistant message.
    // Include all required fields from AssistantMessagePayload schema so that
    // typed_payload() deserialization succeeds on recovered events.
    let msg_row = event_store.append(&AppendOptions {
        session_id,
        event_type: EventType::MessageAssistant,
        payload: json!({
            "content": content,
            "turn": turn,
            "model": "unknown",
            "stopReason": "crash_recovered",
            "tokenUsage": {
                "inputTokens": 0,
                "outputTokens": 0,
            },
            "partial": true,
            "recovered": true,
        }),
        sequence: None,
        parent_id: None,
    })?;
    debug!(session_id, turn, event_id = %msg_row.id, "persisted recovered assistant message");

    // Persist a turn-end event marking the turn as interrupted/recovered.
    // Include all required fields from StreamTurnEndPayload schema.
    let end_row = event_store.append(&AppendOptions {
        session_id,
        event_type: EventType::StreamTurnEnd,
        payload: json!({
            "turn": turn,
            "tokenUsage": {
                "inputTokens": 0,
                "outputTokens": 0,
            },
            "interrupted": true,
            "recovered": true,
        }),
        sequence: None,
        parent_id: None,
    })?;
    debug!(session_id, turn, event_id = %end_row.id, "persisted recovered turn-end event");

    info!(
        session_id,
        turn,
        text_len = recovered.accumulated_text.len(),
        thinking_len = recovered.accumulated_thinking.len(),
        capability_invocations = recovered.capability_invocations.len(),
        "recovered partial assistant message from crash"
    );

    // Delete the journal now that content is persisted
    fs::remove_file(&journal_path)?;
    cleanup_empty_session_dir(&journal_path);

    Ok(true)
}

/// Remove the parent directory if it's empty after journal deletion.
fn cleanup_empty_session_dir(journal_path: &std::path::Path) {
    if let Some(dir) = journal_path.parent() {
        if dir.exists() {
            if let Ok(mut entries) = fs::read_dir(dir) {
                if entries.next().is_none() {
                    let _ = fs::remove_dir(dir);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::session::event_store::ListEventsOptions;
    use crate::domains::session::event_store::sqlite::connection::{self, ConnectionConfig};
    use crate::domains::session::event_store::sqlite::migrations::run_migrations;
    use tempfile::TempDir;

    // Note: Full integration tests require a real EventStore with DB setup.
    // These tests verify the journal scanning and parsing logic in isolation.

    #[test]
    fn test_cleanup_empty_session_dir_removes_empty() {
        let tmp = TempDir::new().unwrap();
        let session_dir = tmp.path().join("session-x");
        fs::create_dir_all(&session_dir).unwrap();
        let fake_journal = session_dir.join("turn_1.wal");
        fs::File::create(&fake_journal).unwrap();
        // Remove the file, then cleanup should remove the dir
        fs::remove_file(&fake_journal).unwrap();
        cleanup_empty_session_dir(&fake_journal);
        assert!(!session_dir.exists());
    }

    #[test]
    fn test_cleanup_empty_session_dir_preserves_nonempty() {
        let tmp = TempDir::new().unwrap();
        let session_dir = tmp.path().join("session-y");
        fs::create_dir_all(&session_dir).unwrap();
        let f1 = session_dir.join("turn_1.wal");
        let f2 = session_dir.join("turn_2.wal");
        fs::File::create(&f1).unwrap();
        fs::File::create(&f2).unwrap();
        // Remove one file — dir still has another
        fs::remove_file(&f1).unwrap();
        cleanup_empty_session_dir(&f1);
        assert!(
            session_dir.exists(),
            "dir should remain (still has turn_2.wal)"
        );
    }

    #[test]
    fn test_recovered_turn_content_building() {
        // Verify the content block construction logic
        let mut args = serde_json::Map::new();
        let _ = args.insert("command".to_owned(), json!("ls"));
        let content = persistence::build_content_json(&[
            crate::shared::protocol::content::AssistantContent::text("Hello world"),
            crate::shared::protocol::content::AssistantContent::Thinking {
                thinking: "Let me think".to_owned(),
                kind: crate::shared::protocol::content::ThinkingContentKind::Thinking,
                signature: None,
            },
            crate::shared::protocol::content::AssistantContent::CapabilityInvocation {
                id: "tc_1".to_owned(),
                name: "execute".to_owned(),
                arguments: args,
                thought_signature: None,
            },
        ]);

        assert_eq!(content.len(), 3);
        assert_eq!(content[0]["type"], "text");
        assert_eq!(content[0]["text"], "Hello world");
        assert_eq!(content[1]["type"], "thinking");
        assert_eq!(content[2]["type"], "capability_invocation");
        assert!(content[2].get("capability_invocation").is_none());
        assert_eq!(content[2]["id"], "tc_1");
        assert_eq!(content[2]["arguments"]["command"], "ls");
    }

    #[test]
    fn durable_turn_failure_stays_terminal_across_restart_recovery() {
        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            run_migrations(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let session = store.create_session("m", "/tmp", Some("t"), None).unwrap();
        store
            .append(&AppendOptions {
                session_id: &session.session.id,
                event_type: EventType::TurnFailed,
                payload: json!({
                    "turn": 3,
                    "error": "provider failed",
                    "recoverable": true,
                }),
                sequence: None,
                parent_id: None,
            })
            .unwrap();

        let tmp = TempDir::new().unwrap();
        let journal_path = tmp.path().join("turn_3.wal");
        fs::write(&journal_path, "{\"t\":\"text\",\"c\":\"partial answer\"}\n").unwrap();

        let recovered =
            recover_single_turn_from_path(&store, &session.session.id, 3, &journal_path).unwrap();

        assert!(!recovered);
        assert!(!journal_path.exists());
        let events = store
            .get_events_by_session(&session.session.id, &ListEventsOptions::default())
            .unwrap();
        assert_eq!(
            events
                .iter()
                .filter(|row| row.event_type == EventType::TurnFailed.as_str())
                .count(),
            1
        );
        assert!(events.iter().all(|row| {
            row.event_type != EventType::MessageAssistant.as_str()
                && row.event_type != EventType::StreamTurnEnd.as_str()
        }));
    }
}
