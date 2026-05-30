use super::*;

// ── Fork ──────────────────────────────────────────────────────────

#[test]
fn fork_basic() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None, None, None)
        .unwrap();

    let user_msg = store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "Hello"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let fork = store.fork(&user_msg.id, &ForkOptions::default()).unwrap();

    assert!(fork.session.id.starts_with("sess_"));
    assert_ne!(fork.session.id, cr.session.id);
    assert_eq!(
        fork.session.parent_session_id.as_deref(),
        Some(cr.session.id.as_str())
    );
    assert_eq!(
        fork.session.fork_from_event_id.as_deref(),
        Some(user_msg.id.as_str())
    );
    assert_eq!(fork.fork_event.event_type, "session.fork");
    assert_eq!(
        fork.fork_event.parent_id.as_deref(),
        Some(user_msg.id.as_str())
    );
    assert_eq!(fork.session.event_count, 1);
}

#[test]
fn fork_ancestors_cross_sessions() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None, None, None)
        .unwrap();

    let user_msg = store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "Hello"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let fork = store.fork(&user_msg.id, &ForkOptions::default()).unwrap();

    // Ancestor walk from fork event traverses back through source session
    let ancestors = store.get_ancestors(&fork.fork_event.id).unwrap();
    assert_eq!(ancestors.len(), 3); // source root → user msg → fork event
    assert_eq!(ancestors[0].id, cr.root_event.id);
    assert_eq!(ancestors[1].id, user_msg.id);
    assert_eq!(ancestors[2].id, fork.fork_event.id);
}

#[test]
fn fork_with_model_override() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None, None, None)
        .unwrap();

    let fork = store
        .fork(
            &cr.root_event.id,
            &ForkOptions {
                model: Some("claude-sonnet-4-5"),
                title: Some("Forked"),
            },
        )
        .unwrap();

    assert_eq!(fork.session.latest_model, "claude-sonnet-4-5");
    assert_eq!(fork.session.title.as_deref(), Some("Forked"));
}

#[test]
fn fork_nonexistent_event_fails() {
    let store = setup();
    let result = store.fork("evt_nonexistent", &ForkOptions::default());
    assert!(result.is_err());
}

// ── Message deletion ──────────────────────────────────────────────

#[test]
fn delete_message_basic() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None, None, None)
        .unwrap();

    let user_msg = store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "Delete me"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let delete_event = store
        .delete_message(&cr.session.id, &user_msg.id, None)
        .unwrap();

    assert_eq!(delete_event.event_type, "message.deleted");
    let payload: Value = serde_json::from_str(&delete_event.payload).unwrap();
    assert_eq!(payload["targetEventId"], user_msg.id);
}

#[test]
fn delete_non_message_fails() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None, None, None)
        .unwrap();

    // Try to delete the root session.start event
    let result = store.delete_message(&cr.session.id, &cr.root_event.id, None);
    assert!(result.is_err());
}

// ── Session management ────────────────────────────────────────────

#[test]
fn get_session() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None, None, None)
        .unwrap();

    let session = store.get_session(&cr.session.id).unwrap();
    assert!(session.is_some());
}

#[test]
fn list_sessions() {
    let store = setup();
    store
        .create_session("claude-opus-4-6", "/tmp/project", None, None, None, None)
        .unwrap();
    store
        .create_session("claude-opus-4-6", "/tmp/project", None, None, None, None)
        .unwrap();

    let sessions = store
        .list_sessions(&ListSessionsOptions::default())
        .unwrap();
    assert_eq!(sessions.len(), 2);
}

#[test]
fn end_and_reactivate_session() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None, None, None)
        .unwrap();

    store.end_session(&cr.session.id).unwrap();
    let session = store.get_session(&cr.session.id).unwrap().unwrap();
    assert!(session.ended_at.is_some());

    store.clear_session_ended(&cr.session.id).unwrap();
    let session = store.get_session(&cr.session.id).unwrap().unwrap();
    assert!(session.ended_at.is_none());
}

