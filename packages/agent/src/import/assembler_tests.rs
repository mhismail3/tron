use super::*;
use serde_json::json;

fn lr(record_type: &str, uuid: &str, parent: Option<&str>, ts: &str, turn: i64) -> LinearRecord {
    LinearRecord {
        record: serde_json::from_value(json!({
            "type": record_type,
            "uuid": uuid,
            "parentUuid": parent,
            "timestamp": ts,
            "message": { "role": record_type, "content": "test" }
        }))
        .unwrap(),
        turn,
    }
}

fn lr_assistant(uuid: &str, parent: Option<&str>, ts: &str, msg_id: &str, content: Value, stop_reason: Option<&str>, usage: Option<Value>, model: Option<&str>, turn: i64) -> LinearRecord {
    let mut msg = json!({
        "id": msg_id,
        "role": "assistant",
        "content": content,
    });
    if let Some(sr) = stop_reason {
        msg["stop_reason"] = json!(sr);
    }
    if let Some(u) = usage {
        msg["usage"] = u;
    }
    if let Some(m) = model {
        msg["model"] = json!(m);
    }

    LinearRecord {
        record: serde_json::from_value(json!({
            "type": "assistant",
            "uuid": uuid,
            "parentUuid": parent,
            "timestamp": ts,
            "message": msg,
        }))
        .unwrap(),
        turn,
    }
}

fn lr_user(uuid: &str, parent: Option<&str>, ts: &str, turn: i64) -> LinearRecord {
    LinearRecord {
        record: serde_json::from_value(json!({
            "type": "user",
            "uuid": uuid,
            "parentUuid": parent,
            "timestamp": ts,
            "promptId": format!("p{turn}"),
            "message": { "role": "user", "content": "hello" }
        }))
        .unwrap(),
        turn,
    }
}

#[test]
fn single_assistant_no_chunking() {
    let records = vec![lr_assistant(
        "a1", None, "2026-01-01T00:00:00Z", "msg1",
        json!([{ "type": "text", "text": "hello" }]),
        Some("end_turn"),
        Some(json!({ "input_tokens": 10, "output_tokens": 5 })),
        Some("claude-opus-4-6"),
        1,
    )];

    let items = assemble(records);
    assert_eq!(items.len(), 1);
    let AssembledItem::AssistantMessage(am) = &items[0] else { panic!("expected AssistantMessage") };
    assert_eq!(am.content_blocks.len(), 1);
    assert_eq!(am.content_blocks[0]["text"], "hello");
    assert_eq!(am.stop_reason, "end_turn");
    assert_eq!(am.model, "claude-opus-4-6");
    assert_eq!(am.usage.input_tokens, 10);
}

#[test]
fn two_chunk_assistant() {
    let records = vec![
        lr_assistant("a1", None, "2026-01-01T00:00:00Z", "msg1",
            json!([{ "type": "thinking", "thinking": "Let me think..." }]),
            None, None, Some("claude-opus-4-6"), 1),
        lr_assistant("a2", Some("a1"), "2026-01-01T00:00:01Z", "msg1",
            json!([{ "type": "text", "text": "Here's the answer" }]),
            Some("end_turn"),
            Some(json!({ "input_tokens": 100, "output_tokens": 50 })),
            None, 1),
    ];

    let items = assemble(records);
    assert_eq!(items.len(), 1);
    let AssembledItem::AssistantMessage(am) = &items[0] else { panic!() };
    assert_eq!(am.content_blocks.len(), 2);
    assert_eq!(am.content_blocks[0]["type"], "thinking");
    assert_eq!(am.content_blocks[1]["type"], "text");
    assert_eq!(am.stop_reason, "end_turn");
    assert_eq!(am.model, "claude-opus-4-6");
    assert_eq!(am.usage.input_tokens, 100);
}

