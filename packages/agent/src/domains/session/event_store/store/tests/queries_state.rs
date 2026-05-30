use super::*;

// ── Batch session queries ─────────────────────────────────────────

#[test]
fn get_sessions_by_ids_basic() {
    let store = setup();
    let cr1 = store
        .create_session("claude-opus-4-6", "/tmp/a", Some("A"), None, None, None)
        .unwrap();
    let cr2 = store
        .create_session("claude-opus-4-6", "/tmp/b", Some("B"), None, None, None)
        .unwrap();
    store
        .create_session("claude-opus-4-6", "/tmp/c", Some("C"), None, None, None)
        .unwrap();

    let ids = [cr1.session.id.as_str(), cr2.session.id.as_str()];
    let result = store.get_sessions_by_ids(&ids).unwrap();
    assert_eq!(result.len(), 2);
    assert!(result.contains_key(&cr1.session.id));
    assert!(result.contains_key(&cr2.session.id));
}

#[test]
fn get_sessions_by_ids_empty() {
    let store = setup();
    let result = store.get_sessions_by_ids(&[]).unwrap();
    assert!(result.is_empty());
}

#[test]
fn get_sessions_by_ids_missing_omitted() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/a", None, None, None, None)
        .unwrap();

    let ids = [cr.session.id.as_str(), "sess_nonexistent"];
    let result = store.get_sessions_by_ids(&ids).unwrap();
    assert_eq!(result.len(), 1);
    assert!(result.contains_key(&cr.session.id));
}

#[test]
fn get_session_message_previews_basic() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/a", None, None, None, None)
        .unwrap();

    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "What is Rust?"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({"content": "A systems language."}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let ids = [cr.session.id.as_str()];
    let previews = store.get_session_message_previews(&ids).unwrap();
    let preview = &previews[&cr.session.id];
    assert_eq!(preview.last_user_prompt.as_deref(), Some("What is Rust?"));
    assert_eq!(
        preview.last_assistant_response.as_deref(),
        Some("A systems language.")
    );
}

// ── Batch event queries ───────────────────────────────────────────

#[test]
fn get_events_by_ids_basic() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/a", None, None, None, None)
        .unwrap();
    let evt = store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "Hello"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let ids = [cr.root_event.id.as_str(), evt.id.as_str()];
    let result = store.get_events_by_ids(&ids).unwrap();
    assert_eq!(result.len(), 2);
    assert!(result.contains_key(&cr.root_event.id));
    assert!(result.contains_key(&evt.id));
}