#[test]
fn update_session_title() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None, None, None)
        .unwrap();

    store
        .update_session_title(&cr.session.id, Some("New Title"))
        .unwrap();
    let session = store.get_session(&cr.session.id).unwrap().unwrap();
    assert_eq!(session.title.as_deref(), Some("New Title"));
}

#[test]
fn delete_session_cascade() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None, None, None)
        .unwrap();

    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "Hello"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    assert!(store.delete_session(&cr.session.id).unwrap());
    assert!(store.get_session(&cr.session.id).unwrap().is_none());

    let events = store
        .get_events_by_session(&cr.session.id, &ListEventsOptions::default())
        .unwrap();
    assert!(events.is_empty());
}

// ── Source tracking ────────────────────────────────────────────────

#[test]
fn update_source_sets_source() {
    let store = setup();
    let cr = store
        .create_session(
            "claude-opus-4-6",
            "/tmp/project",
            Some("Cron: test"),
            None,
            None,
            None,
        )
        .unwrap();

    let updated = store.update_source(&cr.session.id, "cron").unwrap();
    assert!(updated);

    let session = store.get_session(&cr.session.id).unwrap().unwrap();
    assert_eq!(session.source.as_deref(), Some("cron"));
}

#[test]
fn update_source_nonexistent_session() {
    let store = setup();
    let updated = store.update_source("sess_nonexistent", "cron").unwrap();
    assert!(!updated);
}

#[test]
fn update_source_is_idempotent() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None, None, None)
        .unwrap();

    store.update_source(&cr.session.id, "cron").unwrap();
    let updated = store.update_source(&cr.session.id, "cron").unwrap();
    assert!(updated);

    let session = store.get_session(&cr.session.id).unwrap().unwrap();
    assert_eq!(session.source.as_deref(), Some("cron"));
}

#[test]
fn update_spawn_info_links_subagent_and_lists_it() {
    let store = setup();
    let parent = store
        .create_session(
            "claude-opus-4-6",
            "/tmp/project",
            Some("Parent"),
            None,
            None,
            None,
        )
        .unwrap();
    let child = store
        .create_session(
            "claude-opus-4-6",
            "/tmp/project",
            Some("Child"),
            None,
            None,
            None,
        )
        .unwrap();

    let updated = store
        .update_spawn_info(
            &child.session.id,
            &parent.session.id,
            "query",
            "summarize history",
        )
        .unwrap();
    assert!(updated);

    let child_session = store.get_session(&child.session.id).unwrap().unwrap();
    assert_eq!(
        child_session.spawning_session_id.as_deref(),
        Some(parent.session.id.as_str())
    );
    assert_eq!(child_session.spawn_type.as_deref(), Some("query"));
    assert_eq!(
        child_session.spawn_task.as_deref(),
        Some("summarize history")
    );

    let subagents = store.list_subagents(&parent.session.id).unwrap();
    assert_eq!(subagents.len(), 1);
    assert_eq!(subagents[0].id, child.session.id);
}

#[test]
fn update_spawn_info_nonexistent_session_returns_false() {
    let store = setup();
    let updated = store
        .update_spawn_info(
            "sess_nonexistent",
            "sess_parent",
            "query",
            "summarize history",
        )
        .unwrap();
    assert!(!updated);
}

