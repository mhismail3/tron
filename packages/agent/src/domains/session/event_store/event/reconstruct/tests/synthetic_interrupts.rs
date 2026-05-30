use super::*;

// ── Compaction followed by new messages ──────────────────────────

#[test]
fn compaction_then_new_messages() {
    let events = vec![
        session_start(),
        // Pre-compaction messages
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Old question"}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "text", "text": "Old answer"}],
                "turn": 1,
            }),
        ),
        // Compaction
        ev(
            EventType::CompactSummary,
            serde_json::json!({"summary": "User asked a question. Assistant answered."}),
        ),
        // Post-compaction new conversation
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "New question"}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "text", "text": "New answer"}],
                "turn": 2,
                "tokenUsage": {"inputTokens": 200, "outputTokens": 100}
            }),
        ),
    ];

    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);

    // synthetic user, synthetic assistant, new user, new assistant
    assert_eq!(msgs.len(), 4);
    assert!(
        msgs[0]
            .content
            .as_str()
            .unwrap()
            .contains("Context from earlier")
    );
    assert_eq!(msgs[1].role, "assistant");
    assert_eq!(msgs[2].content, "New question");
    assert_eq!(msgs[3].content[0]["text"], "New answer");
}

// ── Event IDs for synthetic messages ─────────────────────────────

#[test]
fn capability_result_messages_have_none_event_ids() {
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Capability"}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "capability_invocation", "id": "call_1", "name": "T", "arguments": {}}],
                "turn": 1,
            }),
        ),
        ev(
            EventType::CapabilityInvocationCompleted,
            serde_json::json!({"invocationId": "call_1", "content": "R", "isError": false}),
        ),
    ];

    let result = reconstruct_from_events(&events);

    // The capabilityResult message should have [None] as event_ids (synthetic)
    let capability_result_entry = &result.messages_with_event_ids[2];
    assert_eq!(capability_result_entry.message.role, "capabilityResult");
    assert_eq!(capability_result_entry.event_ids, vec![None]);
}

// ── Ignored event types ──────────────────────────────────────────

#[test]
fn irrelevant_events_ignored() {
    let events = vec![
        session_start(),
        ev(EventType::StreamTurnStart, serde_json::json!({})),
        ev(EventType::StreamTurnEnd, serde_json::json!({})),
        ev(EventType::SessionFork, serde_json::json!({})),
        ev(EventType::MetadataUpdate, serde_json::json!({})),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Hello"}),
        ),
    ];

    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);

    assert_eq!(msgs.len(), 1);
    assert_eq!(msgs[0].content, "Hello");
}

// ── Helper function tests ────────────────────────────────────────

#[test]
fn normalize_user_content_string() {
    let content = Value::String("hello".to_string());
    let blocks = normalize_user_content(&content);
    assert_eq!(blocks.len(), 1);
    assert_eq!(blocks[0]["type"], "text");
    assert_eq!(blocks[0]["text"], "hello");
}

#[test]
fn normalize_user_content_array() {
    let content = serde_json::json!([{"type": "text", "text": "a"}, {"type": "text", "text": "b"}]);
    let blocks = normalize_user_content(&content);
    assert_eq!(blocks.len(), 2);
}

#[test]
fn normalize_user_content_null() {
    let blocks = normalize_user_content(&Value::Null);
    assert!(blocks.is_empty());
}

#[test]
fn content_has_capability_invocation_true() {
    let content = serde_json::json!([
        {"type": "text", "text": "hi"},
        {"type": "capability_invocation", "id": "call_1", "name": "T", "arguments": {}}
    ]);
    assert!(content_has_capability_invocation(&content));
}

#[test]
fn content_has_capability_invocation_false() {
    let content = serde_json::json!([{"type": "text", "text": "hi"}]);
    assert!(!content_has_capability_invocation(&content));
}

#[test]
fn content_has_capability_invocation_non_array() {
    assert!(!content_has_capability_invocation(&Value::String(
        "hello".to_string()
    )));
}

