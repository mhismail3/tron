//! Crash recovery — recovers partial LLM output from orphaned streaming journals.
//!
//! On server startup (before accepting client connections), `recover_incomplete_turns`
//! scans both orphaned journal files and durable turn starts that have no later
//! terminal row. Prompt admission also repairs terminal prior turns whose
//! tool starts still lack completions; if that atomic repair cannot
//! commit, the new prompt is rejected before its user event or provider exists.
//! The database sweep covers crashes and terminal-write failures that happen
//! before a streaming journal exists. For each orphaned journal:
//!
//! 1. Scope durable assistant/end/failure rows to the latest start for that
//!    ordinal. A journal without its required durable start fails closed for
//!    manual inspection.
//! 2. Repair any started tool invocation without a completion so clients
//!    cannot reconstruct a permanently running invocation.
//! 3. If an assistant is already durable, append only the missing recovered
//!    lifecycle end; otherwise recover the partial assistant when present.
//!    Recovery-owned assistant, tool, and turn-end rows commit atomically.
//! 4. If the session was deleted, remove its orphaned journal.
//!
//! Recovery events use `sequence: None`; the event store assigns the next
//! sequence because the runtime counter is not initialized during startup recovery.
//!
//! ## Double-recovery safety
//!
//! Recovery rows commit before the journal is deleted. A crash between commit
//! and cleanup is idempotent: the next startup recognizes the durable terminal,
//! repairs only a still-missing tool completion, and removes the journal
//! without replaying the assistant.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::fs;
use std::sync::Arc;

use serde_json::json;
use tracing::{debug, info, warn};

use crate::domains::agent::r#loop::orchestrator::streaming_journal::StreamingJournal;
use crate::domains::agent::r#loop::pipeline::persistence;
use crate::domains::session::event_store::{
    AppendBatchItem, EventRow, EventStore, EventType, ListEventsOptions,
};

#[derive(Clone, Copy)]
enum ToolRecoveryCause {
    ServerRestart,
    PromptAdmission,
}

impl ToolRecoveryCause {
    fn content(self) -> &'static str {
        match self {
            Self::ServerRestart => "Tool invocation was interrupted by a server restart.",
            Self::PromptAdmission => {
                "Tool completion could not be persisted. The operation may have executed; inspect its effects before retrying."
            }
        }
    }

    fn skip_reason(self) -> &'static str {
        match self {
            Self::ServerRestart => "server_restart",
            Self::PromptAdmission => "completion_persistence_failed",
        }
    }

    fn code(self) -> &'static str {
        match self {
            Self::ServerRestart => "TOOL_INVOCATION_CRASH_RECOVERED",
            Self::PromptAdmission => "TOOL_COMPLETION_PERSISTENCE_RECOVERED",
        }
    }

    fn details(self) -> serde_json::Value {
        match self {
            Self::ServerRestart => json!({
                "status": "interrupted",
                "executed": false,
                "skipReason": self.skip_reason(),
                "code": self.code(),
                "providerContextResultWritten": false,
                "recovered": true,
            }),
            Self::PromptAdmission => json!({
                "status": "persistence_failed",
                "executionState": "unknown",
                "mayHaveExecuted": true,
                "retrySafe": false,
                "recoveryReason": "prompt_admission_repair",
                "failureReason": self.skip_reason(),
                "code": self.code(),
                "providerContextResultWritten": false,
                "recovered": true,
            }),
        }
    }
}

/// Recover incomplete turns from orphaned streaming journals.
///
/// Returns the list of session IDs that had content recovered.
/// Called from server startup before accepting client connections.
pub fn recover_incomplete_turns(event_store: &Arc<EventStore>) -> Vec<String> {
    let incomplete = match StreamingJournal::scan_incomplete() {
        Ok(list) => list,
        Err(e) => {
            warn!(error = %e, "failed to scan for incomplete journals; continuing with durable turn sweep");
            Vec::new()
        }
    };

    if !incomplete.is_empty() {
        info!(
            count = incomplete.len(),
            "found orphaned journals, starting crash recovery"
        );
    }

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

    match recover_unterminalized_starts(event_store) {
        Ok(session_ids) => recovered_sessions.extend(session_ids),
        Err(error) => {
            warn!(error = %error, "failed to sweep durable unterminated turn starts");
        }
    }

    recovered_sessions.sort();
    recovered_sessions.dedup();

    if !recovered_sessions.is_empty() {
        info!(
            count = recovered_sessions.len(),
            sessions = ?recovered_sessions,
            "crash recovery completed"
        );
    }

    recovered_sessions
}

