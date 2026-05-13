use super::*;
use crate::domains::session::event_store::sqlite::connection::{self, ConnectionConfig};
use crate::domains::session::event_store::sqlite::migrations::run_migrations;
use crate::domains::session::event_store::sqlite::repositories::event::ListEventsOptions;
use crate::domains::session::event_store::sqlite::repositories::session::ListSessionsOptions;
use serde_json::json;
use std::io::Write;
use tempfile::tempdir;

fn setup() -> EventStore {
    let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
    {
        let conn = pool.get().unwrap();
        run_migrations(&conn).unwrap();
    }
    EventStore::new(pool)
}

fn get_events(
    store: &EventStore,
    session_id: &str,
) -> Vec<crate::domains::session::event_store::sqlite::row_types::EventRow> {
    store
        .get_events_by_session(session_id, &ListEventsOptions::default())
        .unwrap()
}

fn write_sample_session(dir: &Path) -> std::path::PathBuf {
    let file = dir.join("test-session-uuid.jsonl");
    let mut f = std::fs::File::create(&file).unwrap();

    // User message
    writeln!(
        f,
        "{}",
        json!({
            "type": "user",
            "uuid": "u1",
            "timestamp": "2026-01-01T00:00:00Z",
            "promptId": "p1",
            "message": { "role": "user", "content": "Hello, help me with Rust" }
        })
    )
    .unwrap();

    // Assistant message (2 chunks)
    writeln!(f, "{}", json!({
        "type": "assistant",
        "uuid": "a1",
        "parentUuid": "u1",
        "timestamp": "2026-01-01T00:00:01Z",
        "message": {
            "id": "msg_01",
            "role": "assistant",
            "content": [{ "type": "thinking", "thinking": "Let me help with Rust", "signature": "abc" }],
            "model": "claude-opus-4-6"
        }
    })).unwrap();

    writeln!(
        f,
        "{}",
        json!({
            "type": "assistant",
            "uuid": "a2",
            "parentUuid": "a1",
            "timestamp": "2026-01-01T00:00:02Z",
            "message": {
                "id": "msg_01",
                "role": "assistant",
                "content": [
                    { "type": "text", "text": "Here's how to use Rust:" }
                ],
                "stop_reason": "end_turn",
                "usage": { "input_tokens": 500, "output_tokens": 200 }
            }
        })
    )
    .unwrap();

    // Final assistant response
    writeln!(
        f,
        "{}",
        json!({
            "type": "assistant",
            "uuid": "a3",
            "parentUuid": "a2",
            "timestamp": "2026-01-01T00:00:04Z",
            "message": {
                "id": "msg_02",
                "role": "assistant",
                "content": [{ "type": "text", "text": "I've created the file for you." }],
                "stop_reason": "end_turn",
                "usage": { "input_tokens": 600, "output_tokens": 50 },
                "model": "claude-opus-4-6"
            }
        })
    )
    .unwrap();

    // Custom title
    writeln!(
        f,
        "{}",
        json!({
            "type": "custom-title",
            "uuid": "ct1",
            "customTitle": "Rust Help Session",
            "sessionId": "s1"
        })
    )
    .unwrap();

    file
}

#[test]
fn import_creates_session_with_correct_metadata() {
    let store = setup();
    let dir = tempdir().unwrap();
    let path = write_sample_session(dir.path());

    let result = import_session(&store, &path, "/tmp/project", &[], None).unwrap();

    assert!(result.tron_session_id.starts_with("sess_"));
    assert_eq!(result.model, "claude-opus-4-6");
    assert_eq!(result.working_directory, "/tmp/project");

    let sessions = store
        .list_sessions(&ListSessionsOptions::default())
        .unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0].title.as_deref(), Some("Rust Help Session"));
    assert_eq!(sessions[0].source.as_deref(), Some("import"));
}

