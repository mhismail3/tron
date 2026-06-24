use super::*;

#[test]
fn session_updated_event_type() {
    let e = TronEvent::SessionUpdated {
        base: BaseEvent::now("s1"),
        title: Some("title".into()),
        model: Some("claude-opus-4-6".into()),
        event_count: Some(8),
        turn_count: Some(2),
        message_count: Some(5),
        input_tokens: Some(100),
        output_tokens: Some(50),
        last_turn_input_tokens: Some(20),
        cache_read_tokens: Some(10),
        cache_creation_tokens: Some(5),
        cost: Some(0.01),
        last_activity: "2024-01-01T00:00:00Z".into(),
        is_active: true,
        last_user_prompt: Some("hello".into()),
        last_assistant_response: Some("world".into()),
        parent_session_id: None,
        activity_lines: None,
    };
    assert_eq!(e.event_type(), "session_updated");
    assert_eq!(e.session_id(), "s1");
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["eventCount"], 8);
    assert_eq!(json["turnCount"], 2);
}

#[test]
fn context_cleared_event_type() {
    let e = TronEvent::ContextCleared {
        base: BaseEvent::now("s1"),
        tokens_before: 5000,
        tokens_after: 0,
    };
    assert_eq!(e.event_type(), "context_cleared");
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["tokensBefore"], 5000);
    assert_eq!(json["tokensAfter"], 0);
}

#[test]
fn message_deleted_event_type() {
    let e = TronEvent::MessageDeleted {
        base: BaseEvent::now("s1"),
        target_event_id: "evt-123".into(),
        target_type: "message.user".into(),
        target_turn: Some(3),
        reason: Some("user request".into()),
    };
    assert_eq!(e.event_type(), "message_deleted");
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["targetEventId"], "evt-123");
    assert_eq!(json["targetType"], "message.user");
    assert_eq!(json["targetTurn"], 3);
}
