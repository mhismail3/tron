use super::*;

// ── Per-turn metadata extraction ────────────────────────────────

#[test]
fn extract_model_from_payload() {
    let conn = setup();
    let event = make_event(
        "evt_1",
        1,
        EventType::MessageAssistant,
        None,
        json!({
            "content": "hello",
            "model": "claude-opus-4-6"
        }),
    );
    EventRepo::insert(&conn, &event).unwrap();

    let row = EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap();
    assert_eq!(row.model.as_deref(), Some("claude-opus-4-6"));
}

#[test]
fn extract_latency_from_payload() {
    let conn = setup();
    let event = make_event(
        "evt_1",
        1,
        EventType::MessageAssistant,
        None,
        json!({
            "content": "hello",
            "latency": 1234
        }),
    );
    EventRepo::insert(&conn, &event).unwrap();

    let row = EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap();
    assert_eq!(row.latency_ms, Some(1234));
}

#[test]
fn extract_stop_reason_from_payload() {
    let conn = setup();
    let event = make_event(
        "evt_1",
        1,
        EventType::MessageAssistant,
        None,
        json!({
            "content": "hello",
            "stopReason": "end_turn"
        }),
    );
    EventRepo::insert(&conn, &event).unwrap();

    let row = EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap();
    assert_eq!(row.stop_reason.as_deref(), Some("end_turn"));
}

#[test]
fn extract_has_thinking_bool_from_payload() {
    let conn = setup();
    let event = make_event(
        "evt_1",
        1,
        EventType::MessageAssistant,
        None,
        json!({
            "content": "hello",
            "hasThinking": true
        }),
    );
    EventRepo::insert(&conn, &event).unwrap();

    let row = EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap();
    assert_eq!(row.has_thinking, Some(1));
}

#[test]
fn extract_has_thinking_false_from_payload() {
    let conn = setup();
    let event = make_event(
        "evt_1",
        1,
        EventType::MessageAssistant,
        None,
        json!({
            "content": "hello",
            "hasThinking": false
        }),
    );
    EventRepo::insert(&conn, &event).unwrap();

    let row = EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap();
    assert_eq!(row.has_thinking, Some(0));
}

#[test]
fn extract_provider_type_from_payload() {
    let conn = setup();
    let event = make_event(
        "evt_1",
        1,
        EventType::MessageAssistant,
        None,
        json!({
            "content": "hello",
            "providerType": "google"
        }),
    );
    EventRepo::insert(&conn, &event).unwrap();

    let row = EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap();
    assert_eq!(row.provider_type.as_deref(), Some("google"));
}

#[test]
fn extract_cost_from_payload() {
    let conn = setup();
    let event = make_event(
        "evt_1",
        1,
        EventType::MessageAssistant,
        None,
        json!({
            "content": "hello",
            "cost": 0.0042
        }),
    );
    EventRepo::insert(&conn, &event).unwrap();

    let row = EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap();
    let cost = row.cost.unwrap();
    assert!(
        (cost - 0.0042).abs() < f64::EPSILON,
        "cost should be ~0.0042, got {cost}"
    );
}

#[test]
fn new_columns_null_when_not_in_payload() {
    let conn = setup();
    let event = make_event(
        "evt_1",
        1,
        EventType::MessageUser,
        None,
        json!({"content": "hi"}),
    );
    EventRepo::insert(&conn, &event).unwrap();

    let row = EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap();
    assert!(
        row.model.is_none(),
        "model should be None for user messages"
    );
    assert!(row.latency_ms.is_none(), "latency_ms should be None");
    assert!(row.stop_reason.is_none(), "stop_reason should be None");
    assert!(row.has_thinking.is_none(), "has_thinking should be None");
    assert!(row.provider_type.is_none(), "provider_type should be None");
    assert!(row.cost.is_none(), "cost should be None");
}