#[test]
fn import_creates_events_in_order() {
    let store = setup();
    let dir = tempdir().unwrap();
    let path = write_sample_session(dir.path());

    let result = import_session(&store, &path, "/tmp/project", &[], None).unwrap();
    let events = get_events(&store, &result.tron_session_id);

    // Sequences should be monotonically increasing
    for i in 1..events.len() {
        assert!(events[i].sequence > events[i - 1].sequence);
    }
}

#[test]
fn import_session_counters_correct() {
    let store = setup();
    let dir = tempdir().unwrap();
    let path = write_sample_session(dir.path());

    let result = import_session(&store, &path, "/tmp/project", &[], None).unwrap();

    assert_eq!(result.turn_count, 1);
    // 1 user + 2 assistant = 3 messages
    assert_eq!(result.message_count, 3);
    assert!(result.event_count > 0);
}

#[test]
fn import_token_counters_accumulated() {
    let store = setup();
    let dir = tempdir().unwrap();
    let path = write_sample_session(dir.path());

    let _result = import_session(&store, &path, "/tmp/project", &[], None).unwrap();

    let sessions = store
        .list_sessions(&ListSessionsOptions::default())
        .unwrap();
    let session = &sessions[0];
    assert!(session.total_input_tokens > 0);
    assert!(session.total_output_tokens > 0);
}

#[test]
fn import_cost_accumulated() {
    let store = setup();
    let dir = tempdir().unwrap();
    let path = write_sample_session(dir.path());

    let result = import_session(&store, &path, "/tmp/project", &[], None).unwrap();
    assert!(result.total_cost > 0.0);
}

#[test]
fn import_duplicate_blocked() {
    let store = setup();
    let dir = tempdir().unwrap();
    let path = write_sample_session(dir.path());

    let _first = import_session(&store, &path, "/tmp/project", &[], None).unwrap();
    let second = import_session(&store, &path, "/tmp/project", &[], None);

    assert!(matches!(second, Err(ImportError::AlreadyImported { .. })));
}

#[test]
fn import_duplicate_returns_existing_session_id() {
    let store = setup();
    let dir = tempdir().unwrap();
    let path = write_sample_session(dir.path());

    let first = import_session(&store, &path, "/tmp/project", &[], None).unwrap();
    let second = import_session(&store, &path, "/tmp/project", &[], None);

    match second {
        Err(ImportError::AlreadyImported { tron_session_id }) => {
            assert_eq!(tron_session_id, first.tron_session_id);
        }
        _ => panic!("expected AlreadyImported"),
    }
}

#[test]
fn import_empty_session_returns_error() {
    let store = setup();
    let dir = tempdir().unwrap();
    let file = dir.path().join("empty-session.jsonl");
    let mut f = std::fs::File::create(&file).unwrap();
    writeln!(
        f,
        "{}",
        json!({
            "type": "file-history-snapshot",
            "messageId": "m1",
            "snapshot": { "trackedFileBackups": {} },
            "isSnapshotUpdate": false
        })
    )
    .unwrap();

    let result = import_session(&store, &file, "/tmp/project", &[], None);
    assert!(matches!(result, Err(ImportError::EmptySession)));
}

#[test]
fn import_with_extra_tags() {
    let store = setup();
    let dir = tempdir().unwrap();
    let path = write_sample_session(dir.path());

    let result = import_session(
        &store,
        &path,
        "/tmp/project",
        &["my-tag".to_string(), "project:tron".to_string()],
        None,
    )
    .unwrap();

    assert!(result.event_count > 0);

    let events = get_events(&store, &result.tron_session_id);
    let tag_events: Vec<_> = events
        .iter()
        .filter(|e| e.event_type == "metadata.tag")
        .collect();
    // dedup tag + 2 extra tags
    assert_eq!(tag_events.len(), 3);
}

#[test]
fn import_source_is_import() {
    let store = setup();
    let dir = tempdir().unwrap();
    let path = write_sample_session(dir.path());

    let _result = import_session(&store, &path, "/tmp/project", &[], None).unwrap();

    let sessions = store
        .list_sessions(&ListSessionsOptions::default())
        .unwrap();
    assert_eq!(sessions[0].source.as_deref(), Some("import"));
}

