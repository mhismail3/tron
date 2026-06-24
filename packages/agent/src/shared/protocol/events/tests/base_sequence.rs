use super::*;

// ── BaseEvent sequence tests ──

#[test]
fn base_event_sequence_serialized() {
    let base = BaseEvent::now("s1").with_sequence(5);
    let json = serde_json::to_value(&base).unwrap();
    assert_eq!(json["sequence"], 5);
}

#[test]
fn base_event_no_sequence_omitted() {
    let base = BaseEvent::now("s1");
    assert!(base.sequence.is_none());
    let json = serde_json::to_value(&base).unwrap();
    assert!(json.get("sequence").is_none());
}

#[test]
fn base_event_with_sequence_builder() {
    let base = BaseEvent::now("s1").with_sequence(42);
    assert_eq!(base.sequence, Some(42));
    assert_eq!(base.session_id, "s1");
}

#[test]
fn tron_event_set_sequence() {
    let mut e = agent_start_event("s1");
    assert!(e.sequence().is_none());
    e.set_sequence(7);
    assert_eq!(e.sequence(), Some(7));
}

#[test]
fn tron_event_sequence_serialized_in_json() {
    let mut e = TronEvent::TurnStart {
        base: BaseEvent::now("s1"),
        turn: 1,
    };
    e.set_sequence(10);
    let json = serde_json::to_value(&e).unwrap();
    assert_eq!(json["sequence"], 10);
}

#[test]
fn tron_event_no_sequence_omitted_from_json() {
    let e = TronEvent::TurnStart {
        base: BaseEvent::now("s1"),
        turn: 1,
    };
    let json = serde_json::to_value(&e).unwrap();
    assert!(json.get("sequence").is_none());
}
