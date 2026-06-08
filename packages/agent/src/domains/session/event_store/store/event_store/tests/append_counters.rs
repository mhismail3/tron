use super::*;

// ── Event appending ───────────────────────────────────────────────

#[test]
fn append_basic() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None)
        .unwrap();

    let event = store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "Hello"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    assert!(event.id.starts_with("evt_"));
    assert_eq!(event.session_id, cr.session.id);
    assert_eq!(event.event_type, "message.user");
    assert_eq!(event.sequence, 1);
    assert_eq!(event.depth, 1);
    assert_eq!(event.parent_id.as_deref(), Some(cr.root_event.id.as_str()));
}

#[test]
fn append_chains_from_head() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None)
        .unwrap();

    let evt1 = store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "Hello"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let evt2 = store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({"content": "Hi there!"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    assert_eq!(evt2.parent_id.as_deref(), Some(evt1.id.as_str()));
    assert_eq!(evt2.sequence, 2);
}

#[test]
fn append_updates_session_head() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None)
        .unwrap();

    let event = store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "Hello"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let session = store.get_session(&cr.session.id).unwrap().unwrap();
    assert_eq!(session.head_event_id.as_deref(), Some(event.id.as_str()));
}

#[test]
fn append_increments_counters() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None)
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
                "content": "Response",
                "tokenUsage": {
                    "inputTokens": 100,
                    "outputTokens": 50,
                    "cacheReadTokens": 10,
                }
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    // Token counters only count from stream.turn_end, not message.assistant
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::StreamTurnEnd,
            payload: serde_json::json!({
                "tokenUsage": {
                    "inputTokens": 100,
                    "outputTokens": 50,
                    "cacheReadTokens": 10,
                }
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let session = store.get_session(&cr.session.id).unwrap().unwrap();
    assert_eq!(session.event_count, 4); // root + user + assistant + turn_end
    assert_eq!(session.message_count, 2);
    assert_eq!(session.total_input_tokens, 100);
    assert_eq!(session.total_output_tokens, 50);
    assert_eq!(session.total_cache_read_tokens, 10);
}

#[test]
fn last_turn_input_tokens_prefers_context_window_tokens() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None)
        .unwrap();

    // Append assistant message with BOTH tokenUsage.inputTokens AND
    // tokenRecord.computed.contextWindowTokens. The latter should win
    // because it includes cache reads for Anthropic (accurate context fill).
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({
                "content": "Hello",
                "tokenUsage": {
                    "inputTokens": 1000,
                    "outputTokens": 200,
                },
                "tokenRecord": {
                    "computed": {
                        "contextWindowTokens": 5000,
                        "newInputTokens": 1000,
                    }
                }
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let session = store.get_session(&cr.session.id).unwrap().unwrap();
    // Should be 5000 (contextWindowTokens), NOT 1000 (inputTokens)
    assert_eq!(session.last_turn_input_tokens, 5000);
}

#[test]
fn last_turn_input_tokens_requires_canonical_token_record() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None)
        .unwrap();

    // No tokenRecord — tokenUsage is not enough to update context state.
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({
                "content": "Hello",
                "tokenUsage": {
                    "inputTokens": 800,
                    "outputTokens": 100,
                }
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let session = store.get_session(&cr.session.id).unwrap().unwrap();
    assert_eq!(session.last_turn_input_tokens, 0);
}

#[test]
fn last_turn_input_tokens_not_set_for_user_messages() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None)
        .unwrap();

    // User messages should NOT update last_turn_input_tokens even if
    // they somehow have tokenUsage (guard: event_type == MessageAssistant)
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({
                "content": "Hello",
                "tokenUsage": {
                    "inputTokens": 999,
                    "outputTokens": 0,
                }
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let session = store.get_session(&cr.session.id).unwrap().unwrap();
    assert_eq!(session.last_turn_input_tokens, 0); // unchanged from default
}

// ── Token double-counting prevention ────────────────────────────

#[test]
fn token_counters_only_from_stream_turn_end() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None)
        .unwrap();

    // message.assistant with tokenUsage should NOT increment token counters
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({
                "content": "Response",
                "tokenUsage": {
                    "inputTokens": 100,
                    "outputTokens": 50,
                    "cacheReadTokens": 10,
                    "cacheCreationTokens": 5,
                }
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let session = store.get_session(&cr.session.id).unwrap().unwrap();
    assert_eq!(
        session.total_input_tokens, 0,
        "message.assistant should not count tokens"
    );
    assert_eq!(session.total_output_tokens, 0);
    assert_eq!(session.total_cache_read_tokens, 0);
    assert_eq!(session.total_cache_creation_tokens, 0);
    // But message_count and turn_count should still increment
    assert_eq!(session.message_count, 1);
    assert_eq!(session.turn_count, 1);

    // stream.turn_end with same tokenUsage SHOULD increment
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::StreamTurnEnd,
            payload: serde_json::json!({
                "tokenUsage": {
                    "inputTokens": 100,
                    "outputTokens": 50,
                    "cacheReadTokens": 10,
                    "cacheCreationTokens": 5,
                }
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let session = store.get_session(&cr.session.id).unwrap().unwrap();
    assert_eq!(session.total_input_tokens, 100);
    assert_eq!(session.total_output_tokens, 50);
    assert_eq!(session.total_cache_read_tokens, 10);
    assert_eq!(session.total_cache_creation_tokens, 5);
    // turn_end should not affect message/turn counts
    assert_eq!(session.message_count, 1);
    assert_eq!(session.turn_count, 1);
}

#[test]
fn cost_only_from_stream_turn_end() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None)
        .unwrap();

    // message.assistant with cost should NOT increment cost
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({
                "content": "Response",
                "cost": 0.005,
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let session = store.get_session(&cr.session.id).unwrap().unwrap();
    assert!(
        session.total_cost < f64::EPSILON,
        "message.assistant should not count cost"
    );

    // stream.turn_end with cost SHOULD increment
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::StreamTurnEnd,
            payload: serde_json::json!({
                "cost": 0.005,
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let session = store.get_session(&cr.session.id).unwrap().unwrap();
    assert!((session.total_cost - 0.005).abs() < f64::EPSILON);
}

#[test]
fn no_double_counting_with_both_events() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None)
        .unwrap();

    // Simulate a real turn: message.assistant then stream.turn_end with identical tokens
    let token_usage = serde_json::json!({
        "inputTokens": 500,
        "outputTokens": 100,
        "cacheReadTokens": 12000,
        "cacheCreationTokens": 200,
    });

    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({
                "content": "Response",
                "tokenUsage": token_usage,
                "cost": 0.01,
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
                "tokenUsage": token_usage,
                "cost": 0.01,
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let session = store.get_session(&cr.session.id).unwrap().unwrap();
    // Tokens should be counted exactly once (from stream.turn_end only)
    assert_eq!(session.total_input_tokens, 500);
    assert_eq!(session.total_output_tokens, 100);
    assert_eq!(session.total_cache_read_tokens, 12000);
    assert_eq!(session.total_cache_creation_tokens, 200);
    assert!((session.total_cost - 0.01).abs() < f64::EPSILON);
}

#[test]
fn stream_turn_end_without_token_usage_no_counter_change() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None)
        .unwrap();

    // stream.turn_end with no tokenUsage (e.g. capability-only turn)
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::StreamTurnEnd,
            payload: serde_json::json!({}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let session = store.get_session(&cr.session.id).unwrap().unwrap();
    assert_eq!(session.total_input_tokens, 0);
    assert_eq!(session.total_output_tokens, 0);
    assert_eq!(session.total_cache_read_tokens, 0);
    assert_eq!(session.total_cache_creation_tokens, 0);
    assert!(session.total_cost < f64::EPSILON);
}

#[test]
fn events_without_token_usage_dont_affect_counters() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None)
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
            event_type: EventType::CapabilityInvocationCompleted,
            payload: serde_json::json!({"invocationId": "t1", "content": "ok"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let session = store.get_session(&cr.session.id).unwrap().unwrap();
    assert_eq!(session.total_input_tokens, 0);
    assert_eq!(session.total_output_tokens, 0);
}

#[test]
fn last_turn_input_tokens_still_set_on_message_assistant() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None)
        .unwrap();

    // Even though token counters don't increment from message.assistant,
    // last_turn_input_tokens (SET semantics) should still be set
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({
                "content": "Response",
                "tokenUsage": {"inputTokens": 500, "outputTokens": 100},
                "tokenRecord": {
                    "computed": {"contextWindowTokens": 12000}
                }
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let session = store.get_session(&cr.session.id).unwrap().unwrap();
    assert_eq!(session.last_turn_input_tokens, 12000);
    // But token totals should be zero (not counted from message.assistant)
    assert_eq!(session.total_input_tokens, 0);
    assert_eq!(session.total_output_tokens, 0);
}

#[test]
fn multi_turn_no_double_counting() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None)
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
            payload: serde_json::json!({
                "content": "Hi",
                "tokenUsage": {"inputTokens": 100, "outputTokens": 20},
                "cost": 0.001,
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
                "tokenUsage": {"inputTokens": 100, "outputTokens": 20},
                "cost": 0.001,
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    // Turn 2
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "More"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({
                "content": "Sure",
                "tokenUsage": {"inputTokens": 200, "outputTokens": 30},
                "cost": 0.002,
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
                "tokenUsage": {"inputTokens": 200, "outputTokens": 30},
                "cost": 0.002,
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let session = store.get_session(&cr.session.id).unwrap().unwrap();
    // Should be sum of turn_end events only, not doubled
    assert_eq!(session.total_input_tokens, 300);
    assert_eq!(session.total_output_tokens, 50);
    assert!((session.total_cost - 0.003).abs() < f64::EPSILON);
    assert_eq!(session.turn_count, 2);
    assert_eq!(session.message_count, 4); // 2 user + 2 assistant
}

#[test]
fn append_with_explicit_parent() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None)
        .unwrap();

    // Append with explicit parent = root event (not head)
    let evt1 = store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "First"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    // Branch from root, not from evt1
    let evt2 = store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "Branch from root"}),
            parent_id: Some(&cr.root_event.id),
            sequence: None,
        })
        .unwrap();

    assert_eq!(evt2.parent_id.as_deref(), Some(cr.root_event.id.as_str()));
    assert_ne!(evt1.id, evt2.id);
}

