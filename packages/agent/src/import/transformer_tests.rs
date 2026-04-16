use super::*;
use crate::events::types::EventType;
use crate::import::assembler::{AssembledAssistant, AssembledItem};
use crate::import::types::ClaudeUsage;
use serde_json::json;

fn make_user_item(content: Value, turn: i64) -> AssembledItem {
    AssembledItem::UserMessage {
        record: serde_json::from_value(json!({
            "type": "user",
            "uuid": "u1",
            "timestamp": "2026-01-01T00:00:00Z",
            "promptId": format!("p{turn}"),
            "message": { "role": "user", "content": content }
        }))
        .unwrap(),
        turn,
    }
}

fn make_assistant_item(
    content_blocks: Vec<Value>,
    turn: i64,
    model: &str,
    stop_reason: &str,
    input_tokens: i64,
    output_tokens: i64,
) -> AssembledItem {
    AssembledItem::AssistantMessage(AssembledAssistant {
        message_id: "msg1".to_string(),
        content_blocks,
        model: model.to_string(),
        stop_reason: stop_reason.to_string(),
        usage: ClaudeUsage {
            input_tokens,
            output_tokens,
            cache_read_input_tokens: 0,
            cache_creation_input_tokens: 0,
        },
        timestamp: "2026-01-01T00:00:01Z".to_string(),
        turn,
    })
}

fn make_tool_result_item(tool_use_id: &str, content: &str, is_error: bool, turn: i64) -> AssembledItem {
    AssembledItem::UserMessage {
        record: serde_json::from_value(json!({
            "type": "user",
            "uuid": "tr1",
            "timestamp": "2026-01-01T00:00:02Z",
            "promptId": "p1",
            "message": {
                "role": "user",
                "content": [{
                    "type": "tool_result",
                    "tool_use_id": tool_use_id,
                    "content": content,
                    "is_error": is_error,
                }]
            }
        }))
        .unwrap(),
        turn,
    }
}

fn make_meta_item(turn: i64) -> AssembledItem {
    AssembledItem::UserMessage {
        record: serde_json::from_value(json!({
            "type": "user",
            "uuid": "meta1",
            "timestamp": "2026-01-01T00:00:00Z",
            "promptId": "p1",
            "isMeta": true,
            "message": { "role": "user", "content": "<system-reminder>context</system-reminder>" }
        }))
        .unwrap(),
        turn,
    }
}

fn make_compact_summary_item(summary: &str, turn: i64) -> AssembledItem {
    AssembledItem::UserMessage {
        record: serde_json::from_value(json!({
            "type": "user",
            "uuid": "cs1",
            "timestamp": "2026-01-01T00:00:00Z",
            "promptId": "p1",
            "isCompactSummary": true,
            "message": { "role": "user", "content": summary }
        }))
        .unwrap(),
        turn,
    }
}

fn make_system_item(subtype: &str, turn: i64) -> AssembledItem {
    AssembledItem::SystemRecord {
        record: serde_json::from_value(json!({
            "type": "system",
            "uuid": "s1",
            "timestamp": "2026-01-01T00:00:00Z",
            "subtype": subtype,
            "message": { "role": "system", "content": "error details" }
        }))
        .unwrap(),
        turn,
    }
}

#[test]
fn user_message_emits_turn_start_and_message() {
    let items = vec![make_user_item(json!("hello"), 1)];
    let result = transform(items);

    assert_eq!(result.events.len(), 2);
    assert_eq!(result.events[0].event_type, EventType::StreamTurnStart);
    assert_eq!(result.events[0].payload["turn"], 1);
    assert_eq!(result.events[1].event_type, EventType::MessageUser);
    assert_eq!(result.events[1].payload["content"], "hello");
    assert_eq!(result.events[1].payload["turn"], 1);
    assert_eq!(result.message_count, 1);
}

#[test]
fn user_message_turn_start_only_once_per_turn() {
    let items = vec![
        make_user_item(json!("first"), 1),
        make_assistant_item(
            vec![json!({"type": "text", "text": "ok"})],
            1, "claude-opus-4-6", "end_turn", 10, 5,
        ),
    ];
    let result = transform(items);

    let turn_starts: Vec<_> = result
        .events
        .iter()
        .filter(|e| e.event_type == EventType::StreamTurnStart)
        .collect();
    assert_eq!(turn_starts.len(), 1);
}

#[test]
fn user_message_with_images_sets_image_count() {
    let content = json!([
        { "type": "text", "text": "check this" },
        { "type": "image", "source": { "type": "base64", "data": "..." } },
        { "type": "image", "source": { "type": "base64", "data": "..." } },
    ]);
    let items = vec![make_user_item(content, 1)];
    let result = transform(items);

    let msg = result
        .events
        .iter()
        .find(|e| e.event_type == EventType::MessageUser)
        .unwrap();
    assert_eq!(msg.payload["imageCount"], 2);
}

