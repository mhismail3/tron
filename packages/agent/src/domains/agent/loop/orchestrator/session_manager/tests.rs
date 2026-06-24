use super::*;

fn make_manager() -> SessionManager {
    let pool = crate::domains::session::event_store::new_in_memory(
        &crate::domains::session::event_store::ConnectionConfig::default(),
    )
    .unwrap();
    {
        let conn = pool.get().unwrap();
        let _ = crate::domains::session::event_store::run_migrations(&conn).unwrap();
    }
    SessionManager::new(Arc::new(EventStore::new(pool)))
}

#[tokio::test]
async fn create_session() {
    let mgr = make_manager();
    let sid = mgr
        .create_session("test-model", "/tmp", Some("test"))
        .unwrap();
    assert!(!sid.is_empty());
    assert!(mgr.is_active(&sid));
    assert_eq!(mgr.active_count(), 1);
}

#[tokio::test]
async fn resume_session() {
    let mgr = make_manager();
    let sid = mgr
        .create_session("test-model", "/tmp", Some("test"))
        .unwrap();

    // Drop from active cache
    mgr.invalidate_session(&sid);
    assert!(!mgr.is_active(&sid));

    // Resume should reconstruct
    let active = mgr.resume_session(&sid).unwrap();
    assert_eq!(active.state.model, "test-model");
    assert!(mgr.is_active(&sid));
}

#[tokio::test]
async fn resume_already_active() {
    let mgr = make_manager();
    let sid = mgr
        .create_session("test-model", "/tmp", Some("test"))
        .unwrap();

    // Resume when already active should return existing
    let active = mgr.resume_session(&sid).unwrap();
    assert_eq!(active.state.model, "test-model");
    assert_eq!(mgr.active_count(), 1);
}

#[tokio::test]
async fn end_session() {
    let mgr = make_manager();
    let sid = mgr
        .create_session("test-model", "/tmp", Some("test"))
        .unwrap();

    mgr.end_session(&sid).await.unwrap();
    assert!(!mgr.is_active(&sid));
}

/// Anchors the wire contract that `session.end` is an actively emitted
/// event. This test guards against any future change that accidentally
/// stops emitting the event (e.g. refactoring `end_session` to skip
/// the append) because the iOS display layer treats the event as current.
#[tokio::test]
async fn end_session_emits_session_end_event() {
    use crate::domains::session::event_store::ListEventsOptions;

    let mgr = make_manager();
    let sid = mgr
        .create_session("test-model", "/tmp", Some("test"))
        .unwrap();

    mgr.end_session(&sid).await.unwrap();

    let events = mgr
        .event_store
        .get_events_by_session(&sid, &ListEventsOptions::default())
        .unwrap();
    let end_event = events
        .iter()
        .find(|e| e.event_type == EventType::SessionEnd.as_str())
        .expect("end_session must persist a session.end event");
    let payload: serde_json::Value = serde_json::from_str(&end_event.payload).unwrap();
    assert_eq!(
        payload.get("reason").and_then(|r| r.as_str()),
        Some("completed"),
        "session.end payload must carry reason=completed"
    );
}

#[tokio::test]
async fn fork_session() {
    let mgr = make_manager();
    let sid = mgr
        .create_session("test-model", "/tmp", Some("test"))
        .unwrap();

    let result = mgr.fork_session(&sid, None, None, Some("forked")).unwrap();
    assert!(!result.new_session_id.is_empty());
    assert_ne!(result.new_session_id, sid);
    assert!(!result.root_event_id.is_empty());
    assert!(!result.forked_from_event_id.is_empty());
}

