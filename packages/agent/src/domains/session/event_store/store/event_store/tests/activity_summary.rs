use super::*;

// ── Activity summary queries ─────────────────────────────────────

#[test]
fn get_activity_summary_empty_session() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/a", None, None)
        .unwrap();
    let lines = store
        .get_session_activity_summaries(&cr.session.id)
        .unwrap();
    assert!(lines.is_empty());
}

#[test]
fn get_activity_summary_user_prompt_only() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/a", None, None)
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

    let lines = store
        .get_session_activity_summaries(&cr.session.id)
        .unwrap();
    assert_eq!(lines.len(), 1);
    assert_eq!(lines[0].kind, "userPrompt");
    assert_eq!(lines[0].text.as_deref(), Some("What is Rust?"));
}

#[test]
fn get_activity_summary_user_prompt_truncation() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/a", None, None)
        .unwrap();
    let long_text = "a".repeat(150);
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": long_text}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let lines = store
        .get_session_activity_summaries(&cr.session.id)
        .unwrap();
    assert_eq!(lines[0].text.as_ref().unwrap().len(), 100);
}

#[test]
fn get_activity_summary_text_block() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/a", None, None)
        .unwrap();
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({"content": [
                {"type": "text", "text": "I'll help you with that."}
            ]}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let lines = store
        .get_session_activity_summaries(&cr.session.id)
        .unwrap();
    assert_eq!(lines.len(), 1);
    assert_eq!(lines[0].kind, "text");
    assert_eq!(lines[0].text.as_deref(), Some("I'll help you with that."));
}

#[test]
fn get_activity_summary_text_block_multiline() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/a", None, None)
        .unwrap();
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({"content": [
                {"type": "text", "text": "\n\nFirst line here\nSecond line\nThird line"}
            ]}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let lines = store
        .get_session_activity_summaries(&cr.session.id)
        .unwrap();
    assert_eq!(lines[0].text.as_deref(), Some("First line here"));
}

#[test]
fn get_activity_summary_thinking_block() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/a", None, None)
        .unwrap();
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({"content": [
                {"type": "thinking", "thinking": "Let me think about this..."}
            ]}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let lines = store
        .get_session_activity_summaries(&cr.session.id)
        .unwrap();
    assert_eq!(lines.len(), 1);
    assert_eq!(lines[0].kind, "thinking");
}