#[test]
fn restore_truncated_inputs_no_truncation() {
    let content = serde_json::json!([
        {"type": "capability_invocation", "id": "call_1", "arguments": {"arg": "val"}}
    ]);
    let map = std::collections::HashMap::new();
    let result = restore_truncated_inputs(&content, &map);
    assert_eq!(result[0]["arguments"]["arg"], "val");
}

#[test]
fn restore_truncated_inputs_with_truncation() {
    let content = serde_json::json!([
        {"type": "capability_invocation", "id": "call_1", "arguments": {"_truncated": true}}
    ]);
    let mut map = std::collections::HashMap::new();
    map.insert(
        "call_1".to_string(),
        serde_json::json!({"fullArg": "restored"}),
    );
    let result = restore_truncated_inputs(&content, &map);
    assert_eq!(result[0]["arguments"]["fullArg"], "restored");
    assert!(result[0]["arguments"].get("_truncated").is_none());
}

#[test]
fn restore_truncated_inputs_missing_from_map() {
    let content = serde_json::json!([
        {"type": "capability_invocation", "id": "call_unknown", "arguments": {"_truncated": true}}
    ]);
    let map = std::collections::HashMap::new();
    let result = restore_truncated_inputs(&content, &map);
    // Should leave as-is when not in map
    assert_eq!(result[0]["arguments"]["_truncated"], true);
}

// ── Synthetic capability results for interrupted sessions ──────────────

#[test]
fn inject_synthetic_results_on_user_interrupt() {
    // Simulates: assistant makes capability invocations, results arrive, user interrupts.
    // The user interrupt discards pending capability results, leaving unmatched
    // capability_invocation blocks. Synthetic error results should be injected.
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Use capability"}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [
                    {"type": "capability_invocation", "id": "call_1", "name": "execute", "arguments": {}},
                    {"type": "capability_invocation", "id": "call_2", "name": "inspect", "arguments": {}}
                ],
                "turn": 1,
            }),
        ),
        // Capability results arrive but will be discarded by user interrupt
        ev(
            EventType::CapabilityInvocationCompleted,
            serde_json::json!({"invocationId": "call_1", "content": "Result 1", "isError": false}),
        ),
        ev(
            EventType::CapabilityInvocationCompleted,
            serde_json::json!({"invocationId": "call_2", "content": "Result 2", "isError": false}),
        ),
        // User interrupt discards pending capability results
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Never mind"}),
        ),
    ];

    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);

    // user, assistant(capability_invocation x2), capabilityResult(call_1), capabilityResult(call_2), user
    assert_eq!(msgs.len(), 5);
    assert_eq!(msgs[0].role, "user");
    assert_eq!(msgs[1].role, "assistant");
    assert_eq!(msgs[2].role, "capabilityResult");
    assert_eq!(msgs[2].invocation_id.as_deref(), Some("call_1"));
    assert_eq!(msgs[2].is_error, Some(true));
    assert_eq!(msgs[2].content, "Capability invocation was interrupted.");
    assert_eq!(msgs[3].role, "capabilityResult");
    assert_eq!(msgs[3].invocation_id.as_deref(), Some("call_2"));
    assert_eq!(msgs[3].is_error, Some(true));
    assert_eq!(msgs[4].role, "user");
    assert_eq!(msgs[4].content, "Never mind");
}

#[test]
fn inject_synthetic_results_mid_execution() {
    // Session ends after assistant emits capability invocations but before any results arrive.
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Run capability"}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [
                    {"type": "capability_invocation", "id": "call_1", "name": "execute", "arguments": {}}
                ],
                "turn": 1,
            }),
        ),
        // No capability result events — session interrupted mid-execution
    ];

    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);

    // user, assistant(capability_invocation), capabilityResult(synthetic error)
    assert_eq!(msgs.len(), 3);
    assert_eq!(msgs[2].role, "capabilityResult");
    assert_eq!(msgs[2].invocation_id.as_deref(), Some("call_1"));
    assert_eq!(msgs[2].is_error, Some(true));
    assert_eq!(msgs[2].content, "Capability invocation was interrupted.");
}

