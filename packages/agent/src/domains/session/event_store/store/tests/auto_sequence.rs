use super::*;

// ── M11: auto-sequence allocation invariant ───────────────────────

/// Concurrent `sequence: None` appends to the same session must produce
/// strictly monotonic, gap-free sequences without ever triggering
/// `UNIQUE(session_id, sequence)` failures.
///
/// This is the full correctness claim documented at
/// `append_event_in_tx` — serialized by the per-session write lock and
/// SQLite's UNIQUE constraint as a backstop.
#[test]
fn concurrent_auto_sequence_appends_are_strictly_monotonic() {
    use std::sync::Arc;
    use std::thread;

    let store = Arc::new(setup());
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None)
        .unwrap();
    let session_id = cr.session.id.clone();

    const THREADS: usize = 8;
    const PER_THREAD: usize = 32;

    let mut handles = Vec::with_capacity(THREADS);
    for tid in 0..THREADS {
        let store = Arc::clone(&store);
        let sid = session_id.clone();
        handles.push(thread::spawn(move || {
            for i in 0..PER_THREAD {
                store
                    .append(&AppendOptions {
                        session_id: &sid,
                        event_type: EventType::MessageUser,
                        payload: serde_json::json!({"t": tid, "i": i}),
                        parent_id: None,
                        sequence: None,
                    })
                    .expect("concurrent auto-seq append must succeed");
            }
        }));
    }
    for h in handles {
        h.join().unwrap();
    }

    // Fetch every event and verify the sequence set is exactly
    // {1..=THREADS*PER_THREAD} (root has sequence 0, auto-allocated starts at 1).
    let events = store
        .get_events_by_session(&session_id, &ListEventsOptions::default())
        .unwrap();
    let mut seqs: Vec<i64> = events.iter().map(|e| e.sequence).collect();
    seqs.sort_unstable();

    let expected_max = (THREADS * PER_THREAD) as i64;
    let expected: Vec<i64> = (0..=expected_max).collect();
    assert_eq!(
        seqs, expected,
        "sequences must be gap-free 0..={expected_max} under concurrent auto-allocation"
    );
}

/// Auto-allocated sequence starts at `MAX(sequence) + 1` from what's
/// already in the DB. Pre-assigned and auto-allocated calls interleave
/// correctly: if we insert sequence=42 explicitly and then call append
/// with `sequence: None`, the next auto value is 43.
#[test]
fn auto_sequence_resumes_from_pre_assigned_max() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None)
        .unwrap();

    // Pre-assign a gap (sequence 42) — simulates an import or test scenario
    // that wants a specific sequence slot.
    let explicit = store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"kind": "pre-assigned"}),
            parent_id: None,
            sequence: Some(42),
        })
        .unwrap();
    assert_eq!(explicit.sequence, 42);

    // Next auto-allocated append must pick 43, not 1.
    let auto = store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({"kind": "auto"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    assert_eq!(auto.sequence, 43);
}

/// Auto-allocated sequences on different sessions are independent —
/// allocation reads from `MAX(sequence) WHERE session_id = ?1`.
#[test]
fn auto_sequence_is_per_session() {
    let store = setup();
    let a = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None)
        .unwrap();
    let b = store
        .create_session("claude-opus-4-6", "/tmp/project-b", None, None)
        .unwrap();

    // Append 3 events to session A.
    for _ in 0..3 {
        store
            .append(&AppendOptions {
                session_id: &a.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
    }

    // First append to session B must still start at sequence 1.
    let first_b = store
        .append(&AppendOptions {
            session_id: &b.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    assert_eq!(first_b.sequence, 1);
}