#[test]
fn get_events_by_sessions_and_types_returns_all_matching_events() {
    let store = setup();
    let first = store
        .create_session("claude-opus-4-6", "/tmp/project-a", None, None, None, None)
        .unwrap();
    let second = store
        .create_session("claude-opus-4-6", "/tmp/project-b", None, None, None, None)
        .unwrap();

    let first_user = store
        .append(&AppendOptions {
            session_id: &first.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "first"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    let _ = store
        .append(&AppendOptions {
            session_id: &first.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({"content": "reply"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    let second_user = store
        .append(&AppendOptions {
            session_id: &second.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "second"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let events = store
        .get_events_by_sessions_and_types(
            &[&first.session.id, &second.session.id],
            &["message.user"],
        )
        .unwrap();

    assert_eq!(events.len(), 2);
    assert_eq!(events[0].id, first_user.id);
    assert_eq!(events[1].id, second_user.id);
}

#[test]
fn get_events_by_type_basic() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/a", None, None, None, None)
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
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({"content": "Hi"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let result = store
        .get_events_by_type(&cr.session.id, &["message.user"], None)
        .unwrap();
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].event_type, "message.user");
}

#[test]
fn get_events_by_workspace_and_types_cross_session() {
    let store = setup();
    let cr1 = store
        .create_session("claude-opus-4-6", "/tmp/proj", None, None, None, None)
        .unwrap();
    let cr2 = store
        .create_session("claude-opus-4-6", "/tmp/proj", None, None, None, None)
        .unwrap();

    store
        .append(&AppendOptions {
            session_id: &cr1.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "A"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    store
        .append(&AppendOptions {
            session_id: &cr2.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "B"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let result = store
        .get_events_by_workspace_and_types(&cr1.session.workspace_id, &["message.user"], None, None)
        .unwrap();
    assert_eq!(result.len(), 2);
}

#[test]
fn count_events_basic() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/a", None, None, None, None)
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

    let count = store.count_events(&cr.session.id).unwrap();
    assert_eq!(count, 2); // root + user message
}

// ── State projection ──────────────────────────────────────────────

#[test]
fn get_messages_at_head_basic() {
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
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({
                "content": [{"type": "text", "text": "Hi there"}],
                "turn": 1,
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let result = store.get_messages_at_head(&cr.session.id).unwrap();
    assert_eq!(result.messages_with_event_ids.len(), 2);
    assert_eq!(result.messages_with_event_ids[0].message.role, "user");
    assert_eq!(result.messages_with_event_ids[1].message.role, "assistant");
    assert_eq!(result.turn_count, 1);
}

#[test]
fn get_messages_at_head_resolves_blob_backed_event_payloads() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None, None, None)
        .unwrap();
    let content = "large message ".repeat(1024);
    let event = store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": content}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    assert!(
        event
            .payload
            .contains(crate::shared::storage::PAYLOAD_REF_ENVELOPE_KEY)
    );

    let result = store.get_messages_at_head(&cr.session.id).unwrap();
    assert_eq!(result.messages_with_event_ids.len(), 1);
    assert_eq!(
        result.messages_with_event_ids[0].message.content,
        serde_json::Value::String(content)
    );
    let conn = store.pool().get().unwrap();
    let refs: i64 = conn
        .query_row("SELECT COUNT(*) FROM storage_payload_refs", [], |row| {
            row.get(0)
        })
        .unwrap();
    let blobs: i64 = conn
        .query_row("SELECT COUNT(*) FROM blobs", [], |row| row.get(0))
        .unwrap();
    let fetched = EventRepo::get_by_id(&conn, &event.id).unwrap().unwrap();
    assert!(
        fetched
            .payload
            .contains(crate::shared::storage::PAYLOAD_REF_ENVELOPE_KEY)
    );
    assert!(refs >= 1);
    assert_eq!(blobs, 1);
}

#[test]
fn resolve_event_payloads_expands_blob_backed_capability_events() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None, None, None)
        .unwrap();
    let large_content = "inspect result ".repeat(2048);
    let event = store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::CapabilityInvocationCompleted,
            payload: serde_json::json!({
                "invocationId": "call_inspect",
                "modelPrimitiveName": "inspect",
                "content": large_content,
                "isError": false,
                "duration": 33
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    assert!(
        event
            .payload
            .contains(crate::shared::storage::PAYLOAD_REF_ENVELOPE_KEY)
    );

    let payloads = store.resolve_event_payloads(&[event]).unwrap();

    assert_eq!(payloads[0]["invocationId"], "call_inspect");
    assert_eq!(payloads[0]["modelPrimitiveName"], "inspect");
    assert_eq!(payloads[0]["content"], large_content);
    assert!(
        payloads[0]
            .get(crate::shared::storage::PAYLOAD_REF_ENVELOPE_KEY)
            .is_none()
    );
}

#[test]
fn get_messages_at_specific_event() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None, None, None)
        .unwrap();
    let user_evt = store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "Hello"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({
                "content": [{"type": "text", "text": "Hi"}],
                "turn": 1,
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    // Reconstruct at user message event (before assistant response)
    let result = store.get_messages_at(&user_evt.id).unwrap();
    assert_eq!(result.messages_with_event_ids.len(), 1);
    assert_eq!(result.messages_with_event_ids[0].message.role, "user");
}

#[test]
fn get_messages_at_nonexistent_fails() {
    let store = setup();
    let result = store.get_messages_at("evt_nonexistent");
    assert!(result.is_err());
}

#[test]
fn get_state_at_head_basic() {
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
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({
                "content": [{"type": "text", "text": "Hi"}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 100, "outputTokens": 50}
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
                "tokenUsage": {"inputTokens": 100, "outputTokens": 50}
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let state = store.get_state_at_head(&cr.session.id).unwrap();
    assert_eq!(state.session_id, cr.session.id);
    assert_eq!(state.model, "claude-opus-4-6");
    assert_eq!(state.working_directory, "/tmp/project");
    assert_eq!(state.messages_with_event_ids.len(), 2);
    assert_eq!(state.turn_count, 1);
    assert_eq!(state.token_usage.input_tokens, 100);
    assert_eq!(state.token_usage.output_tokens, 50);
    assert!(state.is_ended.is_none()); // session is active
}

#[test]
fn get_state_at_head_ended_session() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None, None, None)
        .unwrap();
    store.end_session(&cr.session.id).unwrap();

    let state = store.get_state_at_head(&cr.session.id).unwrap();
    assert_eq!(state.is_ended, Some(true));
}

#[test]
fn get_state_at_specific_event() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None, None, None)
        .unwrap();
    let user_evt = store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "Hello"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({
                "content": [{"type": "text", "text": "Hi"}],
                "turn": 1,
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let state = store.get_state_at(&cr.session.id, &user_evt.id).unwrap();
    assert_eq!(state.head_event_id, user_evt.id);
    assert_eq!(state.messages_with_event_ids.len(), 1);
    assert_eq!(state.messages_with_event_ids[0].message.role, "user");
}

#[test]
fn get_state_at_head_nonexistent_session_fails() {
    let store = setup();
    let result = store.get_state_at_head("sess_nonexistent");
    assert!(result.is_err());
}

#[test]
fn get_state_at_head_with_agentic_loop() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None, None, None)
        .unwrap();

    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "Use a capability"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({
                "content": [{"type": "capability_invocation", "id": "c1", "name": "process::run", "arguments": {}}],
                "turn": 1,
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::CapabilityInvocationCompleted,
            payload: serde_json::json!({"invocationId": "c1", "content": "output", "isError": false}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({
                "content": [{"type": "text", "text": "Done"}],
                "turn": 2,
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let state = store.get_state_at_head(&cr.session.id).unwrap();
    // user, assistant, capabilityResult, assistant
    assert_eq!(state.messages_with_event_ids.len(), 4);
    assert_eq!(state.messages_with_event_ids[0].message.role, "user");
    assert_eq!(state.messages_with_event_ids[1].message.role, "assistant");
    assert_eq!(
        state.messages_with_event_ids[2].message.role,
        "capabilityResult"
    );
    assert_eq!(state.messages_with_event_ids[3].message.role, "assistant");
}

#[test]
fn get_state_at_head_with_compaction() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None, None, None)
        .unwrap();

    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "Old message"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::CompactSummary,
            payload: serde_json::json!({"summary": "User said hello"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "New message"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let state = store.get_state_at_head(&cr.session.id).unwrap();
    // synthetic user (summary), synthetic assistant (ack), new user
    assert_eq!(state.messages_with_event_ids.len(), 3);
    assert!(
        state.messages_with_event_ids[0]
            .message
            .content
            .as_str()
            .unwrap()
            .contains("Context from earlier")
    );
    assert_eq!(
        state.messages_with_event_ids[2].message.content,
        "New message"
    );
}

// ── Helpers ───────────────────────────────────────────────────────

#[test]
fn event_rows_to_session_events_converts_correctly() {
    let row = EventRow {
        id: "evt_1".to_string(),
        session_id: "sess_1".to_string(),
        parent_id: None,
        sequence: 0,
        depth: 0,
        event_type: "session.start".to_string(),
        timestamp: "2025-01-01T00:00:00Z".to_string(),
        payload: r#"{"model":"claude-opus-4-6"}"#.to_string(),
        content_blob_id: None,
        workspace_id: "ws_1".to_string(),
        role: None,
        model_primitive_name: None,
        invocation_id: None,
        turn: None,
        input_tokens: None,
        output_tokens: None,
        cache_read_tokens: None,
        cache_creation_tokens: None,
        checksum: None,
        model: None,
        latency_ms: None,
        stop_reason: None,
        has_thinking: None,
        provider_type: None,
        cost: None,
    };

    let events = super::event_rows_to_session_events(&[row]);
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].id, "evt_1");
    assert_eq!(events[0].event_type, EventType::SessionStart);
    assert_eq!(events[0].payload["model"], "claude-opus-4-6");
}

#[test]
fn event_rows_to_session_events_handles_invalid_json() {
    let row = EventRow {
        id: "evt_1".to_string(),
        session_id: "sess_1".to_string(),
        parent_id: None,
        sequence: 0,
        depth: 0,
        event_type: "message.user".to_string(),
        timestamp: "2025-01-01T00:00:00Z".to_string(),
        payload: "not-json".to_string(),
        content_blob_id: None,
        workspace_id: "ws_1".to_string(),
        role: None,
        model_primitive_name: None,
        invocation_id: None,
        turn: None,
        input_tokens: None,
        output_tokens: None,
        cache_read_tokens: None,
        cache_creation_tokens: None,
        checksum: None,
        model: None,
        latency_ms: None,
        stop_reason: None,
        has_thinking: None,
        provider_type: None,
        cost: None,
    };

    let events = super::event_rows_to_session_events(&[row]);
    assert_eq!(events.len(), 1);
    assert!(events[0].payload.is_null());
}

#[test]
fn event_rows_to_session_events_skips_unknown_event_types() {
    // Regression: previously an unknown event_type silently became
    // EventType::SessionStart, which would misclassify the row during
    // reconstruction. Now the row is dropped and logged as corrupt.
    let unknown = EventRow {
        id: "evt_bad".to_string(),
        session_id: "sess_1".to_string(),
        parent_id: None,
        sequence: 0,
        depth: 0,
        event_type: "some.unknown.event.type".to_string(),
        timestamp: "2025-01-01T00:00:00Z".to_string(),
        payload: "{}".to_string(),
        content_blob_id: None,
        workspace_id: "ws_1".to_string(),
        role: None,
        model_primitive_name: None,
        invocation_id: None,
        turn: None,
        input_tokens: None,
        output_tokens: None,
        cache_read_tokens: None,
        cache_creation_tokens: None,
        checksum: None,
        model: None,
        latency_ms: None,
        stop_reason: None,
        has_thinking: None,
        provider_type: None,
        cost: None,
    };
    let good = EventRow {
        id: "evt_good".to_string(),
        session_id: "sess_1".to_string(),
        parent_id: None,
        sequence: 1,
        depth: 0,
        event_type: "message.user".to_string(),
        timestamp: "2025-01-01T00:00:00Z".to_string(),
        payload: "{}".to_string(),
        content_blob_id: None,
        workspace_id: "ws_1".to_string(),
        role: None,
        model_primitive_name: None,
        invocation_id: None,
        turn: None,
        input_tokens: None,
        output_tokens: None,
        cache_read_tokens: None,
        cache_creation_tokens: None,
        checksum: None,
        model: None,
        latency_ms: None,
        stop_reason: None,
        has_thinking: None,
        provider_type: None,
        cost: None,
    };

    let events = super::event_rows_to_session_events(&[unknown, good]);
    assert_eq!(events.len(), 1, "unknown event type row must be filtered");
    assert_eq!(events[0].id, "evt_good", "only the valid row survives");
    assert_eq!(events[0].event_type, EventType::MessageUser);
}
