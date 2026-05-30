use super::*;

// ── Activity summary queries ─────────────────────────────────────

#[test]
fn get_activity_summary_empty_session() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/a", None, None, None, None)
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
        .create_session("claude-opus-4-6", "/tmp/a", None, None, None, None)
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
        .create_session("claude-opus-4-6", "/tmp/a", None, None, None, None)
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
        .create_session("claude-opus-4-6", "/tmp/a", None, None, None, None)
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
        .create_session("claude-opus-4-6", "/tmp/a", None, None, None, None)
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
        .create_session("claude-opus-4-6", "/tmp/a", None, None, None, None)
        .unwrap();
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({"content": [
                {"type": "capability_invocation", "id": "call_1", "name": "filesystem::read_file", "input": {"path": "/foo.rs"}}
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
    assert_eq!(
        lines[0].model_primitive_name.as_deref(),
        Some("filesystem::read_file")
    );
    assert_eq!(lines[0].duration_ms, Some(150));
    assert_eq!(lines[0].is_error, Some(false));
    assert!(lines[0].capability_args.is_some());
    let args = lines[0].capability_args.as_ref().unwrap();
    assert_eq!(args["path"], "/foo.rs");
}

#[test]
fn get_activity_summary_capability_invocation_no_result() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/a", None, None, None, None)
        .unwrap();
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({"content": [
                {"type": "capability_invocation", "id": "call_99", "name": "process::run", "input": {"command": "ls"}}
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
    assert_eq!(
        lines[0].model_primitive_name.as_deref(),
        Some("process::run")
    );
    assert!(lines[0].duration_ms.is_none());
    assert!(lines[0].is_error.is_none());
}

#[test]
fn get_activity_summary_spawn_subagent_skipped() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/a", None, None, None, None)
        .unwrap();
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({"content": [
                {"type": "capability_invocation", "id": "call_1", "name": "agent::spawn_subagent", "input": {"task": "do stuff"}},
                {"type": "capability_invocation", "id": "call_2", "name": "filesystem::read_file", "input": {"path": "/bar.rs"}}
            ]}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let lines = store
        .get_session_activity_summaries(&cr.session.id)
        .unwrap();
    assert_eq!(lines.len(), 1);
    assert_eq!(
        lines[0].model_primitive_name.as_deref(),
        Some("filesystem::read_file")
    );
}

#[test]
fn get_activity_summary_subagent_lifecycle() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/a", None, None, None, None)
        .unwrap();

    // Spawn a user-visible subagent (has invocationId in payload)
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::SubagentSpawned,
            payload: serde_json::json!({
                "subagentSessionId": "sub1",
                "task": "Review code",
                "invocationId": "tc_1",
                "spawnType": "blocking",
                "model": "claude-opus-4-6",
                "workingDirectory": "/tmp"
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    // Complete it
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::SubagentCompleted,
            payload: serde_json::json!({
                "subagentSessionId": "sub1",
                "totalTurns": 3,
                "duration": 5000,
                "resultSummary": "Done",
                "totalTokenUsage": {"inputTokens": 100, "outputTokens": 50}
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let lines = store
        .get_session_activity_summaries(&cr.session.id)
        .unwrap();
    // Spawn should be replaced by completion
    assert_eq!(lines.len(), 1);
    assert_eq!(lines[0].kind, "subagentDone");
    assert_eq!(lines[0].text.as_deref(), Some("Agent complete (3 turns)"));
    assert_eq!(lines[0].duration_ms, Some(5000));
    assert_eq!(lines[0].turns, Some(3));
}

#[test]
fn get_activity_summary_hook_subagent_filtered() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/a", None, None, None, None)
        .unwrap();

    // Hook subagent: invocationId is null in payload → invocation_id IS NULL on EventRow
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::SubagentSpawned,
            payload: serde_json::json!({
                "subagentSessionId": "hook_sub",
                "task": "Generate title",
                "spawnType": "hook",
                "model": "claude-haiku-4-5-20251001",
                "workingDirectory": "/tmp"
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    // Hook subagent completes — should be filtered out
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::SubagentCompleted,
            payload: serde_json::json!({
                "subagentSessionId": "hook_sub",
                "totalTurns": 1,
                "duration": 200,
                "resultSummary": "Title: test",
                "totalTokenUsage": {"inputTokens": 10, "outputTokens": 5}
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let lines = store
        .get_session_activity_summaries(&cr.session.id)
        .unwrap();
    assert!(
        lines.is_empty(),
        "Hook subagent events should be filtered out"
    );
}

#[test]
fn get_activity_summary_returns_last_5() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/a", None, None, None, None)
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
        .create_session("claude-opus-4-6", "/tmp/a", None, None, None, None)
        .unwrap();
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({"content": [
                {"type": "text", "text": "Let me read the file"},
                {"type": "capability_invocation", "id": "c1", "name": "filesystem::read_file", "input": {"path": "a.rs"}},
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
    assert_eq!(
        lines[1].model_primitive_name.as_deref(),
        Some("filesystem::read_file")
    );
    assert_eq!(lines[2].kind, "text");
    assert_eq!(lines[2].text.as_deref(), Some("Now I see the issue"));
}

#[test]
fn get_activity_summary_multiple_turns() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/a", None, None, None, None)
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
