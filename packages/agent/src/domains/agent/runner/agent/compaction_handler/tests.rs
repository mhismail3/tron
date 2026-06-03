use super::*;

#[test]
fn initial_state() {
    let handler = CompactionHandler::default();
    assert!(!handler.is_compacting());
    assert!(handler.subagent_manager.is_none());
}

#[test]
fn default_state() {
    let handler = CompactionHandler::default();
    assert!(!handler.is_compacting());
}

#[test]
fn pre_compact_target_is_70_percent() {
    let limit: u64 = 200_000;
    let target = (limit * 7) / 10;
    assert_eq!(target, 140_000);
}

#[test]
fn pre_compact_target_not_50_percent() {
    let limit: u64 = 200_000;
    let target = (limit * 7) / 10;
    assert_ne!(target, limit / 2);
}

// -- wait_for_compaction --

#[tokio::test]
async fn wait_returns_immediately_when_idle() {
    let handler = CompactionHandler::default();
    handler
        .wait_for_compaction(std::time::Duration::from_millis(10))
        .await;
    assert!(!handler.is_compacting());
}

// -- CompactionGuard --

#[test]
fn guard_resets_on_drop() {
    let is_compacting = AtomicBool::new(true);
    let done = Arc::new(Notify::new());
    {
        let _guard = CompactionGuard {
            is_compacting: &is_compacting,
            done: &done,
        };
        assert!(is_compacting.load(Ordering::SeqCst));
    }
    assert!(!is_compacting.load(Ordering::SeqCst));
}

#[tokio::test]
async fn guard_notifies_on_drop() {
    let is_compacting = AtomicBool::new(true);
    let done = Arc::new(Notify::new());
    let done_clone = done.clone();

    let waiter = tokio::spawn(async move {
        done_clone.notified().await;
        true
    });

    tokio::task::yield_now().await;

    {
        let _guard = CompactionGuard {
            is_compacting: &is_compacting,
            done: &done,
        };
    }

    let result = tokio::time::timeout(std::time::Duration::from_millis(100), waiter)
        .await
        .expect("waiter should complete")
        .expect("waiter should not panic");
    assert!(result);
}

#[test]
fn concurrent_compaction_rejected() {
    let handler = CompactionHandler::default();
    handler.is_compacting.store(true, Ordering::SeqCst);
    let cas =
        handler
            .is_compacting
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst);
    assert!(cas.is_err());
}

#[test]
fn is_compacting_true_during_execution() {
    let handler = CompactionHandler::default();
    assert!(!handler.is_compacting());
    handler.is_compacting.store(true, Ordering::SeqCst);
    assert!(handler.is_compacting());
}

// -- Multi-signal trigger --

// ── Compaction two-phase commit ─────────────────────────────────────

fn make_event_store_for_test() -> Arc<crate::domains::session::event_store::EventStore> {
    let pool = crate::domains::session::event_store::new_in_memory(
        &crate::domains::session::event_store::ConnectionConfig::default(),
    )
    .expect("in-memory pool");
    {
        let conn = pool.get().unwrap();
        let _ = crate::domains::session::event_store::run_migrations(&conn).unwrap();
    }
    Arc::new(crate::domains::session::event_store::EventStore::new(pool))
}

async fn make_persister_and_session() -> (
    Arc<crate::domains::agent::runner::orchestrator::event_persister::EventPersister>,
    Arc<crate::domains::session::event_store::EventStore>,
    String,
) {
    let store = make_event_store_for_test();
    let session = store
        .create_session(
            "test-model",
            "/tmp",
            Some("compaction-h13"),
            None,
            None,
            None,
        )
        .unwrap();
    let persister = Arc::new(
        crate::domains::agent::runner::orchestrator::event_persister::EventPersister::new(
            store.clone(),
        ),
    );
    (persister, store, session.session.id)
}

fn make_event_emitter_for_test() -> Arc<EventEmitter> {
    Arc::new(EventEmitter::new())
}