#[test]
fn was_session_interrupted_tracks_incomplete_turns() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None, None, None)
        .unwrap();

    assert!(!store.was_session_interrupted(&cr.session.id).unwrap());

    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({
                "content": [{"type": "text", "text": "Partial response"}],
                "turn": 1,
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    assert!(store.was_session_interrupted(&cr.session.id).unwrap());

    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::StreamTurnEnd,
            payload: serde_json::json!({
                "turn": 1,
                "tokenUsage": {"inputTokens": 10, "outputTokens": 5},
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    assert!(!store.was_session_interrupted(&cr.session.id).unwrap());
}

// ── Blob storage ──────────────────────────────────────────────────

#[test]
fn blob_storage() {
    let store = setup();
    let blob_id = store.store_blob(b"hello world", "text/plain").unwrap();

    let content = store.get_blob_content(&blob_id).unwrap().unwrap();
    assert_eq!(content, b"hello world");

    let blob = store.get_blob(&blob_id).unwrap().unwrap();
    assert_eq!(blob.mime_type, "text/plain");
    assert_eq!(blob.size_original, 11);
}

// ── Workspace ─────────────────────────────────────────────────────

#[test]
fn workspace_get_or_create() {
    let store = setup();
    let ws1 = store
        .get_or_create_workspace("/tmp/project", Some("Project"))
        .unwrap();
    let ws2 = store.get_or_create_workspace("/tmp/project", None).unwrap();
    assert_eq!(ws1.id, ws2.id);
}

#[test]
fn list_workspaces() {
    let store = setup();
    store
        .create_session("claude-opus-4-6", "/tmp/a", None, None, None, None)
        .unwrap();
    store
        .create_session("claude-opus-4-6", "/tmp/b", None, None, None, None)
        .unwrap();

    let workspaces = store.list_workspaces().unwrap();
    assert_eq!(workspaces.len(), 2);
}

// ── Complex scenarios ─────────────────────────────────────────────

#[test]
fn agentic_loop() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None, None, None)
        .unwrap();

    // Turn 1: user → assistant(capability_invocation) → turn_end → capability.invocation.completed → assistant(end_turn) → turn_end
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "List files", "turn": 1}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({
                "content": [{"type": "capability_invocation", "id": "capability_1", "name": "process::run", "arguments": {"command": "ls"}}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 200, "outputTokens": 30}
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::StreamTurnEnd,
            payload: serde_json::json!({
                "tokenUsage": {"inputTokens": 200, "outputTokens": 30}
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::CapabilityInvocationCompleted,
            payload: serde_json::json!({
                "invocationId": "capability_1",
                "content": "file1.txt\nfile2.txt",
                "turn": 1
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({
                "content": [{"type": "text", "text": "I found 2 files."}],
                "turn": 1,
                "stopReason": "end_turn",
                "tokenUsage": {"inputTokens": 300, "outputTokens": 20}
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::StreamTurnEnd,
            payload: serde_json::json!({
                "tokenUsage": {"inputTokens": 300, "outputTokens": 20}
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let session = store.get_session(&cr.session.id).unwrap().unwrap();
    assert_eq!(session.event_count, 7); // root + 6
    assert_eq!(session.message_count, 3); // 1 user + 2 assistant
    assert_eq!(session.total_input_tokens, 500);
    assert_eq!(session.total_output_tokens, 50);

    let events = store
        .get_events_by_session(&cr.session.id, &ListEventsOptions::default())
        .unwrap();
    assert_eq!(events.len(), 7);
    for (i, event) in events.iter().enumerate() {
        assert_eq!(event.sequence, i as i64);
    }
}

#[test]
fn fork_then_diverge() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None, None, None)
        .unwrap();

    let user_msg = store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "Hello"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let assistant_msg = store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({"content": "World"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    // Fork from user message (before assistant response)
    let fork = store.fork(&user_msg.id, &ForkOptions::default()).unwrap();

    // Add different continuation in fork
    let fork_response = store
        .append(&AppendOptions {
            session_id: &fork.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({"content": "Alternative response"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    // Original session unchanged
    let orig_events = store
        .get_events_by_session(&cr.session.id, &ListEventsOptions::default())
        .unwrap();
    assert_eq!(orig_events.len(), 3); // root + user + assistant

    // Fork has: source root → user msg → fork event → fork response
    let fork_ancestors = store.get_ancestors(&fork_response.id).unwrap();
    assert_eq!(fork_ancestors.len(), 4);
    assert_eq!(fork_ancestors[0].id, cr.root_event.id);
    assert_eq!(fork_ancestors[1].id, user_msg.id);
    assert_eq!(fork_ancestors[2].id, fork.fork_event.id);
    assert_eq!(fork_ancestors[3].id, fork_response.id);

    // Original assistant response NOT in fork ancestors
    assert!(fork_ancestors.iter().all(|e| e.id != assistant_msg.id));
}