/// Repair terminal prior turns for one serialized session before a new prompt.
///
/// All missing tool completions across the session commit in one batch.
/// Returning an error is an admission veto: callers must not append the new
/// user message or construct a provider. The returned row/payload pairs are
/// the exact durable completions that a live client must receive.
pub(crate) fn recover_incomplete_turns_for_session(
    event_store: &Arc<EventStore>,
    session_id: &str,
) -> Result<Vec<(EventRow, serde_json::Value)>, String> {
    let rows = event_store
        .get_events_by_session(session_id, &ListEventsOptions::default())
        .map_err(|error| error.to_string())?;
    let mut completed_high_water = HashMap::new();
    for row in rows
        .iter()
        .filter(|row| row.event_type == EventType::ToolInvocationCompleted.as_str())
    {
        if let Some(invocation_id) = row.invocation_id.as_deref() {
            completed_high_water
                .entry(invocation_id)
                .and_modify(|sequence: &mut i64| *sequence = (*sequence).max(row.sequence))
                .or_insert(row.sequence);
        }
    }
    let mut candidate_turns = BTreeSet::new();
    for row in rows
        .iter()
        .filter(|row| row.event_type == EventType::ToolInvocationStarted.as_str())
    {
        let invocation_id = row
            .invocation_id
            .as_deref()
            .filter(|id| !id.trim().is_empty())
            .ok_or_else(|| format!("tool start {} has no invocation id", row.id))?;
        if completed_high_water
            .get(invocation_id)
            .is_some_and(|sequence| *sequence > row.sequence)
        {
            continue;
        }
        let turn = row
            .turn
            .ok_or_else(|| format!("tool start {} has no durable turn ordinal", row.id))?;
        candidate_turns.insert(
            u32::try_from(turn)
                .map_err(|_| format!("session {session_id} has invalid prior turn {turn}"))?,
        );
    }

    let mut items = Vec::new();
    let mut payloads = Vec::new();
    let mut repaired_turns = BTreeSet::new();
    for turn in candidate_turns {
        let state =
            durable_turn_state(event_store, session_id, turn).map_err(|error| error.to_string())?;
        let incomplete =
            incomplete_tool_starts(event_store, session_id, turn, state.latest_start_sequence)
                .map_err(|error| error.to_string())?;
        if incomplete.is_empty() {
            continue;
        }
        if !state.has_terminal {
            return Err(format!(
                "prior turn {turn} in session {session_id} is not durably terminal"
            ));
        }
        for start in &incomplete {
            let item = tool_recovery_item(start, ToolRecoveryCause::PromptAdmission)
                .map_err(|error| error.to_string())?;
            payloads.push(item.payload.clone());
            items.push(item);
        }
        repaired_turns.insert(turn);
    }

    if items.is_empty() {
        return Ok(Vec::new());
    }
    let persisted = event_store
        .append_batch(session_id, &items)
        .map_err(|error| error.to_string())?;

    for turn in repaired_turns {
        let journal_path = StreamingJournal::journal_path(session_id, turn);
        if journal_path.exists() {
            if let Err(error) = fs::remove_file(&journal_path) {
                warn!(
                    session_id,
                    turn,
                    error = %error,
                    "failed to remove repaired prompt-admission journal"
                );
            } else {
                cleanup_empty_session_dir(&journal_path);
            }
        }
    }

    Ok(persisted.into_iter().zip(payloads).collect())
}