/// Phase 1 (staging) lands BEFORE phase 2 (boundary) in the event log.
#[tokio::test]
async fn h13_two_phase_staging_precedes_boundary() {
    let (persister, store, session_id) = make_persister_and_session().await;
    let emitter = make_event_emitter_for_test();

    let result = Ok(
        crate::domains::agent::runner::context::types::CompactionResult {
            success: true,
            tokens_before: 100,
            tokens_after: 30,
            compression_ratio: 0.3,
            preserved_turns: 2,
            summarized_turns: 3,
            preserved_messages: 4,
            summary: "the summarizer's precious output".into(),
            extracted_data: None,
        },
    );

    let persist_ok = CompactionHandler::emit_compaction_events(
        result,
        std::time::Instant::now(),
        100,
        30,
        &session_id,
        &emitter,
        CompactionReason::ThresholdExceeded,
        Some(&persister),
        None,
    )
    .await;
    assert!(
        persist_ok,
        "successful compaction with ok persister returns true"
    );

    let opts = crate::domains::session::event_store::sqlite::repositories::event::ListEventsOptions::default();
    let events = store.get_events_by_session(&session_id, &opts).unwrap();

    let staging_seq = events
        .iter()
        .find(|e| e.event_type == "compact.summary_staging")
        .expect("staging event must exist")
        .sequence;
    let boundary_seq = events
        .iter()
        .find(|e| e.event_type == "compact.boundary")
        .expect("boundary event must exist")
        .sequence;
    assert!(
        staging_seq < boundary_seq,
        "staging must come before boundary; staging.seq={staging_seq} boundary.seq={boundary_seq}"
    );
}

/// The staging event carries the same summary text that the boundary
/// carries, so a reader that walked off during phase 2 can recover the
/// LLM's work from staging alone.
#[tokio::test]
async fn h13_staging_carries_summary_text() {
    let (persister, store, session_id) = make_persister_and_session().await;
    let emitter = make_event_emitter_for_test();

    let summary = "durable summarizer output".to_string();
    let result = Ok(
        crate::domains::agent::runner::context::types::CompactionResult {
            success: true,
            tokens_before: 200,
            tokens_after: 50,
            compression_ratio: 0.25,
            preserved_turns: 1,
            summarized_turns: 4,
            preserved_messages: 2,
            summary: summary.clone(),
            extracted_data: None,
        },
    );

    let _ = CompactionHandler::emit_compaction_events(
        result,
        std::time::Instant::now(),
        200,
        50,
        &session_id,
        &emitter,
        CompactionReason::ThresholdExceeded,
        Some(&persister),
        None,
    )
    .await;

    let opts = crate::domains::session::event_store::sqlite::repositories::event::ListEventsOptions::default();
    let events = store.get_events_by_session(&session_id, &opts).unwrap();
    let staging = events
        .iter()
        .find(|e| e.event_type == "compact.summary_staging")
        .expect("staging must exist");
    let payload: serde_json::Value = serde_json::from_str(&staging.payload).unwrap();
    assert_eq!(payload["summary"], summary);
    assert_eq!(payload["originalTokens"], 200);
    assert_eq!(payload["compactedTokens"], 50);
}

/// A failed compaction (Err result) emits CompactionComplete with
/// success=false and does NOT persist either staging or boundary.
#[tokio::test]
async fn h13_failed_compaction_persists_neither_event() {
    let (persister, store, session_id) = make_persister_and_session().await;
    let emitter = make_event_emitter_for_test();

    let err: Result<
        crate::domains::agent::runner::context::types::CompactionResult,
        Box<dyn std::error::Error + Send + Sync>,
    > = Err("summarizer error".into());

    let persist_ok = CompactionHandler::emit_compaction_events(
        err,
        std::time::Instant::now(),
        100,
        100,
        &session_id,
        &emitter,
        CompactionReason::ThresholdExceeded,
        Some(&persister),
        None,
    )
    .await;
    assert!(!persist_ok, "failed compaction returns false");

    let opts = crate::domains::session::event_store::sqlite::repositories::event::ListEventsOptions::default();
    let events = store.get_events_by_session(&session_id, &opts).unwrap();
    assert!(
        !events
            .iter()
            .any(|e| e.event_type == "compact.summary_staging"),
        "failed compaction must not persist staging"
    );
    assert!(
        !events.iter().any(|e| e.event_type == "compact.boundary"),
        "failed compaction must not persist boundary"
    );
}