#[tokio::test]
async fn fork_session_from_specific_event() {
    let mgr = make_manager();
    let sid = mgr
        .create_session("test-model", "/tmp", Some("test"))
        .unwrap();

    // Append an event so we have something besides the root to fork from
    let evt = mgr
        .event_store
        .append(&crate::domains::session::event_store::AppendOptions {
            session_id: &sid,
            event_type: crate::domains::session::event_store::EventType::MessageUser,
            payload: serde_json::json!({"text": "hello"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    // Append another event so HEAD is different from our target
    let _ = mgr
        .event_store
        .append(&crate::domains::session::event_store::AppendOptions {
            session_id: &sid,
            event_type: crate::domains::session::event_store::EventType::MessageAssistant,
            payload: serde_json::json!({"text": "world"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let result = mgr.fork_session(&sid, Some(&evt.id), None, None).unwrap();
    assert_eq!(
        result.forked_from_event_id, evt.id,
        "should fork from the specified event, not HEAD"
    );
}

#[tokio::test]
async fn fork_session_from_head_when_no_event_id() {
    let mgr = make_manager();
    let sid = mgr
        .create_session("test-model", "/tmp", Some("test"))
        .unwrap();

    // Get the HEAD event
    let session = mgr.event_store.get_session(&sid).unwrap().unwrap();
    let head_event_id = session.head_event_id.unwrap();

    let result = mgr.fork_session(&sid, None, None, None).unwrap();
    assert_eq!(
        result.forked_from_event_id, head_event_id,
        "fork with no event ID should fork from HEAD"
    );
}

#[tokio::test]
async fn fork_session_from_nonexistent_event_fails() {
    let mgr = make_manager();
    let _sid = mgr
        .create_session("test-model", "/tmp", Some("test"))
        .unwrap();

    let result = mgr.fork_session(&_sid, Some("nonexistent-event-id"), None, None);
    assert!(
        result.is_err(),
        "fork from nonexistent event should return error"
    );
}

#[tokio::test]
async fn archive_and_unarchive() {
    let mgr = make_manager();
    let sid = mgr
        .create_session("test-model", "/tmp", Some("test"))
        .unwrap();

    mgr.archive_session(&sid).unwrap();
    assert!(!mgr.is_active(&sid));

    mgr.unarchive_session(&sid).unwrap();
    // Unarchive makes it available but doesn't add to active map
    assert!(!mgr.is_active(&sid));
}

#[tokio::test]
async fn delete_session() {
    let mgr = make_manager();
    let sid = mgr
        .create_session("test-model", "/tmp", Some("test"))
        .unwrap();

    mgr.delete_session(&sid).unwrap();
    assert!(!mgr.is_active(&sid));
}

#[tokio::test]
async fn list_sessions() {
    let mgr = make_manager();
    let _ = mgr.create_session("model-a", "/tmp/a", Some("s1")).unwrap();
    let _ = mgr.create_session("model-b", "/tmp/b", Some("s2")).unwrap();

    let sessions = mgr.list_sessions(&SessionFilter::default()).unwrap();
    assert_eq!(sessions.len(), 2);
}

#[tokio::test]
async fn list_sessions_filters_by_workspace_path_and_offset() {
    let mgr = make_manager();
    let first = mgr.create_session("model-a", "/tmp/a", Some("s1")).unwrap();
    let second = mgr.create_session("model-b", "/tmp/b", Some("s2")).unwrap();

    let filtered = mgr
        .list_sessions(&SessionFilter {
            workspace_path: Some("/tmp/a".to_string()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(filtered.len(), 1);
    assert_eq!(filtered[0].id, first);

    let paged = mgr
        .list_sessions(&SessionFilter {
            limit: Some(1),
            offset: Some(1),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(paged.len(), 1);
    assert!(
        paged
            .iter()
            .all(|session| session.id == first || session.id == second)
    );
}

#[tokio::test]
async fn get_session() {
    let mgr = make_manager();
    let sid = mgr
        .create_session("test-model", "/tmp", Some("test"))
        .unwrap();

    let session = mgr.get_session(&sid).unwrap();
    assert!(session.is_some());
}

#[tokio::test]
async fn session_not_found() {
    let mgr = make_manager();
    let result = mgr.resume_session("nonexistent");
    assert!(result.is_err());
}

// ── Cache eviction tests ────────────────────────────────────

#[tokio::test]
async fn evict_idle_session() {
    let mgr = make_manager();
    let sid = mgr.create_session("m", "/tmp", Some("test")).unwrap();

    // Force last_accessed to the past
    if let Some(cached) = mgr.active_sessions.get(&sid) {
        *cached.last_accessed.lock() = Instant::now() - Duration::from_secs(7200);
    }

    let evicted = mgr.evict_idle_sessions(Duration::from_secs(3600));
    assert_eq!(evicted, 1);
    assert!(!mgr.is_active(&sid));
}

#[tokio::test]
async fn evict_preserves_recent_session() {
    let mgr = make_manager();
    let sid = mgr.create_session("m", "/tmp", Some("test")).unwrap();

    let evicted = mgr.evict_idle_sessions(Duration::from_secs(3600));
    assert_eq!(evicted, 0);
    assert!(mgr.is_active(&sid));
}

#[tokio::test]
async fn evict_preserves_processing_session() {
    let mgr = make_manager();
    let sid = mgr.create_session("m", "/tmp", Some("test")).unwrap();

    // Mark as processing and make it old
    let _ = mgr.mark_processing(&sid);
    if let Some(cached) = mgr.active_sessions.get(&sid) {
        *cached.last_accessed.lock() = Instant::now() - Duration::from_secs(7200);
    }

    let evicted = mgr.evict_idle_sessions(Duration::from_secs(3600));
    assert_eq!(evicted, 0, "processing session must not be evicted");
    assert!(mgr.is_active(&sid));
}

#[tokio::test]
async fn evicted_session_reconstructs_on_resume() {
    let mgr = make_manager();
    let sid = mgr.create_session("m", "/tmp", Some("test")).unwrap();

    // Evict it
    if let Some(cached) = mgr.active_sessions.get(&sid) {
        *cached.last_accessed.lock() = Instant::now() - Duration::from_secs(7200);
    }
    let _ = mgr.evict_idle_sessions(Duration::from_secs(3600));
    assert!(!mgr.is_active(&sid));

    // Resume should reconstruct
    let active = mgr.resume_session(&sid).unwrap();
    assert_eq!(active.state.model, "m");
    assert!(mgr.is_active(&sid));
}

#[tokio::test]
async fn evict_mixed_idle_and_active() {
    let mgr = make_manager();
    let idle = mgr.create_session("m", "/tmp", Some("idle")).unwrap();
    let recent = mgr.create_session("m", "/tmp", Some("recent")).unwrap();

    if let Some(cached) = mgr.active_sessions.get(&idle) {
        *cached.last_accessed.lock() = Instant::now() - Duration::from_secs(7200);
    }

    let evicted = mgr.evict_idle_sessions(Duration::from_secs(3600));
    assert_eq!(evicted, 1);
    assert!(!mgr.is_active(&idle));
    assert!(mgr.is_active(&recent));
}

#[tokio::test]
async fn evict_zero_ttl_evicts_all_idle() {
    let mgr = make_manager();
    let s1 = mgr.create_session("m", "/tmp", Some("s1")).unwrap();
    let s2 = mgr.create_session("m", "/tmp", Some("s2")).unwrap();

    let evicted = mgr.evict_idle_sessions(Duration::ZERO);
    assert_eq!(evicted, 2);
    assert!(!mgr.is_active(&s1));
    assert!(!mgr.is_active(&s2));
}

#[tokio::test]
async fn evict_empty_map_is_noop() {
    let mgr = make_manager();
    let evicted = mgr.evict_idle_sessions(Duration::from_secs(3600));
    assert_eq!(evicted, 0);
}

#[tokio::test]
async fn processing_flag_lifecycle() {
    let mgr = make_manager();
    let sid = mgr.create_session("m", "/tmp", Some("test")).unwrap();

    assert!(!mgr.is_processing(&sid));
    mgr.mark_processing(&sid);
    assert!(mgr.is_processing(&sid));
    mgr.clear_processing(&sid);
    assert!(!mgr.is_processing(&sid));
}
