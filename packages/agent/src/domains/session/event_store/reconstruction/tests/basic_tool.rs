use super::*;

// ── Empty input ──────────────────────────────────────────────────

#[test]
fn empty_events_returns_empty() {
    let result = reconstruct_from_events(&[]);
    assert!(result.messages_with_event_ids.is_empty());
    assert_eq!(result.turn_count, 0);
}

#[test]
fn session_start_only_no_messages() {
    let result = reconstruct_from_events(&[session_start()]);
    assert!(result.messages_with_event_ids.is_empty());
}

// ── Basic messages ───────────────────────────────────────────────

#[test]
fn single_user_message() {
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Hello"}),
        ),
    ];
    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);
    assert_eq!(msgs.len(), 1);
    assert_eq!(msgs[0].role, "user");
    assert_eq!(msgs[0].content, "Hello");
}

#[test]
fn user_and_assistant() {
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Hello"}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "text", "text": "Hi there"}],
                "turn": 1,
            }),
        ),
    ];
    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);
    assert_eq!(msgs.len(), 2);
    assert_eq!(msgs[0].role, "user");
    assert_eq!(msgs[1].role, "assistant");
    assert_eq!(msgs[1].content[0]["text"], "Hi there");
    assert_eq!(result.turn_count, 1);
}

// ── Tool result output format ────────────────────────────────────

#[test]
fn tool_results_as_tool_result_messages() {
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Use a tool"}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [
                    {"type": "text", "text": "I will use a tool."},
                    {"type": "tool_invocation", "id": "call_123", "name": "test_tool", "arguments": {"arg": "value"}}
                ],
                "turn": 1,
                "tokenUsage": {"inputTokens": 50, "outputTokens": 25}
            }),
        ),
        ev(
            EventType::ToolInvocationCompleted,
            serde_json::json!({"invocationId": "call_123", "content": "Tool output", "isError": false}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "text", "text": "The tool returned: Tool output"}],
                "turn": 2,
                "tokenUsage": {"inputTokens": 75, "outputTokens": 40}
            }),
        ),
    ];

    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);

    // user, assistant, toolResult, assistant
    assert_eq!(msgs.len(), 4);
    assert_eq!(msgs[0].role, "user");
    assert_eq!(msgs[1].role, "assistant");
    assert_eq!(msgs[2].role, "toolResult");
    assert_eq!(msgs[3].role, "assistant");

    // Verify toolResult format
    assert_eq!(msgs[2].invocation_id.as_deref(), Some("call_123"));
    assert_eq!(msgs[2].content, "Tool output");
    assert_eq!(msgs[2].is_error, Some(false));
}

#[test]
fn tool_result_reconstruction_uses_model_context_content() {
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Use the test tool"}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [
                    {"type": "tool_invocation", "id": "call_123", "name": "test_tool", "arguments": {}}
                ],
                "turn": 1,
            }),
        ),
        ev(
            EventType::ToolInvocationCompleted,
            serde_json::json!({
                "invocationId": "call_123",
                "toolName": "test_tool",
                "content": "display-only target output",
                "modelContextContent": "display-only target output\n[tool evidence]\nidempotencyKey: replay-key\n[/tool evidence]",
                "isError": false,
            }),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "text", "text": "Done"}],
                "turn": 2,
            }),
        ),
    ];

    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);

    assert_eq!(msgs.len(), 4);
    assert_eq!(msgs[2].role, "toolResult");
    assert_eq!(msgs[2].invocation_id.as_deref(), Some("call_123"));
    assert_eq!(
        msgs[2].content,
        "display-only target output\n[tool evidence]\nidempotencyKey: replay-key\n[/tool evidence]"
    );
}

#[test]
fn compact_boundary_drops_results_without_a_remaining_invocation() {
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "compact this context"}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{
                    "type": "tool_invocation",
                    "id": "call_compact",
                    "name": "session_compact",
                    "arguments": {"reason": "manual"}
                }]
            }),
        ),
        ev(
            EventType::ToolInvocationStarted,
            serde_json::json!({
                "invocationId": "call_compact",
                "arguments": {"reason": "manual"}
            }),
        ),
        ev(
            EventType::CompactBoundary,
            serde_json::json!({
                "originalTokens": 100,
                "compactedTokens": 10,
                "reason": "manual",
                "summary": "safe compacted summary"
            }),
        ),
        ev(
            EventType::ToolInvocationCompleted,
            serde_json::json!({
                "invocationId": "call_compact",
                "content": "compact completed",
                "isError": false
            }),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({"content": [{"type": "text", "text": "Compaction recorded."}]}),
        ),
    ];

    let result = reconstruct_from_events(&events);
    let messages = get_messages(&result);
    assert!(messages.iter().all(|message| message.role != "toolResult"));
    assert!(
        messages
            .iter()
            .all(|message| message.content != "compact completed")
    );
    assert!(messages.iter().any(|message| {
        message
            .content
            .to_string()
            .contains("safe compacted summary")
    }));
}