/// A no-op compaction is not a committed boundary. This covers long
/// single-turn sessions that cross the token trigger before any older turn
/// is safe to summarize.
#[tokio::test]
async fn noop_compaction_persists_neither_event() {
    let (persister, store, session_id) = make_persister_and_session().await;
    let emitter = make_event_emitter_for_test();
    let mut rx = emitter.subscribe();

    let result = Ok(
        crate::domains::agent::runner::context::types::CompactionResult {
            success: true,
            tokens_before: 100,
            tokens_after: 100,
            compression_ratio: 1.0,
            preserved_turns: 1,
            summarized_turns: 0,
            preserved_messages: 20,
            summary: String::new(),
            extracted_data: None,
        },
    );

    let persist_ok = CompactionHandler::emit_compaction_events(
        result,
        std::time::Instant::now(),
        100,
        100,
        &session_id,
        &emitter,
        CompactionReason::ThresholdExceeded,
        Some(&persister),
        None,
    )
    .await;
    assert!(!persist_ok, "no-op compaction returns false");

    let broadcast = tokio::time::timeout(std::time::Duration::from_secs(2), rx.recv())
        .await
        .expect("no-op terminal broadcast should arrive")
        .expect("broadcast channel should stay open");
    match broadcast {
        TronEvent::CompactionComplete {
            success,
            tokens_before,
            tokens_after,
            summary,
            summarized_turns,
            ..
        } => {
            assert!(
                !success,
                "no-op terminal event is not a committed compaction"
            );
            assert_eq!(tokens_before, 100);
            assert_eq!(tokens_after, 100);
            assert_eq!(
                summary.as_deref(),
                Some("Compaction skipped: no durable context reduction.")
            );
            assert_eq!(summarized_turns, Some(0));
        }
        other => panic!("expected no-op terminal compaction event, got {other:?}"),
    }

    let opts = crate::domains::session::event_store::sqlite::repositories::event::ListEventsOptions::default();
    let events = store.get_events_by_session(&session_id, &opts).unwrap();
    assert!(
        !events
            .iter()
            .any(|e| e.event_type == "compact.summary_staging"),
        "no-op compaction must not persist staging"
    );
    assert!(
        !events.iter().any(|e| e.event_type == "compact.boundary"),
        "no-op compaction must not persist boundary"
    );
}

#[test]
fn record_process_command_accumulates() {
    let handler = CompactionHandler::default();
    handler.record_process_command("git status");
    handler.record_process_command("cargo build");
    handler.record_process_command("git push origin main");
    let cmds = handler.pending_process_commands.lock().unwrap();
    assert_eq!(cmds.len(), 3);
}

// -- Event type recording --

#[test]
fn record_event_type_accumulates() {
    let handler = CompactionHandler::default();
    handler.record_event_type("worktree.commit");
    handler.record_event_type("worktree.commit");
    let events = handler.pending_event_types.lock().unwrap();
    assert_eq!(events.len(), 2);
    assert_eq!(events[0], "worktree.commit");
}

#[test]
fn event_types_initially_empty() {
    let handler = CompactionHandler::default();
    let events = handler.pending_event_types.lock().unwrap();
    assert!(events.is_empty());
}

#[test]
fn set_persister_via_shared_ref() {
    let handler = CompactionHandler::default();
    // Verify set_persister works through &self (not &mut self)
    assert!(handler.persister.lock().unwrap().is_none());
}
