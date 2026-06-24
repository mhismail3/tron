use super::*;
use crate::domains::session::event_store::EventStore;
use serde_json::json;

fn make_orchestrator() -> Orchestrator {
    let pool = crate::domains::session::event_store::new_in_memory(
        &crate::domains::session::event_store::ConnectionConfig::default(),
    )
    .unwrap();
    {
        let conn = pool.get().unwrap();
        let _ = crate::domains::session::event_store::run_migrations(&conn).unwrap();
    }
    let store = Arc::new(EventStore::new(pool));
    let mgr = Arc::new(SessionManager::new(store));
    Orchestrator::new(mgr)
}

#[test]
fn create_orchestrator() {
    let orch = make_orchestrator();
    assert_eq!(orch.max_concurrent_sessions(), MAX_CONCURRENT_SESSIONS);
    assert_eq!(orch.active_session_count(), 0);
    assert!(orch.can_accept_session());
}

#[tokio::test]
async fn create_session_through_orchestrator() {
    let orch = make_orchestrator();
    let sid = orch
        .session_manager()
        .create_session("model", "/tmp", Some("test"))
        .unwrap();

    assert_eq!(orch.active_session_count(), 1);
    assert!(orch.is_session_busy(&sid));
}

#[tokio::test]
async fn subscribe_to_events() {
    let orch = make_orchestrator();
    let mut rx = orch.subscribe();

    let _ = orch
        .broadcast()
        .emit(crate::shared::protocol::events::agent_start_event("s1"));

    let event = rx.try_recv().unwrap();
    assert_eq!(event.event_type(), "agent_start");
}

#[tokio::test]
async fn max_concurrent_enforced() {
    let orch = make_orchestrator();

    for i in 0..MAX_CONCURRENT_SESSIONS {
        let _ = orch
            .session_manager()
            .create_session("model", &format!("/tmp/{i}"), None)
            .unwrap();
    }

    assert_eq!(orch.active_session_count(), MAX_CONCURRENT_SESSIONS);
    assert!(!orch.can_accept_session());
}

// --- Run tracking tests ---

#[test]
fn begin_run_creates_token() {
    let orch = make_orchestrator();
    let run = orch.begin_run("s1", "run_1").unwrap();
    let token = run.cancel_token();
    assert!(!token.is_cancelled());
    assert!(orch.has_active_run("s1"));
    assert_eq!(orch.active_run_count(), 1);
}

#[test]
fn begin_run_rejects_busy_session() {
    let orch = make_orchestrator();
    let _run = orch.begin_run("s1", "run_1").unwrap();

    let err = orch.begin_run("s1", "run_2").unwrap_err();
    assert!(err.to_string().contains("busy"));
}

#[test]
fn dropping_run_clears_active() {
    let orch = make_orchestrator();
    let run = orch.begin_run("s1", "run_1").unwrap();
    assert!(orch.has_active_run("s1"));

    drop(run);
    assert!(!orch.has_active_run("s1"));
    assert_eq!(orch.active_run_count(), 0);
}

#[test]
fn get_run_id_returns_correct_id() {
    let orch = make_orchestrator();
    let _run = orch.begin_run("s1", "run_abc").unwrap();
    assert_eq!(orch.get_run_id("s1").unwrap(), "run_abc");
}

#[test]
fn get_run_id_unknown_returns_none() {
    let orch = make_orchestrator();
    assert!(orch.get_run_id("unknown").is_none());
}

// --- Abort tests ---

#[test]
fn abort_active_session_returns_true() {
    let orch = make_orchestrator();
    let run = orch.begin_run("s1", "run_1").unwrap();
    let token = run.cancel_token();

    let result = orch.abort("s1").unwrap();
    assert!(result);
    assert!(token.is_cancelled());
}

#[test]
fn abort_unknown_session_returns_false() {
    let orch = make_orchestrator();
    let result = orch.abort("nonexistent").unwrap();
    assert!(!result);
}

#[test]
fn abort_cancels_token() {
    let orch = make_orchestrator();
    let run = orch.begin_run("s1", "run_1").unwrap();
    let token = run.cancel_token();
    assert!(!token.is_cancelled());

    let _ = orch.abort("s1").unwrap();
    assert!(token.is_cancelled());
}

