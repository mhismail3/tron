use super::*;

// ── Compaction ───────────────────────────────────────────────────

#[test]
fn compaction_clears_and_injects_synthetic_pair() {
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Old message"}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "text", "text": "Old response"}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 30, "outputTokens": 15}
            }),
        ),
        ev(
            EventType::CompactSummary,
            serde_json::json!({"summary": "Previous conversation summary"}),
        ),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "New message"}),
        ),
    ];

    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);

    // synthetic user (summary), synthetic assistant, real user
    assert_eq!(msgs.len(), 3);
    assert_eq!(msgs[0].role, "user");
    assert!(
        msgs[0]
            .content
            .as_str()
            .unwrap()
            .contains("Context from earlier")
    );
    assert!(
        msgs[0]
            .content
            .as_str()
            .unwrap()
            .contains("Previous conversation summary")
    );
    assert_eq!(msgs[1].role, "assistant");
    assert_eq!(msgs[2].role, "user");
    assert_eq!(msgs[2].content, "New message");
}

#[test]
fn compaction_synthetic_messages_have_none_event_ids() {
    let events = vec![
        session_start(),
        ev(
            EventType::CompactSummary,
            serde_json::json!({"summary": "Summary text"}),
        ),
    ];

    let result = reconstruct_from_events(&events);

    assert_eq!(result.messages_with_event_ids.len(), 2);
    assert_eq!(result.messages_with_event_ids[0].event_ids, vec![None]);
    assert_eq!(result.messages_with_event_ids[1].event_ids, vec![None]);
}

#[test]
fn compaction_clears_pending_capability_results() {
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Use capability"}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "capability_invocation", "id": "call_1", "name": "execute", "arguments": {}}],
                "turn": 1,
            }),
        ),
        ev(
            EventType::CapabilityInvocationCompleted,
            serde_json::json!({"invocationId": "call_1", "content": "Result", "isError": false}),
        ),
        // Compaction clears everything including pending capability results
        ev(
            EventType::CompactSummary,
            serde_json::json!({"summary": "Summary"}),
        ),
    ];

    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);

    // Only synthetic pair (no lingering capability result)
    assert_eq!(msgs.len(), 2);
    assert_eq!(msgs[0].role, "user");
    assert_eq!(msgs[1].role, "assistant");
}

// ── Context cleared ──────────────────────────────────────────────

#[test]
fn context_cleared_discards_all_messages() {
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Old message"}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "text", "text": "Old response"}],
                "turn": 1,
            }),
        ),
        ev(EventType::ContextCleared, serde_json::json!({})),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Fresh start"}),
        ),
    ];

    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);

    // Only the post-clear message
    assert_eq!(msgs.len(), 1);
    assert_eq!(msgs[0].role, "user");
    assert_eq!(msgs[0].content, "Fresh start");
}

// ── Message deletion ─────────────────────────────────────────────

#[test]
fn deleted_message_excluded() {
    let user_evt = ev_with_id(
        "evt_user",
        EventType::MessageUser,
        serde_json::json!({"content": "Delete me"}),
    );
    let events = vec![
        session_start(),
        user_evt,
        ev(
            EventType::MessageDeleted,
            serde_json::json!({"targetEventId": "evt_user"}),
        ),
    ];

    let result = reconstruct_from_events(&events);
    assert!(result.messages_with_event_ids.is_empty());
}

#[test]
fn deletion_only_affects_targeted_event() {
    let e1 = ev_with_id(
        "evt_keep",
        EventType::MessageUser,
        serde_json::json!({"content": "Keep me"}),
    );
    let e2 = ev_with_id(
        "evt_delete",
        EventType::MessageUser,
        serde_json::json!({"content": "Delete me"}),
    );
    let events = vec![
        session_start(),
        e1,
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "text", "text": "Response"}],
                "turn": 1,
            }),
        ),
        e2,
        ev(
            EventType::MessageDeleted,
            serde_json::json!({"targetEventId": "evt_delete"}),
        ),
    ];

    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);

    // user (kept), assistant — the second user msg is deleted
    assert_eq!(msgs.len(), 2);
    assert_eq!(msgs[0].content, "Keep me");
}