#[test]
fn tool_result_user_emits_tool_result_event() {
    let items = vec![make_tool_result_item("toolu_01", "file contents", false, 1)];
    let result = transform(items);

    assert_eq!(result.events.len(), 1);
    assert_eq!(result.events[0].event_type, EventType::ToolResult);
    assert_eq!(result.events[0].payload["toolCallId"], "toolu_01");
    assert_eq!(result.events[0].payload["content"], "file contents");
    assert_eq!(result.events[0].payload["isError"], false);
    assert_eq!(result.events[0].payload["duration"], 0);
}

#[test]
fn tool_result_with_error() {
    let items = vec![make_tool_result_item("toolu_02", "permission denied", true, 1)];
    let result = transform(items);

    assert_eq!(result.events[0].payload["isError"], true);
}

#[test]
fn meta_user_skipped() {
    let items = vec![make_meta_item(1)];
    let result = transform(items);
    assert!(result.events.is_empty());
    assert_eq!(result.message_count, 0);
}

#[test]
fn compact_summary_emits_boundary_and_summary() {
    let items = vec![make_compact_summary_item("The session covered X and Y.", 1)];
    let result = transform(items);

    assert_eq!(result.events.len(), 2);
    assert_eq!(result.events[0].event_type, EventType::CompactBoundary);
    assert_eq!(result.events[0].payload["originalTokens"], 0);
    assert_eq!(result.events[1].event_type, EventType::CompactSummary);
    assert_eq!(result.events[1].payload["summary"], "The session covered X and Y.");
}

#[test]
fn assistant_emits_message_tool_calls_and_turn_end() {
    let items = vec![make_assistant_item(
        vec![
            json!({"type": "text", "text": "Let me check"}),
            json!({"type": "tool_use", "id": "toolu_01", "name": "Bash", "input": {"command": "ls"}}),
        ],
        1,
        "claude-opus-4-6",
        "tool_use",
        100,
        50,
    )];
    let result = transform(items);

    // stream.turn_start + message.assistant + tool.call + stream.turn_end
    assert_eq!(result.events.len(), 4);
    assert_eq!(result.events[0].event_type, EventType::StreamTurnStart);
    assert_eq!(result.events[1].event_type, EventType::MessageAssistant);
    assert_eq!(result.events[2].event_type, EventType::ToolCall);
    assert_eq!(result.events[3].event_type, EventType::StreamTurnEnd);
}

#[test]
fn assistant_thinking_has_thinking_flag() {
    let items = vec![make_assistant_item(
        vec![
            json!({"type": "thinking", "thinking": "hmm"}),
            json!({"type": "text", "text": "answer"}),
        ],
        1,
        "claude-opus-4-6",
        "end_turn",
        100,
        50,
    )];
    let result = transform(items);

    let msg = result
        .events
        .iter()
        .find(|e| e.event_type == EventType::MessageAssistant)
        .unwrap();
    assert_eq!(msg.payload["hasThinking"], true);
}

#[test]
fn assistant_tool_use_produces_tool_call_event() {
    let items = vec![make_assistant_item(
        vec![json!({"type": "tool_use", "id": "toolu_x", "name": "Read", "input": {"path": "/a.rs"}})],
        1,
        "claude-opus-4-6",
        "tool_use",
        10,
        5,
    )];
    let result = transform(items);

    let tc = result
        .events
        .iter()
        .find(|e| e.event_type == EventType::ToolCall)
        .unwrap();
    assert_eq!(tc.payload["toolCallId"], "toolu_x");
    assert_eq!(tc.payload["name"], "Read");
    assert_eq!(tc.payload["arguments"]["path"], "/a.rs");
    assert_eq!(tc.payload["turn"], 1);
}

#[test]
fn assistant_multiple_tool_uses() {
    let items = vec![make_assistant_item(
        vec![
            json!({"type": "tool_use", "id": "t1", "name": "Bash", "input": {}}),
            json!({"type": "tool_use", "id": "t2", "name": "Read", "input": {}}),
            json!({"type": "tool_use", "id": "t3", "name": "Write", "input": {}}),
        ],
        1,
        "claude-opus-4-6",
        "tool_use",
        10,
        5,
    )];
    let result = transform(items);

    let tool_calls: Vec<_> = result
        .events
        .iter()
        .filter(|e| e.event_type == EventType::ToolCall)
        .collect();
    assert_eq!(tool_calls.len(), 3);
}

#[test]
fn assistant_cost_computed() {
    let items = vec![make_assistant_item(
        vec![json!({"type": "text", "text": "hi"})],
        1,
        "claude-opus-4-6",
        "end_turn",
        1_000_000,
        100_000,
    )];
    let result = transform(items);

    // $15 input + $7.50 output = $22.50
    assert!(result.total_cost > 0.0);
    assert!((result.total_cost - 22.5).abs() < 0.01);

    let turn_end = result
        .events
        .iter()
        .find(|e| e.event_type == EventType::StreamTurnEnd)
        .unwrap();
    assert!(turn_end.payload["cost"].as_f64().unwrap() > 0.0);
}