// --- Concurrent runs ---

#[test]
fn concurrent_runs_different_sessions() {
    let orch = make_orchestrator();
    let _t1 = orch.begin_run("s1", "run_1").unwrap();
    let _t2 = orch.begin_run("s2", "run_2").unwrap();

    assert_eq!(orch.active_run_count(), 2);
    assert!(orch.has_active_run("s1"));
    assert!(orch.has_active_run("s2"));
}

#[test]
fn abort_one_doesnt_affect_other() {
    let orch = make_orchestrator();
    let t1 = orch.begin_run("s1", "run_1").unwrap();
    let t2 = orch.begin_run("s2", "run_2").unwrap();

    let t1_token = t1.cancel_token();
    let t2_token = t2.cancel_token();

    let _ = orch.abort("s1").unwrap();
    assert!(t1_token.is_cancelled());
    assert!(!t2_token.is_cancelled());
}

// --- Capability invocation tracker tests ---

#[tokio::test]
async fn invocation_register_and_resolve() {
    let orch = make_orchestrator();
    let rx = orch.register_capability_invocation("tc_1");

    assert!(orch.has_pending_capability_invocation("tc_1"));
    assert!(orch.resolve_capability_invocation("tc_1", json!({"result": "ok"})));
    assert!(!orch.has_pending_capability_invocation("tc_1"));

    let val = rx.await.unwrap();
    assert_eq!(val["result"], "ok");
}

#[test]
fn invocation_resolve_unknown_returns_false() {
    let orch = make_orchestrator();
    assert!(!orch.resolve_capability_invocation("unknown", json!(null)));
}

// --- Concurrency limit tests ---

#[test]
fn begin_run_rejects_at_capacity() {
    let orch = make_orchestrator();

    // Fill to capacity
    let mut runs = Vec::new();
    for i in 0..MAX_CONCURRENT_SESSIONS {
        runs.push(
            orch.begin_run(&format!("s{i}"), &format!("run_{i}"))
                .unwrap(),
        );
    }
    assert_eq!(orch.active_run_count(), MAX_CONCURRENT_SESSIONS);

    // One past the ceiling should fail with ServerBusy
    let err = orch
        .begin_run(
            &format!("s{MAX_CONCURRENT_SESSIONS}"),
            &format!("run_{MAX_CONCURRENT_SESSIONS}"),
        )
        .unwrap_err();
    assert!(err.to_string().contains("Server busy"));
}

#[test]
fn permit_released_on_drop() {
    let orch = make_orchestrator();

    // Fill to capacity
    let mut runs = Vec::new();
    for i in 0..MAX_CONCURRENT_SESSIONS {
        runs.push(
            orch.begin_run(&format!("s{i}"), &format!("run_{i}"))
                .unwrap(),
        );
    }

    // At capacity — can't start another
    assert!(
        orch.begin_run(
            &format!("s{MAX_CONCURRENT_SESSIONS}"),
            &format!("run_{MAX_CONCURRENT_SESSIONS}"),
        )
        .is_err()
    );

    // Drop one run — frees a permit
    drop(runs.remove(0));
    assert_eq!(orch.active_run_count(), MAX_CONCURRENT_SESSIONS - 1);

    // Now we can start a new run
    let _t = orch
        .begin_run(
            &format!("s{MAX_CONCURRENT_SESSIONS}"),
            &format!("run_{MAX_CONCURRENT_SESSIONS}"),
        )
        .unwrap();
    assert_eq!(orch.active_run_count(), MAX_CONCURRENT_SESSIONS);
}

// --- Shutdown ---

#[tokio::test]
async fn shutdown_cancels_all_runs() {
    let orch = make_orchestrator();
    let t1 = orch.begin_run("s1", "run_1").unwrap();
    let t2 = orch.begin_run("s2", "run_2").unwrap();
    let t1_token = t1.cancel_token();
    let t2_token = t2.cancel_token();

    orch.shutdown().await.unwrap();
    assert!(t1_token.is_cancelled());
    assert!(t2_token.is_cancelled());
}

#[tokio::test]
async fn shutdown_clears_invocations() {
    let orch = make_orchestrator();
    let rx = orch.register_capability_invocation("tc_1");

    orch.shutdown().await.unwrap();
    assert!(rx.await.is_err()); // sender was dropped
}