/// Close durable turn starts that have no later terminal row, including turns
/// interrupted before their stream journal was created. This runs only during
/// startup, before the server accepts prompts, so the query cannot race a live
/// turn.
fn recover_unterminalized_starts(
    event_store: &Arc<EventStore>,
) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let starts = event_store.get_unterminalized_turn_starts()?;
    let mut recovered_sessions = Vec::new();
    for start in starts {
        let turn_value = start
            .turn
            .ok_or_else(|| format!("turn start {} has no denormalized ordinal", start.id))?;
        let turn = u32::try_from(turn_value)
            .map_err(|_| format!("turn start {} has invalid ordinal {turn_value}", start.id))?;
        let state = durable_turn_state(event_store, &start.session_id, turn)?;
        if state.has_terminal {
            continue;
        }
        let incomplete_tools = incomplete_tool_starts(
            event_store,
            &start.session_id,
            turn,
            state.latest_start_sequence,
        )?;
        persist_recovery_batch(
            event_store,
            &start.session_id,
            turn,
            None,
            &incomplete_tools,
            true,
        )?;
        info!(
            session_id = %start.session_id,
            turn,
            "closed durable unterminated turn during startup recovery"
        );
        recovered_sessions.push(start.session_id);
    }
    Ok(recovered_sessions)
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

    let durable_state = durable_turn_state(event_store, session_id, turn)?;
    let incomplete_tools = incomplete_tool_starts(
        event_store,
        session_id,
        turn,
        durable_state.latest_start_sequence,
    )?;

    if durable_state.has_terminal {
        persist_recovery_batch(
            event_store,
            session_id,
            turn,
            None,
            &incomplete_tools,
            false,
        )?;
        info!(
            session_id,
            turn, "removed stale streaming journal for durably terminal turn"
        );
        fs::remove_file(journal_path)?;
        cleanup_empty_session_dir(journal_path);
        return Ok(false);
    }

    if durable_state.has_assistant {
        persist_recovery_batch(event_store, session_id, turn, None, &incomplete_tools, true)?;
        info!(
            session_id,
            turn, "closed turn whose assistant was durable before server interruption"
        );
        fs::remove_file(journal_path)?;
        cleanup_empty_session_dir(journal_path);
        return Ok(false);
    }

    // Load recovery data
    let recovered = StreamingJournal::load_recovery_from_path(journal_path, session_id, turn)?;

    // Build canonical assistant content blocks for the partial message. The
    // journal preserves stream order, including tool positions from the
    // first draft marker rather than recovery-time bucket order.
    let assistant_payload = recovered.as_ref().and_then(|recovered| {
        let content = persistence::build_content_json(&recovered.content);
        (!content.is_empty()).then(|| {
            json!({
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
            })
        })
    });
    persist_recovery_batch(
        event_store,
        session_id,
        turn,
        assistant_payload,
        &incomplete_tools,
        true,
    )?;

    if let Some(recovered) = recovered.as_ref() {
        info!(
            session_id,
            turn,
            text_len = recovered.accumulated_text.len(),
            thinking_len = recovered.accumulated_thinking.len(),
            tool_invocations = recovered.tool_invocations.len(),
            "recovered interrupted turn from streaming journal"
        );
    } else {
        debug!(
            session_id,
            turn, "closed empty or corrupted journal as an interrupted turn"
        );
    }

    // Delete the journal now that content is persisted
    fs::remove_file(&journal_path)?;
    cleanup_empty_session_dir(&journal_path);

    Ok(recovered.is_some())
}

#[derive(Default)]
struct DurableTurnState {
    latest_start_sequence: i64,
    has_assistant: bool,
    has_terminal: bool,
}

fn durable_turn_state(
    event_store: &EventStore,
    session_id: &str,
    turn: u32,
) -> Result<DurableTurnState, Box<dyn std::error::Error>> {
    let latest_start = event_store.get_latest_event_by_type_and_turn(
        session_id,
        EventType::StreamTurnStart,
        turn,
    )?;
    let latest_failure =
        event_store.get_latest_event_by_type_and_turn(session_id, EventType::TurnFailed, turn)?;
    let latest_assistant = event_store.get_latest_event_by_type_and_turn(
        session_id,
        EventType::MessageAssistant,
        turn,
    )?;
    let latest_end = event_store.get_latest_event_by_type_and_turn(
        session_id,
        EventType::StreamTurnEnd,
        turn,
    )?;
    let latest_start_sequence = latest_start
        .as_ref()
        .map(|row| row.sequence)
        .ok_or_else(|| {
            std::io::Error::other(format!(
                "turn {turn} has a streaming journal without its durable start"
            ))
        })?;
    let belongs_to_latest_attempt = |row: &EventRow| row.sequence > latest_start_sequence;
    let has_assistant = latest_assistant
        .as_ref()
        .is_some_and(belongs_to_latest_attempt);
    let has_terminal = [latest_failure, latest_end]
        .into_iter()
        .flatten()
        .any(|row| belongs_to_latest_attempt(&row));
    Ok(DurableTurnState {
        latest_start_sequence,
        has_assistant,
        has_terminal,
    })
}