#[test]
fn three_chunk_assistant() {
    let records = vec![
        lr_assistant("a1", None, "2026-01-01T00:00:00Z", "msg1",
            json!([{ "type": "thinking", "thinking": "hmm" }]),
            None, None, Some("claude-opus-4-6"), 1),
        lr_assistant("a2", Some("a1"), "2026-01-01T00:00:01Z", "msg1",
            json!([{ "type": "text", "text": "answer" }]),
            None, None, None, 1),
        lr_assistant("a3", Some("a2"), "2026-01-01T00:00:02Z", "msg1",
            json!([{ "type": "tool_use", "id": "t1", "name": "Bash", "input": {} }]),
            Some("tool_use"),
            Some(json!({ "input_tokens": 200, "output_tokens": 100 })),
            None, 1),
    ];

    let items = assemble(records);
    assert_eq!(items.len(), 1);
    let AssembledItem::AssistantMessage(am) = &items[0] else { panic!() };
    assert_eq!(am.content_blocks.len(), 3);
    assert_eq!(am.content_blocks[0]["type"], "thinking");
    assert_eq!(am.content_blocks[1]["type"], "text");
    assert_eq!(am.content_blocks[2]["type"], "tool_use");
    assert_eq!(am.stop_reason, "tool_use");
}

#[test]
fn stop_reason_from_last_chunk() {
    let records = vec![
        lr_assistant("a1", None, "2026-01-01T00:00:00Z", "msg1",
            json!([{ "type": "text", "text": "a" }]),
            None, None, None, 1),
        lr_assistant("a2", Some("a1"), "2026-01-01T00:00:01Z", "msg1",
            json!([{ "type": "tool_use", "id": "t1", "name": "X", "input": {} }]),
            Some("tool_use"), None, None, 1),
    ];

    let items = assemble(records);
    let AssembledItem::AssistantMessage(am) = &items[0] else { panic!() };
    assert_eq!(am.stop_reason, "tool_use");
}

#[test]
fn usage_from_last_chunk() {
    let records = vec![
        lr_assistant("a1", None, "2026-01-01T00:00:00Z", "msg1",
            json!([{ "type": "thinking", "thinking": "x" }]),
            None,
            Some(json!({ "input_tokens": 3, "output_tokens": 1 })),
            None, 1),
        lr_assistant("a2", Some("a1"), "2026-01-01T00:00:01Z", "msg1",
            json!([{ "type": "text", "text": "y" }]),
            Some("end_turn"),
            Some(json!({ "input_tokens": 100, "output_tokens": 50 })),
            None, 1),
    ];

    let items = assemble(records);
    let AssembledItem::AssistantMessage(am) = &items[0] else { panic!() };
    assert_eq!(am.usage.input_tokens, 100);
    assert_eq!(am.usage.output_tokens, 50);
}

#[test]
fn model_from_any_chunk() {
    let records = vec![
        lr_assistant("a1", None, "2026-01-01T00:00:00Z", "msg1",
            json!([{ "type": "text", "text": "a" }]),
            None, None, Some("claude-sonnet-4-6"), 1),
        lr_assistant("a2", Some("a1"), "2026-01-01T00:00:01Z", "msg1",
            json!([{ "type": "text", "text": "b" }]),
            Some("end_turn"), None, None, 1),
    ];

    let items = assemble(records);
    let AssembledItem::AssistantMessage(am) = &items[0] else { panic!() };
    assert_eq!(am.model, "claude-sonnet-4-6");
}

#[test]
fn empty_thinking_stripped() {
    let records = vec![lr_assistant("a1", None, "2026-01-01T00:00:00Z", "msg1",
        json!([
            { "type": "thinking", "thinking": "", "signature": "abc" },
            { "type": "text", "text": "answer" }
        ]),
        Some("end_turn"), None, None, 1)];

    let items = assemble(records);
    let AssembledItem::AssistantMessage(am) = &items[0] else { panic!() };
    assert_eq!(am.content_blocks.len(), 1); // empty thinking stripped
    assert_eq!(am.content_blocks[0]["type"], "text");
}