#[test]
fn multiple_tool_results_as_separate_messages() {
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Use multiple tools"}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [
                    {"type": "tool_invocation", "id": "call_1", "name": "test_tool", "arguments": {}},
                    {"type": "tool_invocation", "id": "call_2", "name": "inspect", "arguments": {}}
                ],
                "turn": 1,
                "tokenUsage": {"inputTokens": 60, "outputTokens": 30}
            }),
        ),
        ev(
            EventType::ToolInvocationCompleted,
            serde_json::json!({"invocationId": "call_1", "content": "Result 1", "isError": false}),
        ),
        ev(
            EventType::ToolInvocationCompleted,
            serde_json::json!({"invocationId": "call_2", "content": "Result 2", "isError": true}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "text", "text": "Done"}],
                "turn": 2,
                "tokenUsage": {"inputTokens": 80, "outputTokens": 35}
            }),
        ),
    ];

    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);

    // user, assistant, toolResult, toolResult, assistant
    assert_eq!(msgs.len(), 5);
    assert_eq!(msgs[2].role, "toolResult");
    assert_eq!(msgs[2].invocation_id.as_deref(), Some("call_1"));
    assert_eq!(msgs[2].content, "Result 1");
    assert_eq!(msgs[2].is_error, Some(false));

    assert_eq!(msgs[3].role, "toolResult");
    assert_eq!(msgs[3].invocation_id.as_deref(), Some("call_2"));
    assert_eq!(msgs[3].content, "Result 2");
    assert_eq!(msgs[3].is_error, Some(true));
}

#[test]
fn agentic_loop_flushes_between_turns() {
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Start agentic loop"}),
        ),
        // First tool invocation
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "tool_invocation", "id": "call_1", "name": "test_tool", "arguments": {}}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 45, "outputTokens": 20}
            }),
        ),
        ev(
            EventType::ToolInvocationCompleted,
            serde_json::json!({"invocationId": "call_1", "content": "Result 1", "isError": false}),
        ),
        // Second tool invocation (continuation)
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "tool_invocation", "id": "call_2", "name": "inspect", "arguments": {}}],
                "turn": 2,
                "tokenUsage": {"inputTokens": 65, "outputTokens": 28}
            }),
        ),
        ev(
            EventType::ToolInvocationCompleted,
            serde_json::json!({"invocationId": "call_2", "content": "Result 2", "isError": false}),
        ),
        // Final response
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "text", "text": "All done!"}],
                "turn": 3,
                "tokenUsage": {"inputTokens": 85, "outputTokens": 42}
            }),
        ),
    ];

    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);

    // user, assistant, toolResult, assistant, toolResult, assistant
    assert_eq!(msgs.len(), 6);
    assert_eq!(msgs[0].role, "user");
    assert_eq!(msgs[1].role, "assistant");
    assert_eq!(msgs[2].role, "toolResult");
    assert_eq!(msgs[3].role, "assistant");
    assert_eq!(msgs[4].role, "toolResult");
    assert_eq!(msgs[5].role, "assistant");
}

#[test]
fn tool_results_at_end_of_conversation() {
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Run a tool"}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "tool_invocation", "id": "call_1", "name": "test_tool", "arguments": {}}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 40, "outputTokens": 18}
            }),
        ),
        ev(
            EventType::ToolInvocationCompleted,
            serde_json::json!({"invocationId": "call_1", "content": "Tool finished", "isError": false}),
        ),
        // No more events — simulates mid-agentic-loop resume
    ];

    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);

    // user, assistant, toolResult
    assert_eq!(msgs.len(), 3);
    assert_eq!(msgs[0].role, "user");
    assert_eq!(msgs[1].role, "assistant");
    assert_eq!(msgs[2].role, "toolResult");
    assert_eq!(msgs[2].invocation_id.as_deref(), Some("call_1"));
    assert_eq!(msgs[2].content, "Tool finished");
}