// ── Token usage ──────────────────────────────────────────────────

#[test]
fn token_usage_accumulation() {
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Hello"}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "text", "text": "Hi"}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 100, "outputTokens": 50, "cacheReadTokens": 10}
            }),
        ),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "More"}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "text", "text": "More response"}],
                "turn": 2,
                "tokenUsage": {"inputTokens": 150, "outputTokens": 75, "cacheCreationTokens": 20}
            }),
        ),
    ];

    let result = reconstruct_from_events(&events);

    assert_eq!(result.token_usage.input_tokens, 250);
    assert_eq!(result.token_usage.output_tokens, 125);
    assert_eq!(result.token_usage.cache_read_tokens, 10);
    assert_eq!(result.token_usage.cache_creation_tokens, 20);
}

#[test]
fn token_usage_from_user_messages() {
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({
                "content": "Hello",
                "tokenUsage": {"inputTokens": 5, "outputTokens": 0}
            }),
        ),
    ];

    let result = reconstruct_from_events(&events);
    assert_eq!(result.token_usage.input_tokens, 5);
}

#[test]
fn token_usage_defaults_to_zero() {
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Hello"}),
        ),
    ];

    let result = reconstruct_from_events(&events);
    assert_eq!(result.token_usage.input_tokens, 0);
    assert_eq!(result.token_usage.output_tokens, 0);
    assert_eq!(result.token_usage.cache_read_tokens, 0);
    assert_eq!(result.token_usage.cache_creation_tokens, 0);
}

// ── Capability argument restoration ────────────────────────────────────

#[test]
fn restore_truncated_capability_arguments() {
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Run capability"}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{
                    "type": "capability_invocation",
                    "id": "call_1",
                    "name": "BigTool",
                    "arguments": {"_truncated": true}
                }],
                "turn": 1,
                "tokenUsage": {"inputTokens": 55, "outputTokens": 22}
            }),
        ),
        ev(
            EventType::CapabilityInvocationStarted,
            serde_json::json!({
                "invocationId": "call_1",
                "name": "BigTool",
                "arguments": {"largeArg": "Full argument value"}
            }),
        ),
        ev(
            EventType::CapabilityInvocationCompleted,
            serde_json::json!({"invocationId": "call_1", "content": "Done", "isError": false}),
        ),
    ];

    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);

    // Assistant message should have restored arguments
    let capability_invocation = &msgs[1].content[0];
    assert_eq!(
        capability_invocation["arguments"]["largeArg"],
        "Full argument value"
    );
    // _truncated should be gone
    assert!(
        capability_invocation["arguments"]
            .get("_truncated")
            .is_none()
    );
}

#[test]
fn non_truncated_capability_invocation_unchanged() {
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Run capability"}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{
                    "type": "capability_invocation",
                    "id": "call_1",
                    "name": "execute",
                    "arguments": {"arg": "value"}
                }],
                "turn": 1,
            }),
        ),
    ];

    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);

    let capability_invocation = &msgs[1].content[0];
    assert_eq!(capability_invocation["arguments"]["arg"], "value");
}

// ── Reasoning level ──────────────────────────────────────────────

#[test]
fn reasoning_level_from_config() {
    let events = vec![
        session_start(),
        ev(
            EventType::ConfigReasoningLevel,
            serde_json::json!({"newLevel": "high"}),
        ),
    ];

    let result = reconstruct_from_events(&events);
    assert_eq!(result.reasoning_level.as_deref(), Some("high"));
}

#[test]
fn reasoning_level_last_wins() {
    let events = vec![
        session_start(),
        ev(
            EventType::ConfigReasoningLevel,
            serde_json::json!({"newLevel": "low"}),
        ),
        ev(
            EventType::ConfigReasoningLevel,
            serde_json::json!({"newLevel": "medium"}),
        ),
        ev(
            EventType::ConfigReasoningLevel,
            serde_json::json!({"newLevel": "xhigh"}),
        ),
    ];

    let result = reconstruct_from_events(&events);
    assert_eq!(result.reasoning_level.as_deref(), Some("xhigh"));
}