#[test]
fn get_activity_summary_capability_invocation_with_result() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/a", None, None)
        .unwrap();
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({"content": [
                {"type": "capability_invocation", "id": "call_1", "name": "execute", "input": {"operation": "file_read", "path": "/foo.rs"}}
            ]}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::CapabilityInvocationCompleted,
            payload: serde_json::json!({"invocationId": "call_1", "isError": false, "duration": 150}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let lines = store
        .get_session_activity_summaries(&cr.session.id)
        .unwrap();
    assert_eq!(lines.len(), 1);
    assert_eq!(lines[0].kind, "capability");
    assert_eq!(lines[0].model_primitive_name.as_deref(), Some("execute"));
    assert_eq!(lines[0].duration_ms, Some(150));
    assert_eq!(lines[0].is_error, Some(false));
    assert!(lines[0].capability_args.is_some());
    let args = lines[0].capability_args.as_ref().unwrap();
    assert_eq!(args["operation"], "file_read");
    assert_eq!(args["path"], "/foo.rs");
}

#[test]
fn get_activity_summary_capability_invocation_uses_execute_identity() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/a", None, None)
        .unwrap();
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({"content": [
                {
                    "type": "capability_invocation",
                    "id": "call_1",
                    "name": "execute",
                    "input": {
                        "operation": "process_run",
                        "command": "printf hello"
                    }
                }
            ]}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::CapabilityInvocationCompleted,
            payload: serde_json::json!({
                "invocationId": "call_1",
                "modelPrimitiveName": "execute",
                "operationName": "process_run",
                "traceId": "trace-execute",
                "rootInvocationId": "root-execute",
                "themeColor": "#10B981",
                "presentationHints": {
                    "displayName": "Execute",
                    "summary": "Primitive process operation",
                    "icon": "terminal"
                },
                "isError": false,
                "duration": 150
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let lines = store
        .get_session_activity_summaries(&cr.session.id)
        .unwrap();
    assert_eq!(lines.len(), 1);
    assert_eq!(lines[0].kind, "capability");
    assert_eq!(lines[0].model_primitive_name.as_deref(), Some("execute"));
    assert_eq!(lines[0].operation_name.as_deref(), Some("process_run"));
    assert_eq!(lines[0].trace_id.as_deref(), Some("trace-execute"));
    assert_eq!(lines[0].root_invocation_id.as_deref(), Some("root-execute"));
    assert_eq!(lines[0].theme_color.as_deref(), Some("#10B981"));
    assert_eq!(
        lines[0].summary.as_deref(),
        Some("Primitive process operation")
    );
    assert_eq!(
        lines[0].capability_args.as_ref().unwrap(),
        &serde_json::json!({
            "operation": "process_run",
            "command": "printf hello"
        })
    );
}

#[test]
fn get_activity_summary_capability_invocation_no_result() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/a", None, None)
        .unwrap();
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({"content": [
                {"type": "capability_invocation", "id": "call_99", "name": "execute", "input": {"operation": "process_run", "command": "ls"}}
            ]}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let lines = store
        .get_session_activity_summaries(&cr.session.id)
        .unwrap();
    assert_eq!(lines.len(), 1);
    assert_eq!(lines[0].kind, "capability");
    assert_eq!(lines[0].model_primitive_name.as_deref(), Some("execute"));
    assert!(lines[0].duration_ms.is_none());
    assert!(lines[0].is_error.is_none());
}

#[test]
fn get_activity_summary_returns_last_5() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/a", None, None)
        .unwrap();

    // Create 8 user prompts
    for i in 0..8 {
        store
            .append(&AppendOptions {
                session_id: &cr.session.id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": format!("Prompt {i}")}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
    }

    let lines = store
        .get_session_activity_summaries(&cr.session.id)
        .unwrap();
    assert_eq!(lines.len(), 5);
    assert_eq!(lines[0].text.as_deref(), Some("Prompt 3"));
    assert_eq!(lines[4].text.as_deref(), Some("Prompt 7"));
}

#[test]
fn get_activity_summary_interleaved_content() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/a", None, None)
        .unwrap();
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({"content": [
                {"type": "text", "text": "Let me read the file"},
                {"type": "capability_invocation", "id": "c1", "name": "execute", "input": {"operation": "file_read", "path": "a.rs"}},
                {"type": "text", "text": "Now I see the issue"}
            ]}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let lines = store
        .get_session_activity_summaries(&cr.session.id)
        .unwrap();
    assert_eq!(lines.len(), 3);
    assert_eq!(lines[0].kind, "text");
    assert_eq!(lines[0].text.as_deref(), Some("Let me read the file"));
    assert_eq!(lines[1].kind, "capability");
    assert_eq!(lines[1].model_primitive_name.as_deref(), Some("execute"));
    assert_eq!(lines[2].kind, "text");
    assert_eq!(lines[2].text.as_deref(), Some("Now I see the issue"));
}

#[test]
fn get_activity_summary_multiple_turns() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/a", None, None)
        .unwrap();

    // Turn 1
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
            payload: serde_json::json!({"content": [{"type": "text", "text": "Hi there"}]}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    // Turn 2
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "How are you?"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({"content": [{"type": "text", "text": "I'm doing well"}]}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let lines = store
        .get_session_activity_summaries(&cr.session.id)
        .unwrap();
    assert_eq!(lines.len(), 4);
    assert_eq!(lines[0].kind, "userPrompt");
    assert_eq!(lines[0].text.as_deref(), Some("Hello"));
    assert_eq!(lines[1].kind, "text");
    assert_eq!(lines[1].text.as_deref(), Some("Hi there"));
    assert_eq!(lines[2].kind, "userPrompt");
    assert_eq!(lines[2].text.as_deref(), Some("How are you?"));
    assert_eq!(lines[3].kind, "text");
    assert_eq!(lines[3].text.as_deref(), Some("I'm doing well"));
}
