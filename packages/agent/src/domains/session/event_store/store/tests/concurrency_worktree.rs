use super::*;

// ── Concurrency (write serialization) ───────────────────────────

#[test]
fn concurrent_appends_produce_unique_sequences() {
    use std::sync::Arc;

    let (store, _dir) = setup_file_backed();
    let store = Arc::new(store);

    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None, None, None)
        .unwrap();
    let session_id = cr.session.id.clone();

    let threads: Vec<_> = (0..20)
        .map(|_| {
            let store = Arc::clone(&store);
            let sid = session_id.clone();
            std::thread::spawn(move || {
                let mut ids = Vec::new();
                for _ in 0..10 {
                    let event = store
                        .append(&AppendOptions {
                            session_id: &sid,
                            event_type: EventType::MessageUser,
                            payload: serde_json::json!({"content": "concurrent"}),
                            parent_id: None,
                            sequence: None,
                        })
                        .unwrap();
                    ids.push((event.id, event.sequence));
                }
                ids
            })
        })
        .collect();

    let mut all_sequences = std::collections::HashSet::new();
    for handle in threads {
        let ids = handle.join().unwrap();
        for (_id, seq) in ids {
            assert!(all_sequences.insert(seq), "duplicate sequence: {seq}");
        }
    }

    // root (seq 0) + 200 appended events = 201 unique sequences
    assert_eq!(all_sequences.len(), 200);
}

#[test]
fn concurrent_appends_to_different_sessions() {
    use std::sync::Arc;

    let (store, _dir) = setup_file_backed();
    let store = Arc::new(store);

    let threads: Vec<_> = (0..10)
        .map(|i| {
            let store = Arc::clone(&store);
            std::thread::spawn(move || {
                let cr = store
                    .create_session(
                        "claude-opus-4-6",
                        &format!("/tmp/project-{i}"),
                        None,
                        None,
                        None,
                        None,
                    )
                    .unwrap();
                for _ in 0..5 {
                    store
                        .append(&AppendOptions {
                            session_id: &cr.session.id,
                            event_type: EventType::MessageUser,
                            payload: serde_json::json!({"content": "msg"}),
                            parent_id: None,
                            sequence: None,
                        })
                        .unwrap();
                }
                cr.session.id
            })
        })
        .collect();

    for handle in threads {
        let sid = handle.join().unwrap();
        let count = store.count_events(&sid).unwrap();
        assert_eq!(count, 6); // 1 root + 5 appended
    }
}

#[test]
fn concurrent_reads_during_writes() {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};

    let (store, _dir) = setup_file_backed();
    let store = Arc::new(store);

    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None, None, None)
        .unwrap();
    let session_id = cr.session.id.clone();

    let done = Arc::new(AtomicBool::new(false));

    // Writer thread: append 50 events
    let writer_store = Arc::clone(&store);
    let writer_sid = session_id.clone();
    let writer_done = Arc::clone(&done);
    let writer = std::thread::spawn(move || {
        for _ in 0..50 {
            writer_store
                .append(&AppendOptions {
                    session_id: &writer_sid,
                    event_type: EventType::MessageUser,
                    payload: serde_json::json!({"content": "write"}),
                    parent_id: None,
                    sequence: None,
                })
                .unwrap();
        }
        writer_done.store(true, Ordering::SeqCst);
    });

    // Reader threads: query continuously until writer is done
    let readers: Vec<_> = (0..4)
        .map(|_| {
            let store = Arc::clone(&store);
            let sid = session_id.clone();
            let done = Arc::clone(&done);
            std::thread::spawn(move || {
                let mut read_count = 0u64;
                while !done.load(Ordering::SeqCst) {
                    let events = store
                        .get_events_by_session(&sid, &ListEventsOptions::default())
                        .unwrap();
                    // Events should always be ordered by sequence
                    for pair in events.windows(2) {
                        assert!(pair[0].sequence < pair[1].sequence, "events not ordered");
                    }
                    read_count += 1;
                }
                read_count
            })
        })
        .collect();

    writer.join().unwrap();
    for handle in readers {
        let reads = handle.join().unwrap();
        assert!(reads > 0, "reader should have performed at least one read");
    }

    // Final check: all 51 events present (root + 50)
    let final_count = store.count_events(&session_id).unwrap();
    assert_eq!(final_count, 51);
}

// ── Worktree queries ─────────────────────────────────────────────

#[test]
fn get_active_worktree_none() {
    let store = setup();
    let session = store
        .create_session("model", "/tmp", Some("test"), None, None, None)
        .unwrap();
    let result = store.get_active_worktree(&session.session.id).unwrap();
    assert!(result.is_none());
}

#[test]
fn get_active_worktree_acquired() {
    let store = setup();
    let session = store
        .create_session("model", "/tmp", Some("test"), None, None, None)
        .unwrap();
    let sid = &session.session.id;

    store
        .append(&AppendOptions {
            session_id: sid,
            event_type: EventType::WorktreeAcquired,
            payload: serde_json::json!({
                "path": "/repo/.worktrees/session/abc",
                "branch": "session/abc",
                "baseCommit": "deadbeef",
                "isolated": true
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let result = store.get_active_worktree(sid).unwrap();
    assert!(result.is_some());
}

#[test]
fn get_active_worktree_released() {
    let store = setup();
    let session = store
        .create_session("model", "/tmp", Some("test"), None, None, None)
        .unwrap();
    let sid = &session.session.id;

    store
        .append(&AppendOptions {
            session_id: sid,
            event_type: EventType::WorktreeAcquired,
            payload: serde_json::json!({
                "path": "/repo/.worktrees/session/abc",
                "branch": "session/abc",
                "baseCommit": "deadbeef",
                "isolated": true
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    store
        .append(&AppendOptions {
            session_id: sid,
            event_type: EventType::WorktreeReleased,
            payload: serde_json::json!({
                "deleted": true,
                "branchPreserved": true
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let result = store.get_active_worktree(sid).unwrap();
    assert!(result.is_none());
}

#[test]
fn get_active_worktree_reacquired() {
    let store = setup();
    let session = store
        .create_session("model", "/tmp", Some("test"), None, None, None)
        .unwrap();
    let sid = &session.session.id;

    // Acquired
    store
        .append(&AppendOptions {
            session_id: sid,
            event_type: EventType::WorktreeAcquired,
            payload: serde_json::json!({
                "path": "/first", "branch": "b1", "baseCommit": "aaa", "isolated": true
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    // Released
    store
        .append(&AppendOptions {
            session_id: sid,
            event_type: EventType::WorktreeReleased,
            payload: serde_json::json!({ "deleted": true, "branchPreserved": true }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    // Re-acquired
    store
        .append(&AppendOptions {
            session_id: sid,
            event_type: EventType::WorktreeAcquired,
            payload: serde_json::json!({
                "path": "/second", "branch": "b2", "baseCommit": "bbb", "isolated": true
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let result = store.get_active_worktree(sid).unwrap();
    assert!(result.is_some());
    let event = result.unwrap();
    let payload: serde_json::Value = serde_json::from_str(&event.payload).unwrap();
    assert_eq!(payload["path"], "/second");
}