#[test]
fn import_head_event_is_last() {
    let store = setup();
    let dir = tempdir().unwrap();
    let path = write_sample_session(dir.path());

    let result = import_session(&store, &path, "/tmp/project", &[], None).unwrap();

    let sessions = store
        .list_sessions(&ListSessionsOptions::default())
        .unwrap();
    let session = &sessions[0];

    let events = get_events(&store, &result.tron_session_id);
    let last_event = events.last().unwrap();
    assert_eq!(
        session.head_event_id.as_deref(),
        Some(last_event.id.as_str())
    );
}

#[test]
fn import_reconstruction_produces_valid_messages() {
    use crate::domains::session::event_store::event_rows_to_session_events;
    use crate::domains::session::event_store::reconstruct::reconstruct_from_events;

    let store = setup();
    let dir = tempdir().unwrap();
    let path = write_sample_session(dir.path());

    let result = import_session(&store, &path, "/tmp/project", &[], None).unwrap();
    let events = get_events(&store, &result.tron_session_id);
    let session_events = event_rows_to_session_events(&events);
    let recon = reconstruct_from_events(&session_events);

    assert!(!recon.messages_with_event_ids.is_empty());

    let roles: Vec<&str> = recon
        .messages_with_event_ids
        .iter()
        .map(|m| m.message.role.as_str())
        .collect();

    assert!(roles.contains(&"user"));
    assert!(roles.contains(&"assistant"));
}

#[test]
fn import_reconstruction_has_no_provider_capability_blocks() {
    use crate::domains::session::event_store::event_rows_to_session_events;
    use crate::domains::session::event_store::reconstruct::reconstruct_from_events;

    let store = setup();
    let dir = tempdir().unwrap();
    let path = write_sample_session(dir.path());

    let result = import_session(&store, &path, "/tmp/project", &[], None).unwrap();
    let events = get_events(&store, &result.tron_session_id);
    let session_events = event_rows_to_session_events(&events);
    let recon = reconstruct_from_events(&session_events);

    let has_provider_capability_blocks = recon.messages_with_event_ids.iter().any(|m| {
        if let Some(arr) = m.message.content.as_array() {
            arr.iter().any(|b| {
                matches!(
                    b.get("type").and_then(serde_json::Value::as_str),
                    Some("capability_invocation" | "capability_result")
                )
            })
        } else {
            false
        }
    });
    assert!(!has_provider_capability_blocks);
}

#[test]
fn import_reconstruction_handles_compact() {
    use crate::domains::session::event_store::event_rows_to_session_events;
    use crate::domains::session::event_store::reconstruct::reconstruct_from_events;

    let store = setup();
    let dir = tempdir().unwrap();
    let file = dir.path().join("compact-session.jsonl");
    let mut f = std::fs::File::create(&file).unwrap();

    writeln!(
        f,
        "{}",
        json!({
            "type": "user",
            "uuid": "u1",
            "timestamp": "2026-01-01T00:00:00Z",
            "promptId": "p1",
            "message": { "role": "user", "content": "First question" }
        })
    )
    .unwrap();

    writeln!(
        f,
        "{}",
        json!({
            "type": "assistant",
            "uuid": "a1",
            "parentUuid": "u1",
            "timestamp": "2026-01-01T00:00:01Z",
            "message": {
                "id": "msg_01",
                "role": "assistant",
                "content": [{ "type": "text", "text": "First answer" }],
                "stop_reason": "end_turn",
                "usage": { "input_tokens": 100, "output_tokens": 50 },
                "model": "claude-opus-4-6"
            }
        })
    )
    .unwrap();

    writeln!(
        f,
        "{}",
        json!({
            "type": "user",
            "uuid": "cs1",
            "parentUuid": "a1",
            "timestamp": "2026-01-01T00:00:02Z",
            "promptId": "p1",
            "isCompactSummary": true,
            "message": { "role": "user", "content": "Summary of prior conversation about Rust" }
        })
    )
    .unwrap();

    writeln!(
        f,
        "{}",
        json!({
            "type": "user",
            "uuid": "u2",
            "parentUuid": "cs1",
            "timestamp": "2026-01-01T00:00:03Z",
            "promptId": "p2",
            "message": { "role": "user", "content": "Follow-up question" }
        })
    )
    .unwrap();

    writeln!(
        f,
        "{}",
        json!({
            "type": "assistant",
            "uuid": "a2",
            "parentUuid": "u2",
            "timestamp": "2026-01-01T00:00:04Z",
            "message": {
                "id": "msg_02",
                "role": "assistant",
                "content": [{ "type": "text", "text": "Follow-up answer" }],
                "stop_reason": "end_turn",
                "usage": { "input_tokens": 200, "output_tokens": 100 },
                "model": "claude-opus-4-6"
            }
        })
    )
    .unwrap();

    let result = import_session(&store, &file, "/tmp/project", &[], None).unwrap();
    let events = get_events(&store, &result.tron_session_id);
    let session_events = event_rows_to_session_events(&events);
    let recon = reconstruct_from_events(&session_events);

    assert!(!recon.messages_with_event_ids.is_empty());
}