#[test]
fn append_to_nonexistent_session_fails() {
    let store = setup();
    let result = store.append(&AppendOptions {
        session_id: "sess_nonexistent",
        event_type: EventType::MessageUser,
        payload: serde_json::json!({"content": "Hello"}),
        parent_id: None,
        sequence: None,
    });
    assert!(result.is_err());
}

// ── Event retrieval ───────────────────────────────────────────────

#[test]
fn get_event() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None)
        .unwrap();

    let event = store.get_event(&cr.root_event.id).unwrap();
    assert!(event.is_some());
    assert_eq!(event.unwrap().event_type, "session.start");
}

#[test]
fn get_events_by_session() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None)
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

    let events = store
        .get_events_by_session(&cr.session.id, &ListEventsOptions::default())
        .unwrap();
    assert_eq!(events.len(), 2); // root + user message
    assert_eq!(events[0].sequence, 0);
    assert_eq!(events[1].sequence, 1);
}

#[test]
fn get_ancestors() {
    let store = setup();
    let cr = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None)
        .unwrap();

    let evt1 = store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "Hello"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let evt2 = store
        .append(&AppendOptions {
            session_id: &cr.session.id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({"content": "Hi"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let ancestors = store.get_ancestors(&evt2.id).unwrap();
    assert_eq!(ancestors.len(), 3); // root → evt1 → evt2
    assert_eq!(ancestors[0].id, cr.root_event.id);
    assert_eq!(ancestors[1].id, evt1.id);
    assert_eq!(ancestors[2].id, evt2.id);
}