// ── System prompt ────────────────────────────────────────────────

#[test]
fn system_prompt_from_session_start() {
    let events = vec![ev(
        EventType::SessionStart,
        serde_json::json!({
            "workingDirectory": "/test",
            "model": "claude-opus-4-6",
            "systemPrompt": "You are a helpful assistant."
        }),
    )];

    let result = reconstruct_from_events(&events);
    assert_eq!(
        result.system_prompt.as_deref(),
        Some("You are a helpful assistant.")
    );
}

#[test]
fn system_prompt_from_config_prompt_update() {
    let events = vec![
        session_start(),
        ev(
            EventType::ConfigPromptUpdate,
            serde_json::json!({"newHash": "abc123", "contentBlobId": "blob_1"}),
        ),
    ];

    let result = reconstruct_from_events(&events);
    assert_eq!(
        result.system_prompt.as_deref(),
        Some("[Updated prompt - hash: abc123]")
    );
}

#[test]
fn system_prompt_not_updated_without_blob_id() {
    let events = vec![
        ev(
            EventType::SessionStart,
            serde_json::json!({
                "workingDirectory": "/test",
                "model": "claude-opus-4-6",
                "systemPrompt": "Original"
            }),
        ),
        ev(
            EventType::ConfigPromptUpdate,
            serde_json::json!({"newHash": "abc123"}),
        ),
    ];

    let result = reconstruct_from_events(&events);
    assert_eq!(result.system_prompt.as_deref(), Some("Original"));
}

// ── Turn count ───────────────────────────────────────────────────

#[test]
fn turn_count_highest_turn_seen() {
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Hello"}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "text", "text": "Hi"}],
                "turn": 1,
            }),
        ),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "More"}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "text", "text": "More response"}],
                "turn": 5,
            }),
        ),
    ];

    let result = reconstruct_from_events(&events);
    assert_eq!(result.turn_count, 5);
}

// ── Complex agentic loop ─────────────────────────────────────────

#[test]
fn complex_agentic_loop() {
    let events = vec![
        session_start(),
        // User asks
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Run multiple capabilities"}),
        ),
        // Assistant calls first capability
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "capability_invocation", "id": "call_1", "name": "process::run", "arguments": {"command": "ls"}}],
                "turn": 1,
            }),
        ),
        ev(
            EventType::CapabilityInvocationStarted,
            serde_json::json!({"invocationId": "call_1", "name": "process::run", "arguments": {"command": "ls"}}),
        ),
        ev(
            EventType::CapabilityInvocationCompleted,
            serde_json::json!({"invocationId": "call_1", "content": "file1.txt", "isError": false}),
        ),
        // Assistant calls second capability
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "capability_invocation", "id": "call_2", "name": "filesystem::read_file", "arguments": {"path": "file1.txt"}}],
                "turn": 2,
            }),
        ),
        ev(
            EventType::CapabilityInvocationStarted,
            serde_json::json!({"invocationId": "call_2", "name": "filesystem::read_file", "arguments": {"path": "file1.txt"}}),
        ),
        ev(
            EventType::CapabilityInvocationCompleted,
            serde_json::json!({"invocationId": "call_2", "content": "Hello World", "isError": false}),
        ),
        // Assistant gives final answer
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "text", "text": "The file contains Hello World."}],
                "turn": 3,
            }),
        ),
    ];

    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);

    // user, assistant(capability_invocation), capabilityResult, assistant(capability_invocation), capabilityResult, assistant(text)
    assert_eq!(msgs.len(), 6);
    assert_eq!(msgs[0].role, "user");
    assert_eq!(msgs[1].role, "assistant");
    assert_eq!(msgs[2].role, "capabilityResult");
    assert_eq!(msgs[3].role, "assistant");
    assert_eq!(msgs[4].role, "capabilityResult");
    assert_eq!(msgs[5].role, "assistant");
    assert_eq!(msgs[5].content[0]["text"], "The file contains Hello World.");
}