#[test]
fn concurrent_imports_of_same_file_produce_single_session() {
    use std::sync::Arc;

    let store = Arc::new(setup());
    let dir = tempdir().unwrap();
    let path = write_sample_session(dir.path());

    let mut handles = vec![];
    for _ in 0..5 {
        let store = Arc::clone(&store);
        let path = path.clone();
        handles.push(std::thread::spawn(move || {
            import_session(&store, &path, "/tmp/project", &[], None)
        }));
    }

    let results: Vec<_> = handles.into_iter().map(|h| h.join().unwrap()).collect();
    let successes: usize = results.iter().filter(|r| r.is_ok()).count();
    let failures: usize = results
        .iter()
        .filter(|r| matches!(r, Err(ImportError::AlreadyImported { .. })))
        .count();

    assert_eq!(successes, 1, "exactly one concurrent import must succeed");
    assert_eq!(failures, 4, "the other four must fail with AlreadyImported");

    let sessions = store
        .list_sessions(&ListSessionsOptions::default())
        .unwrap();
    assert_eq!(
        sessions.len(),
        1,
        "exactly one session must exist in store; got {}: {:?}",
        sessions.len(),
        sessions.iter().map(|s| &s.id).collect::<Vec<_>>()
    );
}

#[test]
fn import_produces_exactly_the_advertised_event_count() {
    // Regression guard for atomicity: event_count reported by import_session
    // must match what actually ended up in the DB. On the non-atomic pipeline
    // a partial failure could report N-1 but leave N rows (or vice versa).
    let store = setup();
    let dir = tempdir().unwrap();
    let path = write_sample_session(dir.path());

    let result = import_session(
        &store,
        &path,
        "/tmp/project",
        &["t1".into(), "t2".into()],
        None,
    )
    .unwrap();
    let events = get_events(&store, &result.tron_session_id);

    // +1 for session.start (created alongside session), which the pipeline also counts.
    assert_eq!(
        events.len() as i64,
        result.event_count + 1,
        "DB event count must equal reported count + session.start"
    );
}

#[test]
fn import_session_refuses_provider_capability_history() {
    let store = setup();
    let dir = tempdir().unwrap();
    let file = dir.path().join("provider-capability-history.jsonl");
    let mut f = std::fs::File::create(&file).unwrap();

    writeln!(
        f,
        "{}",
        json!({
            "type": "user",
            "uuid": "u1",
            "timestamp": "2026-01-01T00:00:00Z",
            "promptId": "p1",
            "message": { "role": "user", "content": "Q" }
        })
    )
    .unwrap();

    writeln!(f, "{}", json!({
        "type": "assistant",
        "uuid": "a1",
        "parentUuid": "u1",
        "timestamp": "2026-01-01T00:00:01Z",
        "message": {
            "id": "msg_01",
            "role": "assistant",
            "content": [
                { "type": "capability_invocation", "id": "provider_cap_1", "name": "filesystem::read_file", "input": { "path": "x.txt" } }
            ],
            "stop_reason": "capability_invocation",
            "usage": { "input_tokens": 10, "output_tokens": 5 },
            "model": "claude-opus-4-6"
        }
    })).unwrap();

    assert!(matches!(
        import_session(&store, &file, "/tmp/project", &[], None),
        Err(
            crate::domains::import::ImportError::UnsupportedProviderCapabilityHistory {
                block_count: 1
            }
        )
    ));
}