#[test]
fn thinking_signature_stripped() {
    let records = vec![lr_assistant("a1", None, "2026-01-01T00:00:00Z", "msg1",
        json!([{ "type": "thinking", "thinking": "deep thoughts", "signature": "ErsMClk" }]),
        Some("end_turn"), None, None, 1)];

    let items = assemble(records);
    let AssembledItem::AssistantMessage(am) = &items[0] else { panic!() };
    assert_eq!(am.content_blocks.len(), 1);
    assert!(am.content_blocks[0].get("signature").is_none());
    assert_eq!(am.content_blocks[0]["thinking"], "deep thoughts");
}

#[test]
fn user_records_pass_through() {
    let records = vec![lr_user("u1", None, "2026-01-01T00:00:00Z", 1)];
    let items = assemble(records);
    assert_eq!(items.len(), 1);
    assert!(matches!(&items[0], AssembledItem::UserMessage { .. }));
}

#[test]
fn system_records_pass_through() {
    let records = vec![lr("system", "s1", None, "2026-01-01T00:00:00Z", 1)];
    let items = assemble(records);
    assert_eq!(items.len(), 1);
    assert!(matches!(&items[0], AssembledItem::SystemRecord { .. }));
}

#[test]
fn custom_title_extracted() {
    let records = vec![LinearRecord {
        record: serde_json::from_value(json!({
            "type": "custom-title",
            "uuid": "ct1",
            "customTitle": "My Title",
            "sessionId": "s1"
        }))
        .unwrap(),
        turn: 1,
    }];

    let items = assemble(records);
    assert_eq!(items.len(), 1);
    let AssembledItem::CustomTitle(title) = &items[0] else { panic!() };
    assert_eq!(title, "My Title");
}

#[test]
fn interleaved_user_assistant() {
    let records = vec![
        lr_user("u1", None, "2026-01-01T00:00:00Z", 1),
        lr_assistant("a1", Some("u1"), "2026-01-01T00:00:01Z", "msg1",
            json!([{ "type": "thinking", "thinking": "t" }]),
            None, None, Some("model"), 1),
        lr_assistant("a2", Some("a1"), "2026-01-01T00:00:02Z", "msg1",
            json!([{ "type": "text", "text": "answer" }]),
            Some("end_turn"), None, None, 1),
        lr_user("u2", Some("a2"), "2026-01-01T00:00:03Z", 2),
        lr_assistant("a3", Some("u2"), "2026-01-01T00:00:04Z", "msg2",
            json!([{ "type": "text", "text": "response" }]),
            Some("end_turn"), None, None, 2),
    ];

    let items = assemble(records);
    assert_eq!(items.len(), 4); // u1, assembled(a1+a2), u2, assembled(a3)
    assert!(matches!(&items[0], AssembledItem::UserMessage { .. }));
    let AssembledItem::AssistantMessage(am1) = &items[1] else { panic!() };
    assert_eq!(am1.content_blocks.len(), 2); // thinking + text merged
    assert!(matches!(&items[2], AssembledItem::UserMessage { .. }));
    let AssembledItem::AssistantMessage(am2) = &items[3] else { panic!() };
    assert_eq!(am2.content_blocks.len(), 1);
}

#[test]
fn assistant_with_no_message_id() {
    let records = vec![LinearRecord {
        record: serde_json::from_value(json!({
            "type": "assistant",
            "uuid": "a1",
            "timestamp": "2026-01-01T00:00:00Z",
            "message": {
                "role": "assistant",
                "content": [{ "type": "text", "text": "hi" }],
                "stop_reason": "end_turn"
            }
        }))
        .unwrap(),
        turn: 1,
    }];

    let items = assemble(records);
    assert_eq!(items.len(), 1);
    let AssembledItem::AssistantMessage(am) = &items[0] else { panic!() };
    assert_eq!(am.content_blocks.len(), 1);
}