#[test]
fn no_synthetic_results_when_all_matched() {
    // Normal flow: all capability invocations have matching results. No synthetics needed.
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
            serde_json::json!({"invocationId": "call_1", "content": "Done", "isError": false}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "text", "text": "All done"}],
                "turn": 2,
            }),
        ),
    ];

    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);

    // user, assistant, capabilityResult, assistant — no synthetics
    assert_eq!(msgs.len(), 4);
    assert_eq!(msgs[2].role, "capabilityResult");
    assert_eq!(msgs[2].content, "Done");
    assert_eq!(msgs[2].is_error, Some(false));
}

#[test]
fn partial_capability_results_injects_only_missing() {
    // One of two capability invocations gets a result, the other doesn't.
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Use capabilities"}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [
                    {"type": "capability_invocation", "id": "call_1", "name": "execute", "arguments": {}},
                    {"type": "capability_invocation", "id": "call_2", "name": "inspect", "arguments": {}}
                ],
                "turn": 1,
            }),
        ),
        // Only call_1 gets a result
        ev(
            EventType::CapabilityInvocationCompleted,
            serde_json::json!({"invocationId": "call_1", "content": "Result 1", "isError": false}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "text", "text": "Continuing"}],
                "turn": 2,
            }),
        ),
    ];

    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);

    // user, assistant(capability_invocation x2), synthetic(call_2), capabilityResult(call_1), assistant
    // The synthetic is injected right after assistant, before existing capabilityResults
    assert_eq!(msgs.len(), 5);
    assert_eq!(msgs[1].role, "assistant");
    // Synthetic injected first (for unmatched call_2)
    assert_eq!(msgs[2].role, "capabilityResult");
    assert_eq!(msgs[2].invocation_id.as_deref(), Some("call_2"));
    assert_eq!(msgs[2].is_error, Some(true));
    // Real result for call_1
    assert_eq!(msgs[3].role, "capabilityResult");
    assert_eq!(msgs[3].invocation_id.as_deref(), Some("call_1"));
    assert_eq!(msgs[3].is_error, Some(false));
    assert_eq!(msgs[4].role, "assistant");
}

#[test]
fn cross_provider_resume_with_interrupted_capability_invocations() {
    // Realistic scenario: Anthropic capability invocations completed, then GPT capability invocations interrupted.
    let events = vec![
        session_start(),
        // User prompt
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Help me with files"}),
        ),
        // Anthropic assistant uses capability (completed)
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "capability_invocation", "id": "toolu_abc", "name": "filesystem::read_file", "arguments": {"path": "file.txt"}}],
                "turn": 1,
            }),
        ),
        ev(
            EventType::CapabilityInvocationCompleted,
            serde_json::json!({"invocationId": "toolu_abc", "content": "file contents", "isError": false}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "text", "text": "Here are the contents."}],
                "turn": 2,
            }),
        ),
        // User switches model, sends new prompt
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Now use GPT to do more"}),
        ),
        // GPT assistant uses capabilities (interrupted before results)
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [
                    {"type": "capability_invocation", "id": "call_gpt_1", "name": "filesystem::write_file", "arguments": {"path": "out.txt"}},
                    {"type": "capability_invocation", "id": "call_gpt_2", "name": "process::run", "arguments": {"command": "echo hi"}}
                ],
                "turn": 3,
            }),
        ),
        // Session interrupted — no capability.invocation.completed events for GPT calls
    ];

    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);

    // user, assistant(toolu_abc), capabilityResult(toolu_abc), assistant(text),
    // user, assistant(call_gpt_1, call_gpt_2), capabilityResult(call_gpt_1), capabilityResult(call_gpt_2)
    assert_eq!(msgs.len(), 8);

    // Anthropic calls properly matched
    assert_eq!(msgs[2].role, "capabilityResult");
    assert_eq!(msgs[2].invocation_id.as_deref(), Some("toolu_abc"));
    assert_eq!(msgs[2].is_error, Some(false));

    // GPT calls get synthetic error results
    assert_eq!(msgs[6].role, "capabilityResult");
    assert_eq!(msgs[6].invocation_id.as_deref(), Some("call_gpt_1"));
    assert_eq!(msgs[6].is_error, Some(true));
    assert_eq!(msgs[6].content, "Capability invocation was interrupted.");

    assert_eq!(msgs[7].role, "capabilityResult");
    assert_eq!(msgs[7].invocation_id.as_deref(), Some("call_gpt_2"));
    assert_eq!(msgs[7].is_error, Some(true));
}