#[test]
fn reconstructed_tool_history_remains_provider_neutral() {
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Read this file"}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{
                    "type": "tool_invocation",
                    "id": "toolu_01tool",
                    "name": "worker_list",
                    "arguments": {"includeRetired": false}
                }],
                "turn": 1
            }),
        ),
        ev(
            EventType::ToolInvocationCompleted,
            serde_json::json!({
                "invocationId": "toolu_01tool",
                "content": "example contents",
                "isError": false,
                "toolName": "worker_list",
                "contractId": "worker_kernel::list",
                "implementationId": "worker.kernel.list",
                "functionId": "worker_kernel::list",
                "pluginId": null,
                "workerId": "worker-kernel",
                "schemaDigest": "sha256:read",
                "catalogRevision": 7,
                "trustTier": "host_primitive",
                "riskLevel": "low",
                "effectClass": "pure_read",
                "traceId": "trace-read",
                "rootInvocationId": "root-read",
                "bindingDecisionId": null
            }),
        ),
    ];

    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);

    assert_eq!(msgs.len(), 3);
    assert_eq!(msgs[0].role, "user");
    assert_eq!(msgs[1].role, "assistant");
    assert_eq!(msgs[1].content[0]["type"], "tool_invocation");
    assert_eq!(msgs[1].content[0]["name"], "worker_list");
    assert_eq!(msgs[1].content[0]["arguments"]["includeRetired"], false);
    assert_eq!(msgs[2].role, "toolResult");
    assert_eq!(msgs[2].invocation_id.as_deref(), Some("toolu_01tool"));
    assert_eq!(msgs[2].content, "example contents");
}

// ── Message merging ──────────────────────────────────────────────

#[test]
fn merge_consecutive_user_messages() {
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "First message"}),
        ),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Second message"}),
        ),
    ];

    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);

    assert_eq!(msgs.len(), 1);
    assert_eq!(msgs[0].role, "user");

    // Content should be merged into array
    let content = msgs[0].content.as_array().unwrap();
    assert_eq!(content.len(), 2);
    assert_eq!(content[0]["text"], "First message");
    assert_eq!(content[1]["text"], "Second message");
}

#[test]
fn merge_consecutive_user_messages_tracks_event_ids() {
    let e1 = ev_with_id(
        "evt_user_1",
        EventType::MessageUser,
        serde_json::json!({"content": "First"}),
    );
    let e2 = ev_with_id(
        "evt_user_2",
        EventType::MessageUser,
        serde_json::json!({"content": "Second"}),
    );
    let events = vec![session_start(), e1, e2];

    let result = reconstruct_from_events(&events);

    assert_eq!(result.messages_with_event_ids.len(), 1);
    let entry = &result.messages_with_event_ids[0];
    assert_eq!(entry.event_ids.len(), 2);
    assert_eq!(entry.event_ids[0].as_deref(), Some("evt_user_1"));
    assert_eq!(entry.event_ids[1].as_deref(), Some("evt_user_2"));
}

#[test]
fn merge_user_messages_with_array_content() {
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": [{"type": "text", "text": "Block A"}]}),
        ),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": [{"type": "text", "text": "Block B"}]}),
        ),
    ];

    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);

    assert_eq!(msgs.len(), 1);
    let content = msgs[0].content.as_array().unwrap();
    assert_eq!(content.len(), 2);
    assert_eq!(content[0]["text"], "Block A");
    assert_eq!(content[1]["text"], "Block B");
}

#[test]
fn user_interrupt_injects_synthetic_tool_result() {
    // When user interrupts after tool invocations, pending results are discarded
    // but synthetic error results are injected to keep provider tool-invocation
    // state well-formed.
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Use tool"}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "tool_invocation", "id": "call_1", "name": "test_tool", "arguments": {}}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 50, "outputTokens": 25}
            }),
        ),
        ev(
            EventType::ToolInvocationCompleted,
            serde_json::json!({"invocationId": "call_1", "content": "Result", "isError": false}),
        ),
        // User interrupts — pending tool results are discarded, but
        // synthetic error results keep provider tool-invocation state well-formed.
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Actually, never mind"}),
        ),
    ];

    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);

    // user, assistant(tool_invocation), toolResult(synthetic), user
    assert_eq!(msgs.len(), 4);
    assert_eq!(msgs[0].role, "user");
    assert_eq!(msgs[1].role, "assistant");
    assert_eq!(msgs[2].role, "toolResult");
    assert_eq!(msgs[2].invocation_id.as_deref(), Some("call_1"));
    assert_eq!(msgs[2].is_error, Some(true));
    assert_eq!(msgs[2].content, "Tool invocation was interrupted.");
    assert_eq!(msgs[3].role, "user");
}