fn incomplete_tool_starts(
    event_store: &EventStore,
    session_id: &str,
    turn: u32,
    latest_start_sequence: i64,
) -> Result<Vec<EventRow>, Box<dyn std::error::Error>> {
    let rows = event_store.get_events_since(session_id, latest_start_sequence)?;
    let completed = rows
        .iter()
        .filter(|row| row.event_type == EventType::ToolInvocationCompleted.as_str())
        .filter_map(|row| row.invocation_id.as_deref())
        .collect::<HashSet<_>>();
    Ok(rows
        .iter()
        .filter(|row| {
            row.event_type == EventType::ToolInvocationStarted.as_str()
                && row.turn == Some(i64::from(turn))
                && row
                    .invocation_id
                    .as_deref()
                    .is_some_and(|id| !completed.contains(id))
        })
        .cloned()
        .collect())
}

fn persist_recovery_batch(
    event_store: &EventStore,
    session_id: &str,
    turn: u32,
    assistant_payload: Option<serde_json::Value>,
    incomplete_tools: &[EventRow],
    append_turn_end: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut items = Vec::with_capacity(
        usize::from(assistant_payload.is_some())
            + incomplete_tools.len()
            + usize::from(append_turn_end),
    );
    if let Some(payload) = assistant_payload {
        items.push(AppendBatchItem {
            event_type: EventType::MessageAssistant,
            payload,
            sequence: None,
        });
    }
    for start in incomplete_tools {
        items.push(tool_recovery_item(start, ToolRecoveryCause::ServerRestart)?);
    }
    if append_turn_end {
        items.push(AppendBatchItem {
            event_type: EventType::StreamTurnEnd,
            payload: json!({
                "turn": turn,
                "stopReason": "crash_recovered",
                "tokenUsage": {
                    "inputTokens": 0,
                    "outputTokens": 0,
                },
                "interrupted": true,
                "recovered": true,
            }),
            sequence: None,
        });
    }
    let _ = event_store.append_batch(session_id, &items)?;
    Ok(())
}