// ── Interrupted session persistence scenarios ─────────────────

#[test]
fn interrupted_assistant_with_capability_invocation_gets_synthetic_results() {
    // Server persists partial message.assistant with interrupted=true + capability_invocation.
    // Reconstruction should inject synthetic capability results.
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Do something"}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [
                    {"type": "text", "text": "I'll help with"},
                    {"type": "capability_invocation", "id": "tc_1", "name": "execute", "arguments": {"command": "ls"}}
                ],
                "turn": 1,
                "stopReason": "interrupted",
                "interrupted": true,
            }),
        ),
    ];
    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);

    // user, assistant(text + capability_invocation), synthetic capabilityResult
    assert_eq!(msgs.len(), 3);
    assert_eq!(msgs[0].role, "user");
    assert_eq!(msgs[1].role, "assistant");
    assert_eq!(msgs[2].role, "capabilityResult");
    assert_eq!(msgs[2].invocation_id.as_deref(), Some("tc_1"));
    assert_eq!(msgs[2].is_error, Some(true));
}

#[test]
fn interrupted_text_only_assistant_reconstructs() {
    // Interrupted mid-text, no capability invocations — simpler case.
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Tell me a story"}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [{"type": "text", "text": "Once upon a time"}],
                "turn": 1,
                "stopReason": "interrupted",
                "interrupted": true,
            }),
        ),
    ];
    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);

    // user, assistant(text only) — no synthetic results needed
    assert_eq!(msgs.len(), 2);
    assert_eq!(msgs[0].role, "user");
    assert_eq!(msgs[1].role, "assistant");
    assert_eq!(msgs[1].content[0]["text"], "Once upon a time");
}

#[test]
fn interrupted_session_resume_reconstructs_full_history() {
    // Session interrupted, notification persisted, then user resumes.
    let events = vec![
        session_start(),
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Run capability"}),
        ),
        ev(
            EventType::MessageAssistant,
            serde_json::json!({
                "content": [
                    {"type": "capability_invocation", "id": "tc_1", "name": "execute", "arguments": {}}
                ],
                "turn": 1,
                "stopReason": "interrupted",
                "interrupted": true,
            }),
        ),
        ev(
            EventType::NotificationInterrupted,
            serde_json::json!({
                "timestamp": "2026-02-17T00:00:00Z",
                "turn": 1,
            }),
        ),
        // User resumes
        ev(
            EventType::MessageUser,
            serde_json::json!({"content": "Try again"}),
        ),
    ];
    let result = reconstruct_from_events(&events);
    let msgs = get_messages(&result);

    // user, assistant(capability_invocation), synthetic capabilityResult, user
    assert_eq!(msgs.len(), 4);
    assert_eq!(msgs[0].role, "user");
    assert_eq!(msgs[1].role, "assistant");
    assert_eq!(msgs[2].role, "capabilityResult");
    assert_eq!(msgs[2].is_error, Some(true));
    assert_eq!(msgs[2].invocation_id.as_deref(), Some("tc_1"));
    assert_eq!(msgs[3].role, "user");
    assert_eq!(msgs[3].content, "Try again");
}

#[test]
fn extract_capability_invocation_ids_from_content() {
    let content = serde_json::json!([
        {"type": "text", "text": "hello"},
        {"type": "capability_invocation", "id": "call_1", "name": "T", "arguments": {}},
        {"type": "capability_invocation", "id": "call_2", "name": "T2", "arguments": {}}
    ]);
    let ids = extract_capability_invocation_ids(&content);
    assert_eq!(ids, vec!["call_1", "call_2"]);
}

#[test]
fn extract_capability_invocation_ids_no_capabilities() {
    let content = serde_json::json!([{"type": "text", "text": "hello"}]);
    let ids = extract_capability_invocation_ids(&content);
    assert!(ids.is_empty());
}

#[test]
fn extract_capability_invocation_ids_non_array() {
    let ids = extract_capability_invocation_ids(&Value::String("hello".to_string()));
    assert!(ids.is_empty());
}