// --- is_session_busy advisory tests ---

#[test]
fn is_session_busy_reflects_active_run() {
    let orch = make_orchestrator();
    assert!(!orch.is_session_busy("s1"));
    let run = orch.begin_run("s1", "run_1").unwrap();
    assert!(orch.is_session_busy("s1"));
    drop(run);
    assert!(!orch.is_session_busy("s1"));
}

#[tokio::test]
async fn is_session_busy_reflects_active_session() {
    let orch = make_orchestrator();
    let sid = orch
        .session_manager()
        .create_session("model", "/tmp", Some("test"))
        .unwrap();
    assert!(orch.is_session_busy(&sid));
}

// --- Sequence counter tests ---

#[test]
fn next_sequence_monotonic() {
    let orch = make_orchestrator();
    orch.init_sequence_counter("s1", 0);
    let seqs: Vec<i64> = (0..10).map(|_| orch.next_sequence("s1").unwrap()).collect();
    assert_eq!(seqs, vec![1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
}

#[test]
fn next_sequence_initializes_from_db() {
    let orch = make_orchestrator();
    orch.init_sequence_counter("s1", 5);
    assert_eq!(orch.next_sequence("s1").unwrap(), 6);
    assert_eq!(orch.next_sequence("s1").unwrap(), 7);
}

#[test]
fn next_sequence_concurrent() {
    use std::sync::Arc;
    let orch = Arc::new(make_orchestrator());
    orch.init_sequence_counter("s1", 0);

    let mut handles = Vec::new();
    for _ in 0..10 {
        let orch = Arc::clone(&orch);
        handles.push(std::thread::spawn(move || {
            orch.next_sequence("s1").unwrap()
        }));
    }
    let mut results: Vec<i64> = handles.into_iter().map(|h| h.join().unwrap()).collect();
    results.sort_unstable();
    assert_eq!(results, vec![1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
}

#[test]
fn next_sequence_cross_session_independent() {
    let orch = make_orchestrator();
    orch.init_sequence_counter("s1", 0);
    orch.init_sequence_counter("s2", 0);
    assert_eq!(orch.next_sequence("s1").unwrap(), 1);
    assert_eq!(orch.next_sequence("s2").unwrap(), 1);
    assert_eq!(orch.next_sequence("s1").unwrap(), 2);
    assert_eq!(orch.next_sequence("s2").unwrap(), 2);
}

#[test]
fn sequence_counter_cleaned_on_session_end() {
    let orch = make_orchestrator();
    orch.init_sequence_counter("s1", 0);
    assert!(orch.current_sequence("s1").is_some());
    orch.remove_sequence_counter("s1");
    assert!(orch.current_sequence("s1").is_none());
}

#[test]
fn current_sequence_returns_none_for_unknown() {
    let orch = make_orchestrator();
    assert!(orch.current_sequence("unknown").is_none());
}

#[test]
fn current_sequence_reads_without_increment() {
    let orch = make_orchestrator();
    orch.init_sequence_counter("s1", 0);
    let _ = orch.next_sequence("s1").unwrap();
    let _ = orch.next_sequence("s1").unwrap();
    assert_eq!(orch.current_sequence("s1"), Some(2));
    assert_eq!(orch.current_sequence("s1"), Some(2));
}

#[test]
fn init_counter_simulates_server_restart() {
    // Simulates: server restarts, queries MAX(sequence) = 42 from DB, inits counter at 42
    let orch = make_orchestrator();
    orch.init_sequence_counter("s1", 42);
    // Next sequence should be 43, not 1
    assert_eq!(orch.next_sequence("s1").unwrap(), 43);
    assert_eq!(orch.next_sequence("s1").unwrap(), 44);
}

#[test]
fn reinit_counter_resets_to_new_start() {
    // Simulates: counter existed, then session is re-initialized
    let orch = make_orchestrator();
    orch.init_sequence_counter("s1", 0);
    assert_eq!(orch.next_sequence("s1").unwrap(), 1);
    assert_eq!(orch.next_sequence("s1").unwrap(), 2);

    // Re-init to a higher value (e.g., after DB sync)
    orch.init_sequence_counter("s1", 100);
    assert_eq!(orch.next_sequence("s1").unwrap(), 101);
}

#[test]
fn ensure_sequence_counter_advances_stale_counter() {
    let orch = make_orchestrator();
    orch.init_sequence_counter("s1", 2);

    let counter = orch.ensure_sequence_counter_at_least("s1", 155);

    assert_eq!(counter.load(Ordering::SeqCst), 155);
    assert_eq!(orch.next_sequence("s1").unwrap(), 156);
}

#[test]
fn ensure_sequence_counter_never_rewinds_live_counter() {
    let orch = make_orchestrator();
    orch.init_sequence_counter("s1", 200);

    let counter = orch.ensure_sequence_counter_at_least("s1", 155);

    assert_eq!(counter.load(Ordering::SeqCst), 200);
    assert_eq!(orch.next_sequence("s1").unwrap(), 201);
}

#[test]
fn ensure_sequence_counter_initializes_missing_counter() {
    let orch = make_orchestrator();

    let counter = orch.ensure_sequence_counter_at_least("s1", 42);

    assert_eq!(counter.load(Ordering::SeqCst), 42);
    assert_eq!(orch.next_sequence("s1").unwrap(), 43);
}

// ── Retain concurrency guard tests ──

#[test]
fn try_begin_retain_first_call_succeeds() {
    let orch = make_orchestrator();
    let guard = orch.try_begin_retain("s1");
    assert!(guard.is_some());
    assert!(orch.retain_is_in_flight("s1"));
}

#[test]
fn try_begin_retain_second_call_blocked_until_first_drops() {
    let orch = make_orchestrator();
    let first = orch.try_begin_retain("s1").expect("first must succeed");
    assert!(
        orch.try_begin_retain("s1").is_none(),
        "second concurrent call must return None"
    );
    drop(first);
    assert!(
        orch.try_begin_retain("s1").is_some(),
        "after drop, slot must be reclaimable"
    );
}

#[test]
fn try_begin_retain_independent_across_sessions() {
    let orch = make_orchestrator();
    let a = orch.try_begin_retain("s1").unwrap();
    let b = orch.try_begin_retain("s2").unwrap();
    // Both guards held simultaneously for different sessions.
    assert!(orch.retain_is_in_flight("s1"));
    assert!(orch.retain_is_in_flight("s2"));
    drop(a);
    assert!(!orch.retain_is_in_flight("s1"));
    assert!(orch.retain_is_in_flight("s2"));
    drop(b);
    assert!(!orch.retain_is_in_flight("s2"));
}

#[test]
fn retain_guard_clears_on_panic() {
    let orch = Arc::new(make_orchestrator());
    let orch_clone = Arc::clone(&orch);
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _guard = orch_clone
            .try_begin_retain("s1")
            .expect("first must succeed");
        panic!("forced panic to verify RAII cleanup");
    }));
    assert!(result.is_err(), "expected panic");
    assert!(
        !orch.retain_is_in_flight("s1"),
        "guard drop during unwind must clear the slot"
    );
    assert!(
        orch.try_begin_retain("s1").is_some(),
        "slot is reclaimable after panic-drop"
    );
}

#[test]
fn next_sequence_returns_error_when_not_initialized() {
    let orch = make_orchestrator();
    let result = orch.next_sequence("nonexistent");
    assert!(result.is_err());
}

#[test]
fn next_sequence_error_contains_session_id() {
    let orch = make_orchestrator();
    let err = orch.next_sequence("sess_abc123").unwrap_err();
    let msg = err.to_string();
    assert!(
        msg.contains("sess_abc123"),
        "error should contain session id: {msg}"
    );
}

// --- Orphaned run cleanup ---

#[tokio::test]
async fn shutdown_clears_orphaned_runs() {
    let orch = make_orchestrator();
    let t1 = orch.begin_run("s1", "run_1").unwrap();
    let t2 = orch.begin_run("s2", "run_2").unwrap();
    let t1_token = t1.cancel_token();
    let t2_token = t2.cancel_token();
    assert_eq!(orch.active_run_count(), 2);

    orch.shutdown().await.unwrap();
    assert!(t1_token.is_cancelled());
    assert!(t2_token.is_cancelled());
    assert_eq!(
        orch.active_run_count(),
        0,
        "active_runs must be cleared after shutdown"
    );
}