#[test]
fn import_session_clean_source_has_no_warnings() {
    // Regression guard: clean fixtures must not produce warnings —
    // otherwise validator noise will train users to ignore the signal.
    let store = setup();
    let dir = tempdir().unwrap();
    let path = write_sample_session(dir.path());

    let result = import_session(&store, &path, "/tmp/project", &[], None).unwrap();
    assert!(
        result.warnings.is_empty(),
        "clean import produced warnings: {:?}",
        result.warnings
    );
}

#[test]
fn import_multiturn_session() {
    let store = setup();
    let dir = tempdir().unwrap();
    let file = dir.path().join("multi-turn.jsonl");
    let mut f = std::fs::File::create(&file).unwrap();

    writeln!(
        f,
        "{}",
        json!({
            "type": "user", "uuid": "u1",
            "timestamp": "2026-01-01T00:00:00Z", "promptId": "p1",
            "message": { "role": "user", "content": "Question 1" }
        })
    )
    .unwrap();
    writeln!(
        f,
        "{}",
        json!({
            "type": "assistant", "uuid": "a1", "parentUuid": "u1",
            "timestamp": "2026-01-01T00:00:01Z",
            "message": { "id": "msg_01", "role": "assistant",
                "content": [{ "type": "text", "text": "Answer 1" }],
                "stop_reason": "end_turn",
                "usage": { "input_tokens": 100, "output_tokens": 50 },
                "model": "claude-opus-4-6" }
        })
    )
    .unwrap();

    writeln!(
        f,
        "{}",
        json!({
            "type": "user", "uuid": "u2", "parentUuid": "a1",
            "timestamp": "2026-01-01T00:00:02Z", "promptId": "p2",
            "message": { "role": "user", "content": "Question 2" }
        })
    )
    .unwrap();
    writeln!(
        f,
        "{}",
        json!({
            "type": "assistant", "uuid": "a2", "parentUuid": "u2",
            "timestamp": "2026-01-01T00:00:03Z",
            "message": { "id": "msg_02", "role": "assistant",
                "content": [{ "type": "text", "text": "Answer 2" }],
                "stop_reason": "end_turn",
                "usage": { "input_tokens": 200, "output_tokens": 100 },
                "model": "claude-opus-4-6" }
        })
    )
    .unwrap();

    writeln!(
        f,
        "{}",
        json!({
            "type": "user", "uuid": "u3", "parentUuid": "a2",
            "timestamp": "2026-01-01T00:00:04Z", "promptId": "p3",
            "message": { "role": "user", "content": "Question 3" }
        })
    )
    .unwrap();
    writeln!(
        f,
        "{}",
        json!({
            "type": "assistant", "uuid": "a3", "parentUuid": "u3",
            "timestamp": "2026-01-01T00:00:05Z",
            "message": { "id": "msg_03", "role": "assistant",
                "content": [{ "type": "text", "text": "Answer 3" }],
                "stop_reason": "end_turn",
                "usage": { "input_tokens": 300, "output_tokens": 150 },
                "model": "claude-opus-4-6" }
        })
    )
    .unwrap();

    let result = import_session(&store, &file, "/tmp/project", &[], None).unwrap();

    assert_eq!(result.turn_count, 3);
    assert_eq!(result.message_count, 6);
    assert_eq!(result.model, "claude-opus-4-6");
}