#[test]
fn extract_all_per_turn_fields_together() {
    let conn = setup();
    let event = make_event(
        "evt_1",
        1,
        EventType::MessageAssistant,
        None,
        json!({
            "content": "thinking response",
            "model": "claude-opus-4-6",
            "latency": 2500,
            "stopReason": "end_turn",
            "hasThinking": true,
            "providerType": "anthropic",
            "cost": 0.015,
            "tokenUsage": {
                "inputTokens": 500,
                "outputTokens": 200,
                "cacheReadTokens": 100
            }
        }),
    );
    EventRepo::insert(&conn, &event).unwrap();

    let row = EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap();
    assert_eq!(row.model.as_deref(), Some("claude-opus-4-6"));
    assert_eq!(row.latency_ms, Some(2500));
    assert_eq!(row.stop_reason.as_deref(), Some("end_turn"));
    assert_eq!(row.has_thinking, Some(1));
    assert_eq!(row.provider_type.as_deref(), Some("anthropic"));
    assert!((row.cost.unwrap() - 0.015).abs() < f64::EPSILON);
    assert_eq!(row.input_tokens, Some(500));
    assert_eq!(row.output_tokens, Some(200));
}

#[test]
fn query_events_by_model() {
    let conn = setup();
    EventRepo::insert(
        &conn,
        &make_event(
            "evt_1",
            1,
            EventType::MessageAssistant,
            None,
            json!({
                "model": "claude-opus-4-6"
            }),
        ),
    )
    .unwrap();
    EventRepo::insert(
        &conn,
        &make_event(
            "evt_2",
            2,
            EventType::MessageAssistant,
            None,
            json!({
                "model": "claude-opus-4-6"
            }),
        ),
    )
    .unwrap();
    EventRepo::insert(
        &conn,
        &make_event(
            "evt_3",
            3,
            EventType::MessageAssistant,
            None,
            json!({
                "model": "gpt-4"
            }),
        ),
    )
    .unwrap();

    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM events WHERE session_id = 'sess_1' AND model = 'claude-opus-4-6'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        count, 2,
        "should find exactly 2 events with claude-opus-4-6 model"
    );
}

#[test]
fn per_turn_columns_survive_ancestor_cte() {
    let conn = setup();
    let e1 = make_event("evt_1", 1, EventType::MessageUser, None, json!({}));
    let e2 = make_event(
        "evt_2",
        2,
        EventType::MessageAssistant,
        Some("evt_1"),
        json!({
            "model": "claude-opus-4-6",
            "latency": 1000,
            "stopReason": "end_turn",
            "hasThinking": false,
            "providerType": "anthropic",
            "cost": 0.01
        }),
    );
    EventRepo::insert(&conn, &e1).unwrap();
    EventRepo::insert(&conn, &e2).unwrap();

    let ancestors = EventRepo::get_ancestors(&conn, "evt_2").unwrap();
    assert_eq!(ancestors.len(), 2);
    // The assistant message (last in chain) should have per-turn fields.
    let assistant = &ancestors[1];
    assert_eq!(assistant.model.as_deref(), Some("claude-opus-4-6"));
    assert_eq!(assistant.latency_ms, Some(1000));
    assert_eq!(assistant.stop_reason.as_deref(), Some("end_turn"));
    assert_eq!(assistant.provider_type.as_deref(), Some("anthropic"));
}

#[test]
fn per_turn_columns_survive_descendant_cte() {
    let conn = setup();
    let e1 = make_event("evt_1", 1, EventType::MessageUser, None, json!({}));
    let e2 = make_event(
        "evt_2",
        2,
        EventType::MessageAssistant,
        Some("evt_1"),
        json!({
            "model": "gpt-4",
            "providerType": "openai"
        }),
    );
    EventRepo::insert(&conn, &e1).unwrap();
    EventRepo::insert(&conn, &e2).unwrap();

    let desc = EventRepo::get_descendants(&conn, "evt_1").unwrap();
    assert_eq!(desc.len(), 1);
    assert_eq!(desc[0].model.as_deref(), Some("gpt-4"));
    assert_eq!(desc[0].provider_type.as_deref(), Some("openai"));
}
