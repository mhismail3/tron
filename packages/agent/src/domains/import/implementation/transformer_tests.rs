use super::*;
use crate::domains::import::assembler::{AssembledAssistant, AssembledItem};
use crate::domains::import::types::ClaudeUsage;
use crate::domains::session::event_store::types::EventType;
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

fn make_assistant_item_with_usage(
    content_blocks: Vec<Value>,
    turn: i64,
    model: &str,
    stop_reason: &str,
    usage: ClaudeUsage,
) -> AssembledItem {
    AssembledItem::AssistantMessage(AssembledAssistant {
        message_id: "msg1".to_string(),
        content_blocks,
        model: model.to_string(),
        stop_reason: stop_reason.to_string(),
        usage,
        timestamp: "2026-01-01T00:00:01Z".to_string(),
        turn,
    })
}

fn make_provider_capability_result_item(turn: i64) -> AssembledItem {
    AssembledItem::UserMessage {
        record: serde_json::from_value(json!({
            "type": "user",
            "uuid": "tr1",
            "timestamp": "2026-01-01T00:00:02Z",
            "promptId": "p1",
            "message": {
                "role": "user",
                "content": [{
                    "type": "capability_result",
                    "capability_invocation_id": "provider_capability_1",
                    "content": "provider result",
                    "is_error": false,
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

fn make_imported_summary_item(summary: &str, turn: i64) -> AssembledItem {
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
            1,
            "claude-opus-4-6",
            "end_turn",
            10,
            5,
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
fn provider_capability_result_is_not_translated() {
    let items = vec![make_provider_capability_result_item(1)];
    let result = transform(items);

    assert!(result.events.is_empty());
}

#[test]
fn meta_user_skipped() {
    let items = vec![make_meta_item(1)];
    let result = transform(items);
    assert!(result.events.is_empty());
    assert_eq!(result.message_count, 0);
}

#[test]
fn imported_summary_record_emits_boundary_with_summary() {
    let items = vec![make_imported_summary_item(
        "The session covered X and Y.",
        1,
    )];
    let result = transform(items);

    assert_eq!(result.events.len(), 1);
    assert_eq!(result.events[0].event_type, EventType::CompactBoundary);
    assert_eq!(result.events[0].payload["originalTokens"], 0);
    assert_eq!(
        result.events[0].payload["summary"],
        "The session covered X and Y."
    );
}

#[test]
fn assistant_drops_provider_capability_blocks_and_keeps_text() {
    let items = vec![make_assistant_item(
        vec![
            json!({"type": "text", "text": "Let me check"}),
            json!({"type": "capability_invocation", "id": "provider_capability_1", "name": "process::run", "input": {"command": "ls"}}),
        ],
        1,
        "claude-opus-4-6",
        "capability_invocation",
        100,
        50,
    )];
    let result = transform(items);

    assert_eq!(result.events.len(), 3);
    assert_eq!(result.events[0].event_type, EventType::StreamTurnStart);
    assert_eq!(result.events[1].event_type, EventType::MessageAssistant);
    assert_eq!(
        result.events[1].payload["content"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(result.events[2].event_type, EventType::StreamTurnEnd);
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
fn provider_capability_only_assistant_produces_no_invocation_event() {
    let items = vec![make_assistant_item(
        vec![
            json!({"type": "capability_invocation", "id": "provider_capability_x", "name": "filesystem::read_file", "input": {"path": "/a.rs"}}),
        ],
        1,
        "claude-opus-4-6",
        "capability_invocation",
        10,
        5,
    )];
    let result = transform(items);

    assert!(
        result
            .events
            .iter()
            .all(|event| event.event_type != EventType::CapabilityInvocationStarted)
    );
    let msg = result
        .events
        .iter()
        .find(|e| e.event_type == EventType::MessageAssistant)
        .unwrap();
    assert!(msg.payload["content"].as_array().unwrap().is_empty());
}

#[test]
fn assistant_multiple_provider_capability_blocks_are_dropped() {
    let items = vec![make_assistant_item(
        vec![
            json!({"type": "capability_invocation", "id": "provider_capability_1", "name": "process::run", "input": {}}),
            json!({"type": "capability_invocation", "id": "provider_capability_2", "name": "filesystem::read_file", "input": {}}),
            json!({"type": "capability_invocation", "id": "provider_capability_3", "name": "filesystem::write_file", "input": {}}),
        ],
        1,
        "claude-opus-4-6",
        "capability_invocation",
        10,
        5,
    )];
    let result = transform(items);

    assert!(
        result
            .events
            .iter()
            .all(|event| event.event_type != EventType::CapabilityInvocationStarted)
    );
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

    // Opus 4.6+ tier: $5 input (1M tokens) + $2.50 output (100K tokens) = $7.50
    assert!(result.total_cost > 0.0);
    assert!((result.total_cost - 7.5).abs() < 0.01);

    let turn_end = result
        .events
        .iter()
        .find(|e| e.event_type == EventType::StreamTurnEnd)
        .unwrap();
    let turn_end_cost = turn_end.payload["cost"].as_f64().unwrap();
    let record_cost = turn_end.payload["tokenRecord"]["pricing"]["cost"]["totalCost"]
        .as_f64()
        .unwrap();
    assert!(turn_end_cost > 0.0);
    assert!((turn_end_cost - record_cost).abs() < f64::EPSILON);
}

#[test]
fn assistant_token_record_uses_imported_model_and_canonical_cost() {
    let items = vec![make_assistant_item_with_usage(
        vec![json!({"type": "text", "text": "hi"})],
        1,
        "claude-opus-4-6",
        "end_turn",
        ClaudeUsage {
            input_tokens: 100,
            output_tokens: 50,
            cache_read_input_tokens: 10,
            cache_creation_input_tokens: 5,
        },
    )];
    let result = transform(items);

    let msg = result
        .events
        .iter()
        .find(|e| e.event_type == EventType::MessageAssistant)
        .unwrap();
    assert_eq!(
        msg.payload["tokenRecord"]["meta"]["model"],
        "claude-opus-4-6"
    );
    assert_eq!(
        msg.payload["tokenRecord"]["source"]["provider"],
        "anthropic"
    );
    assert_eq!(msg.payload["tokenUsage"]["cachedInputTokens"], 10);
    assert_eq!(msg.payload["tokenUsage"]["totalTokens"], 165);
    assert_eq!(msg.payload["tokenRecord"]["pricing"]["available"], true);

    let turn_end = result
        .events
        .iter()
        .find(|e| e.event_type == EventType::StreamTurnEnd)
        .unwrap();
    assert_eq!(
        turn_end.payload["tokenRecord"]["meta"]["model"],
        "claude-opus-4-6"
    );
    assert_eq!(turn_end.payload["tokenUsage"]["providerType"], "anthropic");
    assert_eq!(turn_end.payload["tokenUsage"]["totalTokens"], 165);
    assert_eq!(
        turn_end.payload["tokenRecord"]["pricing"]["cost"]["totalCost"],
        msg.payload["tokenRecord"]["pricing"]["cost"]["totalCost"]
    );
}

#[test]
fn assistant_unknown_model_marks_pricing_unavailable_without_guessing() {
    let items = vec![make_assistant_item(
        vec![json!({"type": "text", "text": "hi"})],
        1,
        "claude-unlisted-future-model",
        "end_turn",
        1_000_000,
        100_000,
    )];
    let result = transform(items);

    assert_eq!(result.total_cost, 0.0);

    let msg = result
        .events
        .iter()
        .find(|e| e.event_type == EventType::MessageAssistant)
        .unwrap();
    assert_eq!(msg.payload["tokenRecord"]["pricing"]["available"], false);
    assert_eq!(
        msg.payload["tokenRecord"]["pricing"]["reason"],
        "unsupported_model_pricing"
    );
    assert!(msg.payload["tokenRecord"]["pricing"].get("cost").is_none());

    let turn_end = result
        .events
        .iter()
        .find(|e| e.event_type == EventType::StreamTurnEnd)
        .unwrap();
    assert!(turn_end.payload.get("cost").is_none());
    assert_eq!(
        turn_end.payload["tokenRecord"]["pricing"]["available"],
        false
    );
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
    // Imported api_error records carry no original classification; emit
    // "unknown" so the strict iOS decoder still accepts the event and the
    // renderer shows a generic-icon pill.
    assert_eq!(result.events[0].payload["category"], "unknown");
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
            1,
            "claude-opus-4-6",
            "end_turn",
            100,
            50,
        ),
        make_user_item(json!("q2"), 2),
        make_assistant_item(
            vec![json!({"type": "text", "text": "a2"})],
            2,
            "claude-opus-4-6",
            "end_turn",
            200,
            100,
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
            1,
            "claude-opus-4-6",
            "end_turn",
            100,
            50,
        ),
        make_user_item(json!("Show me an example"), 2),
        make_assistant_item(
            vec![
                json!({"type": "text", "text": "Here's an example:"}),
                json!({"type": "capability_invocation", "id": "provider_capability_1", "name": "filesystem::write_file", "input": {"path": "main.rs"}}),
            ],
            2,
            "claude-opus-4-6",
            "capability_invocation",
            200,
            100,
        ),
        make_provider_capability_result_item(2),
        make_assistant_item(
            vec![json!({"type": "text", "text": "I created the file."})],
            2,
            "claude-opus-4-6",
            "end_turn",
            150,
            30,
        ),
    ];
    let result = transform(items);

    let types: Vec<EventType> = result.events.iter().map(|e| e.event_type).collect();
    assert_eq!(
        types,
        vec![
            EventType::StreamTurnStart,  // turn 1
            EventType::MessageUser,      // "What is Rust?"
            EventType::MessageAssistant, // thinking + text
            EventType::StreamTurnEnd,    // turn 1 end
            EventType::StreamTurnStart,  // turn 2
            EventType::MessageUser,      // "Show me an example"
            EventType::MessageAssistant,
            EventType::MessageAssistant, // "I created the file."
            EventType::StreamTurnEnd,    // turn 2 end (one per turn)
        ]
    );
}

#[test]
fn provider_capability_block_is_removed_from_assistant_content() {
    let items = vec![make_assistant_item(
        vec![json!({
            "type": "capability_invocation",
            "id": "provider_capability_1",
            "name": "process::run",
            "input": {"command": "ls"},
            "caller": "capability_invocationer_xyz"
        })],
        1,
        "claude-opus-4-6",
        "capability_invocation",
        10,
        5,
    )];
    let result = transform(items);

    let msg = result
        .events
        .iter()
        .find(|e| e.event_type == EventType::MessageAssistant)
        .unwrap();
    assert!(msg.payload["content"].as_array().unwrap().is_empty());
}
