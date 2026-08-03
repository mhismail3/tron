use serde_json::json;

use super::state::*;

#[test]
fn message_serde_roundtrip() {
    let message = Message {
        role: "user".into(),
        content: json!("Hello"),
        invocation_id: None,
        is_error: None,
    };
    let value = serde_json::to_value(&message).unwrap();
    assert_eq!(value["role"], "user");
    assert!(value.get("invocationId").is_none());
    assert_eq!(serde_json::from_value::<Message>(value).unwrap(), message);
}

#[test]
fn tool_result_message_carries_invocation_identity() {
    let message = Message {
        role: "toolResult".into(),
        content: json!("ls output"),
        invocation_id: Some("tc-1".into()),
        is_error: Some(false),
    };
    let value = serde_json::to_value(message).unwrap();
    assert_eq!(value["invocationId"], "tc-1");
    assert_eq!(value["isError"], false);
}

#[test]
fn message_event_ids_preserve_null_slots() {
    let value = serde_json::to_value(MessageWithEventId {
        message: Message {
            role: "assistant".into(),
            content: json!([{"type": "text", "text": "Hi"}]),
            invocation_id: None,
            is_error: None,
        },
        event_ids: vec![Some("evt-1".into()), None],
    })
    .unwrap();
    assert_eq!(value["eventIds"][0], "evt-1");
    assert!(value["eventIds"][1].is_null());
}