#[test]
fn system_compact_boundary() {
    let items = vec![make_system_item("compact_boundary", 1)];
    let result = transform(items);

    assert_eq!(result.events.len(), 1);
    assert_eq!(result.events[0].event_type, EventType::CompactBoundary);
}

#[test]
fn system_api_error() {
    let items = vec![make_system_item("api_error", 1)];
    let result = transform(items);

    assert_eq!(result.events.len(), 1);
    assert_eq!(result.events[0].event_type, EventType::ErrorProvider);
    assert_eq!(result.events[0].payload["provider"], "anthropic");
    assert_eq!(result.events[0].payload["retryable"], false);
}

#[test]
fn system_turn_duration_skipped() {
    let items = vec![make_system_item("turn_duration", 1)];
    let result = transform(items);
    assert!(result.events.is_empty());
}

#[test]
fn system_local_command_skipped() {
    let items = vec![make_system_item("local_command", 1)];
    let result = transform(items);
    assert!(result.events.is_empty());
}

#[test]
fn custom_title_captured() {
    let items = vec![AssembledItem::CustomTitle("My Session".to_string())];
    let result = transform(items);
    assert!(result.events.is_empty());
    assert_eq!(result.title.as_deref(), Some("My Session"));
}

#[test]
fn transform_result_aggregates() {
    let items = vec![
        make_user_item(json!("q1"), 1),
        make_assistant_item(
            vec![json!({"type": "text", "text": "a1"})],
            1, "claude-opus-4-6", "end_turn", 100, 50,
        ),
        make_user_item(json!("q2"), 2),
        make_assistant_item(
            vec![json!({"type": "text", "text": "a2"})],
            2, "claude-opus-4-6", "end_turn", 200, 100,
        ),
    ];
    let result = transform(items);

    assert_eq!(result.total_input_tokens, 300);
    assert_eq!(result.total_output_tokens, 150);
    assert!(result.total_cost > 0.0);
    assert_eq!(result.turn_count, 2);
    assert_eq!(result.message_count, 4); // 2 user + 2 assistant
    assert_eq!(result.model, "claude-opus-4-6");
}

#[test]
fn full_conversation_event_sequence() {
    // Verify the complete event ordering for a realistic conversation
    let items = vec![
        make_user_item(json!("What is Rust?"), 1),
        make_assistant_item(
            vec![
                json!({"type": "thinking", "thinking": "Let me explain Rust"}),
                json!({"type": "text", "text": "Rust is a systems language"}),
            ],
            1, "claude-opus-4-6", "end_turn", 100, 50,
        ),
        make_user_item(json!("Show me an example"), 2),
        make_assistant_item(
            vec![
                json!({"type": "text", "text": "Here's an example:"}),
                json!({"type": "tool_use", "id": "t1", "name": "Write", "input": {"path": "main.rs"}}),
            ],
            2, "claude-opus-4-6", "tool_use", 200, 100,
        ),
        make_tool_result_item("t1", "File written", false, 2),
        make_assistant_item(
            vec![json!({"type": "text", "text": "I created the file."})],
            2, "claude-opus-4-6", "end_turn", 150, 30,
        ),
    ];
    let result = transform(items);

    let types: Vec<EventType> = result.events.iter().map(|e| e.event_type).collect();
    assert_eq!(
        types,
        vec![
            EventType::StreamTurnStart,   // turn 1
            EventType::MessageUser,        // "What is Rust?"
            EventType::MessageAssistant,   // thinking + text
            EventType::StreamTurnEnd,      // turn 1 end
            EventType::StreamTurnStart,    // turn 2
            EventType::MessageUser,        // "Show me an example"
            EventType::MessageAssistant,   // text + tool_use
            EventType::ToolCall,           // Write tool
            EventType::ToolResult,         // "File written"
            EventType::MessageAssistant,   // "I created the file."
            EventType::StreamTurnEnd,      // turn 2 end (one per turn)
        ]
    );
}

#[test]
fn assistant_tool_use_normalized_input_to_arguments() {
    // Claude Code stores "input" + "caller" on tool_use blocks; Tron expects "arguments"
    let items = vec![make_assistant_item(
        vec![json!({
            "type": "tool_use",
            "id": "toolu_01",
            "name": "Bash",
            "input": {"command": "ls"},
            "caller": "tool_caller_xyz"
        })],
        1,
        "claude-opus-4-6",
        "tool_use",
        10,
        5,
    )];
    let result = transform(items);

    let msg = result
        .events
        .iter()
        .find(|e| e.event_type == EventType::MessageAssistant)
        .unwrap();
    let block = &msg.payload["content"][0];
    // "input" renamed to "arguments"
    assert_eq!(block["arguments"]["command"], "ls");
    assert!(block.get("input").is_none());
    // "caller" stripped
    assert!(block.get("caller").is_none());
    // Other fields preserved
    assert_eq!(block["type"], "tool_use");
    assert_eq!(block["id"], "toolu_01");
    assert_eq!(block["name"], "Bash");
}