fn tool_recovery_item(
    start: &EventRow,
    cause: ToolRecoveryCause,
) -> Result<AppendBatchItem, Box<dyn std::error::Error>> {
    let invocation_id = start
        .invocation_id
        .as_deref()
        .ok_or_else(|| format!("tool start {} has no invocation id", start.id))?;
    let tool_name = start
        .tool_name
        .as_deref()
        .ok_or_else(|| format!("tool start {} has no tool name", start.id))?;
    Ok(AppendBatchItem {
        event_type: EventType::ToolInvocationCompleted,
        payload: json!({
            "invocationId": invocation_id,
            "toolName": tool_name,
            "content": cause.content(),
            "isError": true,
            "duration": 0,
            "details": cause.details(),
        }),
        sequence: None,
    })
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
    use crate::domains::session::event_store::sqlite::connection::{self, ConnectionConfig};
    use crate::domains::session::event_store::sqlite::schema::ensure_schema;
    use crate::domains::session::event_store::{AppendOptions, ListEventsOptions};
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
            crate::shared::protocol::content::AssistantContent::ToolInvocation {
                id: "tc_1".to_owned(),
                name: "test_tool".to_owned(),
                arguments: args,
                thought_signature: None,
            },
        ]);

        assert_eq!(content.len(), 3);
        assert_eq!(content[0]["type"], "text");
        assert_eq!(content[0]["text"], "Hello world");
        assert_eq!(content[1]["type"], "thinking");
        assert_eq!(content[2]["type"], "tool_invocation");
        assert!(content[2].get("tool_invocation").is_none());
        assert_eq!(content[2]["id"], "tc_1");
        assert_eq!(content[2]["arguments"]["command"], "ls");
    }

    #[test]
    fn startup_sweep_closes_durable_start_without_a_journal() {
        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            ensure_schema(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let session = store
            .create_session("m", "/tmp", Some("orphan start"), None)
            .unwrap();
        store
            .append(&AppendOptions {
                session_id: &session.session.id,
                event_type: EventType::StreamTurnStart,
                payload: json!({"turn": 11}),
                sequence: None,
                parent_id: None,
            })
            .unwrap();

        let recovered = recover_unterminalized_starts(&store).unwrap();
        assert_eq!(recovered, vec![session.session.id.clone()]);
        assert!(store.get_unterminalized_turn_starts().unwrap().is_empty());

        let rows = store
            .get_events_by_session(&session.session.id, &ListEventsOptions::default())
            .unwrap();
        let end = rows
            .iter()
            .find(|row| row.event_type == EventType::StreamTurnEnd.as_str())
            .expect("startup sweep terminal row");
        assert_eq!(end.turn, Some(11));
        let payload: serde_json::Value = serde_json::from_str(&end.payload).unwrap();
        assert_eq!(payload["stopReason"], "crash_recovered");
        assert_eq!(payload["interrupted"], true);
    }

    #[test]
    fn durable_turn_failure_stays_terminal_across_restart_recovery() {
        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            ensure_schema(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let session = store.create_session("m", "/tmp", Some("t"), None).unwrap();
        store
            .append(&AppendOptions {
                session_id: &session.session.id,
                event_type: EventType::StreamTurnStart,
                payload: json!({"turn": 3}),
                sequence: None,
                parent_id: None,
            })
            .unwrap();
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

    #[test]
    fn durable_assistant_prevents_duplicate_journal_replay() {
        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            ensure_schema(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let session = store.create_session("m", "/tmp", Some("t"), None).unwrap();
        for (event_type, payload) in [
            (EventType::StreamTurnStart, json!({"turn": 7})),
            (
                EventType::MessageAssistant,
                json!({
                    "turn": 7,
                    "content": [{"type": "text", "text": "complete"}],
                    "model": "m",
                    "stopReason": "end_turn"
                }),
            ),
        ] {
            store
                .append(&AppendOptions {
                    session_id: &session.session.id,
                    event_type,
                    payload,
                    sequence: None,
                    parent_id: None,
                })
                .unwrap();
        }
        let tmp = TempDir::new().unwrap();
        let journal_path = tmp.path().join("turn_7.wal");
        fs::write(&journal_path, "{\"t\":\"text\",\"c\":\"complete\"}\n").unwrap();

        let recovered =
            recover_single_turn_from_path(&store, &session.session.id, 7, &journal_path).unwrap();

        assert!(!recovered);
        assert!(!journal_path.exists());
        let assistant_count = store
            .get_events_by_session(&session.session.id, &ListEventsOptions::default())
            .unwrap()
            .into_iter()
            .filter(|row| row.event_type == EventType::MessageAssistant.as_str())
            .count();
        assert_eq!(assistant_count, 1);
        assert_eq!(
            store
                .get_events_by_session(&session.session.id, &ListEventsOptions::default())
                .unwrap()
                .iter()
                .filter(|row| row.event_type == EventType::StreamTurnEnd.as_str())
                .count(),
            1,
            "durable assistant without an end must be closed, not replayed"
        );
        assert_eq!(
            store
                .get_session(&session.session.id)
                .unwrap()
                .unwrap()
                .turn_count,
            1
        );
    }

    #[test]
    fn recovery_closes_incomplete_tool_and_turn() {
        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            ensure_schema(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let session = store.create_session("m", "/tmp", Some("t"), None).unwrap();
        for (event_type, payload) in [
            (EventType::StreamTurnStart, json!({"turn": 4})),
            (
                EventType::MessageAssistant,
                json!({
                    "turn": 4,
                    "content": [{
                        "type": "tool_invocation",
                        "id": "call-crashed",
                        "name": "test_tool",
                        "arguments": {"operation": "observe"}
                    }],
                    "model": "m",
                    "stopReason": "tool_invocation"
                }),
            ),
            (
                EventType::ToolInvocationStarted,
                json!({
                    "turn": 4,
                    "invocationId": "call-crashed",
                    "toolName": "test_tool",
                    "arguments": {"operation": "observe"}
                }),
            ),
        ] {
            store
                .append(&AppendOptions {
                    session_id: &session.session.id,
                    event_type,
                    payload,
                    sequence: None,
                    parent_id: None,
                })
                .unwrap();
        }
        let tmp = TempDir::new().unwrap();
        let journal_path = tmp.path().join("turn_4.wal");
        fs::write(
            &journal_path,
            "{\"t\":\"text\",\"c\":\"ignored duplicate\"}\n",
        )
        .unwrap();

        let recovered =
            recover_single_turn_from_path(&store, &session.session.id, 4, &journal_path).unwrap();

        assert!(!recovered);
        assert!(!journal_path.exists());
        let events = store
            .get_events_by_session(&session.session.id, &ListEventsOptions::default())
            .unwrap();
        let completions = events
            .iter()
            .filter(|row| row.event_type == EventType::ToolInvocationCompleted.as_str())
            .collect::<Vec<_>>();
        assert_eq!(completions.len(), 1);
        assert_eq!(
            completions[0].invocation_id.as_deref(),
            Some("call-crashed")
        );
        let completion_payload: serde_json::Value =
            serde_json::from_str(&completions[0].payload).unwrap();
        assert_eq!(completion_payload["isError"], true);
        assert_eq!(completion_payload["details"]["recovered"], true);
        assert_eq!(
            events
                .iter()
                .filter(|row| row.event_type == EventType::StreamTurnEnd.as_str())
                .count(),
            1
        );
        assert_eq!(
            events
                .iter()
                .filter(|row| row.event_type == EventType::MessageAssistant.as_str())
                .count(),
            1
        );
    }

    #[test]
    fn prompt_admission_retries_atomic_terminal_tool_repair() {
        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            ensure_schema(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool.clone()));
        let session = store.create_session("m", "/tmp", Some("t"), None).unwrap();
        for (event_type, payload) in [
            (EventType::StreamTurnStart, json!({"turn": 6})),
            (
                EventType::ToolInvocationStarted,
                json!({
                    "turn": 6,
                    "invocationId": "call-a",
                    "toolName": "test_tool",
                    "arguments": {"operation": "observe"}
                }),
            ),
            (
                EventType::ToolInvocationStarted,
                json!({
                    "turn": 6,
                    "invocationId": "call-b",
                    "toolName": "test_tool",
                    "arguments": {"operation": "observe"}
                }),
            ),
            (
                EventType::TurnFailed,
                json!({"turn": 6, "error": "completion persistence failed"}),
            ),
        ] {
            store
                .append(&AppendOptions {
                    session_id: &session.session.id,
                    event_type,
                    payload,
                    sequence: None,
                    parent_id: None,
                })
                .unwrap();
        }
        {
            let conn = pool.get().unwrap();
            conn.execute_batch(
                "CREATE TRIGGER fail_prompt_repair
                 BEFORE INSERT ON events
                 WHEN NEW.type = 'tool.invocation.completed'
                  AND NEW.invocation_id = 'call-b'
                 BEGIN
                   SELECT RAISE(FAIL, 'forced prompt repair failure');
                 END;",
            )
            .unwrap();
        }

        let error = recover_incomplete_turns_for_session(&store, &session.session.id)
            .expect_err("completion rejection must veto prompt admission");
        assert!(error.contains("forced prompt repair failure"));
        assert!(
            store
                .get_events_by_session(&session.session.id, &ListEventsOptions::default(),)
                .unwrap()
                .iter()
                .all(|row| { row.event_type != EventType::ToolInvocationCompleted.as_str() }),
            "the first repair row must roll back with the rejected second row"
        );

        {
            let conn = pool.get().unwrap();
            conn.execute_batch("DROP TRIGGER fail_prompt_repair;")
                .unwrap();
        }
        let repaired = recover_incomplete_turns_for_session(&store, &session.session.id)
            .expect("retry repairs prior lifecycle");
        assert_eq!(repaired.len(), 2);
        assert_eq!(
            repaired
                .iter()
                .map(|(_, payload)| payload["invocationId"].as_str().unwrap())
                .collect::<Vec<_>>(),
            vec!["call-a", "call-b"]
        );
        assert!(repaired.iter().all(|(_, payload)| {
            payload["details"]["status"] == json!("persistence_failed")
                && payload["details"]["executionState"] == json!("unknown")
                && payload["details"]["mayHaveExecuted"] == json!(true)
                && payload["details"]["retrySafe"] == json!(false)
                && payload["details"]["recoveryReason"] == json!("prompt_admission_repair")
                && payload["details"]["code"] == json!("TOOL_COMPLETION_PERSISTENCE_RECOVERED")
                && !payload["content"]
                    .as_str()
                    .unwrap()
                    .contains("server restart")
        }));
        assert!(
            recover_incomplete_turns_for_session(&store, &session.session.id)
                .expect("repair is idempotent")
                .is_empty()
        );
    }

    #[test]
    fn prompt_admission_rejects_unidentifiable_tool_start() {
        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            ensure_schema(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let session = store.create_session("m", "/tmp", Some("t"), None).unwrap();
        for (event_type, payload) in [
            (EventType::StreamTurnStart, json!({"turn": 2})),
            (
                EventType::ToolInvocationStarted,
                json!({"turn": 2, "toolName": "test_tool", "arguments": {}}),
            ),
            (EventType::TurnFailed, json!({"turn": 2, "error": "failed"})),
        ] {
            store
                .append(&AppendOptions {
                    session_id: &session.session.id,
                    event_type,
                    payload,
                    sequence: None,
                    parent_id: None,
                })
                .unwrap();
        }

        let error = recover_incomplete_turns_for_session(&store, &session.session.id)
            .expect_err("an uncloseable start must veto prompt admission");
        assert!(error.contains("has no invocation id"));
    }

    #[test]
    fn empty_journal_still_closes_durable_turn_start() {
        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            ensure_schema(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let session = store.create_session("m", "/tmp", Some("t"), None).unwrap();
        store
            .append(&AppendOptions {
                session_id: &session.session.id,
                event_type: EventType::StreamTurnStart,
                payload: json!({"turn": 5}),
                sequence: None,
                parent_id: None,
            })
            .unwrap();
        let tmp = TempDir::new().unwrap();
        let journal_path = tmp.path().join("turn_5.wal");
        fs::write(&journal_path, "").unwrap();

        let recovered =
            recover_single_turn_from_path(&store, &session.session.id, 5, &journal_path).unwrap();

        assert!(!recovered);
        assert!(!journal_path.exists());
        let events = store
            .get_events_by_session(&session.session.id, &ListEventsOptions::default())
            .unwrap();
        assert!(events.iter().any(|row| {
            row.event_type == EventType::StreamTurnEnd.as_str() && row.turn == Some(5)
        }));
    }

    #[test]
    fn newer_reused_turn_start_keeps_journal_recoverable() {
        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            ensure_schema(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let session = store.create_session("m", "/tmp", Some("t"), None).unwrap();
        for event_type in [
            EventType::StreamTurnStart,
            EventType::TurnFailed,
            EventType::StreamTurnStart,
        ] {
            store
                .append(&AppendOptions {
                    session_id: &session.session.id,
                    event_type,
                    payload: json!({"turn": 20, "error": "old cancellation"}),
                    sequence: None,
                    parent_id: None,
                })
                .unwrap();
        }

        let tmp = TempDir::new().unwrap();
        let journal_path = tmp.path().join("turn_20.wal");
        fs::write(&journal_path, "{\"t\":\"text\",\"c\":\"new attempt\"}\n").unwrap();

        let recovered =
            recover_single_turn_from_path(&store, &session.session.id, 20, &journal_path).unwrap();

        assert!(recovered);
        assert!(!journal_path.exists());
        let events = store
            .get_events_by_session(&session.session.id, &ListEventsOptions::default())
            .unwrap();
        let recovered_message = events
            .iter()
            .find(|row| row.event_type == EventType::MessageAssistant.as_str())
            .expect("newer reused turn must recover its partial assistant message");
        let payload: serde_json::Value = serde_json::from_str(&recovered_message.payload).unwrap();
        assert_eq!(payload["turn"], 20);
        assert_eq!(payload["recovered"], true);
        assert!(events.iter().any(|row| {
            row.event_type == EventType::StreamTurnEnd.as_str() && row.turn == Some(20)
        }));
    }
}
