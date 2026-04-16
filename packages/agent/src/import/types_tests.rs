use super::*;
use serde_json::json;

#[test]
fn deserialize_user_plain_text() {
    let raw = json!({
        "type": "user",
        "uuid": "bed3c186-e1df-4db2-b4d0-e044435c1b0e",
        "parentUuid": null,
        "sessionId": "a7ecbfd5-654c-422f-8b0c-d17c74a3c08a",
        "timestamp": "2026-03-27T01:41:22.862Z",
        "promptId": "1b3c12a5-e0a3-4e8d-ab2f-9068910081c0",
        "isSidechain": false,
        "message": {
            "role": "user",
            "content": "Hello, how are you?"
        },
        "userType": "external",
        "entrypoint": "cli",
        "cwd": "/Users/moose/projects",
        "version": "2.1.84",
        "gitBranch": "main"
    });

    let record: ClaudeRecord = serde_json::from_value(raw).unwrap();
    assert_eq!(record.record_type, "user");
    assert_eq!(record.kind(), RecordKind::User);
    assert_eq!(record.uuid.as_deref(), Some("bed3c186-e1df-4db2-b4d0-e044435c1b0e"));
    assert!(record.parent_uuid.is_none());
    assert_eq!(record.prompt_id.as_deref(), Some("1b3c12a5-e0a3-4e8d-ab2f-9068910081c0"));
    assert!(!record.is_tool_result());

    let msg = record.message.unwrap();
    assert_eq!(msg.role.as_deref(), Some("user"));
    assert_eq!(msg.content.unwrap().as_str(), Some("Hello, how are you?"));
}

#[test]
fn deserialize_user_with_image() {
    let raw = json!({
        "type": "user",
        "uuid": "u1",
        "parentUuid": null,
        "timestamp": "2026-03-27T01:41:22.862Z",
        "promptId": "p1",
        "message": {
            "role": "user",
            "content": [
                { "type": "text", "text": "What is this?" },
                { "type": "image", "source": { "type": "base64", "media_type": "image/png", "data": "iVBOR" } }
            ]
        }
    });

    let record: ClaudeRecord = serde_json::from_value(raw).unwrap();
    assert!(!record.is_tool_result());
    let content = record.message.unwrap().content.unwrap();
    let blocks = content.as_array().unwrap();
    assert_eq!(blocks.len(), 2);
    assert_eq!(blocks[0]["type"], "text");
    assert_eq!(blocks[1]["type"], "image");
}

#[test]
fn deserialize_user_tool_result() {
    let raw = json!({
        "type": "user",
        "uuid": "tr1",
        "parentUuid": "a1",
        "timestamp": "2026-03-27T01:42:00Z",
        "promptId": "p1",
        "message": {
            "role": "user",
            "content": [{
                "type": "tool_result",
                "tool_use_id": "toolu_01QZ",
                "content": "file contents here",
                "is_error": false
            }]
        },
        "sourceToolUseId": "toolu_01QZ",
        "sourceToolAssistantUUID": "a1"
    });

    let record: ClaudeRecord = serde_json::from_value(raw).unwrap();
    assert!(record.is_tool_result());
    assert_eq!(record.source_tool_use_id.as_deref(), Some("toolu_01QZ"));
    assert_eq!(record.source_tool_assistant_uuid.as_deref(), Some("a1"));
}

#[test]
fn deserialize_user_tool_result_with_error() {
    let raw = json!({
        "type": "user",
        "uuid": "tr2",
        "parentUuid": "a2",
        "timestamp": "2026-03-27T01:42:00Z",
        "message": {
            "role": "user",
            "content": [{
                "type": "tool_result",
                "tool_use_id": "toolu_err",
                "content": "<tool_use_error>Command failed</tool_use_error>",
                "is_error": true
            }]
        }
    });

    let record: ClaudeRecord = serde_json::from_value(raw).unwrap();
    assert!(record.is_tool_result());
    let content = record.message.unwrap().content.unwrap();
    let block = &content.as_array().unwrap()[0];
    assert_eq!(block["is_error"], true);
}

#[test]
fn deserialize_user_is_meta() {
    let raw = json!({
        "type": "user",
        "uuid": "meta1",
        "parentUuid": "u1",
        "timestamp": "2026-03-27T01:41:22.862Z",
        "promptId": "p1",
        "isMeta": true,
        "message": {
            "role": "user",
            "content": "<local-command-caveat>Caveat text</local-command-caveat>"
        }
    });

    let record: ClaudeRecord = serde_json::from_value(raw).unwrap();
    assert_eq!(record.is_meta, Some(true));
    assert!(!record.is_tool_result());
}

#[test]
fn deserialize_assistant_thinking() {
    let raw = json!({
        "type": "assistant",
        "uuid": "a1",
        "parentUuid": "u1",
        "timestamp": "2026-03-27T01:41:33.840Z",
        "requestId": "req_011CZ",
        "message": {
            "id": "msg_01Rw",
            "model": "claude-opus-4-6",
            "role": "assistant",
            "content": [{
                "type": "thinking",
                "thinking": "Let me analyze this...",
                "signature": "ErsMClkIDB"
            }],
            "stop_reason": null,
            "usage": {
                "input_tokens": 3,
                "output_tokens": 44,
                "cache_read_input_tokens": 9647,
                "cache_creation_input_tokens": 11988
            }
        },
        "slug": "flickering-crafting-cupcake"
    });

    let record: ClaudeRecord = serde_json::from_value(raw).unwrap();
    assert_eq!(record.kind(), RecordKind::Assistant);
    assert_eq!(record.slug.as_deref(), Some("flickering-crafting-cupcake"));

    let msg = record.message.unwrap();
    assert_eq!(msg.id.as_deref(), Some("msg_01Rw"));
    assert_eq!(msg.model.as_deref(), Some("claude-opus-4-6"));
    assert!(msg.stop_reason.is_none());

    let usage = msg.usage.unwrap();
    assert_eq!(usage.input_tokens, 3);
    assert_eq!(usage.output_tokens, 44);
    assert_eq!(usage.cache_read_input_tokens, 9647);
    assert_eq!(usage.cache_creation_input_tokens, 11988);
}

#[test]
fn deserialize_assistant_text() {
    let raw = json!({
        "type": "assistant",
        "uuid": "a2",
        "parentUuid": "a1",
        "timestamp": "2026-03-27T01:41:34Z",
        "requestId": "req_011CZ",
        "message": {
            "id": "msg_01Rw",
            "role": "assistant",
            "content": [{ "type": "text", "text": "Here is the answer." }],
            "stop_reason": null
        }
    });

    let record: ClaudeRecord = serde_json::from_value(raw).unwrap();
    let content = record.message.unwrap().content.unwrap();
    let blocks = content.as_array().unwrap();
    assert_eq!(blocks[0]["type"], "text");
    assert_eq!(blocks[0]["text"], "Here is the answer.");
}

#[test]
fn deserialize_assistant_tool_use() {
    let raw = json!({
        "type": "assistant",
        "uuid": "a3",
        "parentUuid": "a2",
        "timestamp": "2026-03-27T01:41:35Z",
        "requestId": "req_011CZ",
        "message": {
            "id": "msg_01Rw",
            "role": "assistant",
            "content": [{
                "type": "tool_use",
                "id": "toolu_01QZ",
                "name": "Bash",
                "input": { "command": "ls -la" }
            }],
            "stop_reason": "tool_use",
            "usage": { "input_tokens": 100, "output_tokens": 50 }
        }
    });

    let record: ClaudeRecord = serde_json::from_value(raw).unwrap();
    let msg = record.message.unwrap();
    assert_eq!(msg.stop_reason.as_deref(), Some("tool_use"));
    let content = msg.content.unwrap();
    let block = &content.as_array().unwrap()[0];
    assert_eq!(block["name"], "Bash");
    assert_eq!(block["input"]["command"], "ls -la");
}

#[test]
fn deserialize_system_compact_boundary() {
    let raw = json!({
        "type": "system",
        "uuid": "s1",
        "parentUuid": null,
        "timestamp": "2026-03-28T00:00:00Z",
        "subtype": "compact_boundary",
        "content": "Conversation compacted"
    });

    let record: ClaudeRecord = serde_json::from_value(raw).unwrap();
    assert_eq!(record.kind(), RecordKind::System);
    assert_eq!(record.subtype.as_deref(), Some("compact_boundary"));
}

#[test]
fn deserialize_system_api_error() {
    let raw = json!({
        "type": "system",
        "uuid": "s2",
        "parentUuid": "a1",
        "timestamp": "2026-03-28T00:00:00Z",
        "subtype": "api_error",
        "level": "error",
        "error": { "cause": { "code": "ConnectionRefused" } },
        "retryInMs": 500,
        "retryAttempt": 1
    });

    let record: ClaudeRecord = serde_json::from_value(raw).unwrap();
    assert_eq!(record.kind(), RecordKind::System);
    assert_eq!(record.subtype.as_deref(), Some("api_error"));
}

#[test]
fn deserialize_custom_title() {
    let raw = json!({
        "type": "custom-title",
        "customTitle": "my-session-title",
        "sessionId": "a7ecbfd5"
    });

    let record: ClaudeRecord = serde_json::from_value(raw).unwrap();
    assert_eq!(record.kind(), RecordKind::CustomTitle);
    assert_eq!(record.custom_title.as_deref(), Some("my-session-title"));
}

#[test]
fn deserialize_last_prompt() {
    let raw = json!({
        "type": "last-prompt",
        "lastPrompt": "fix the bug",
        "sessionId": "a7ecbfd5"
    });

    let record: ClaudeRecord = serde_json::from_value(raw).unwrap();
    assert_eq!(record.kind(), RecordKind::LastPrompt);
    assert_eq!(record.last_prompt.as_deref(), Some("fix the bug"));
}

#[test]
fn deserialize_file_history_snapshot() {
    let raw = json!({
        "type": "file-history-snapshot",
        "messageId": "bed3c186",
        "snapshot": {
            "messageId": "bed3c186",
            "trackedFileBackups": {},
            "timestamp": "2026-03-27T01:41:22.862Z"
        },
        "isSnapshotUpdate": false
    });

    let record: ClaudeRecord = serde_json::from_value(raw).unwrap();
    assert_eq!(record.kind(), RecordKind::FileHistorySnapshot);
    assert!(record.uuid.is_none());
    assert_eq!(record.message_id.as_deref(), Some("bed3c186"));
    assert_eq!(record.is_snapshot_update, Some(false));
}

#[test]
fn deserialize_unknown_type_does_not_panic() {
    let raw = json!({
        "type": "some-future-type",
        "uuid": "x1",
        "timestamp": "2026-04-01T00:00:00Z"
    });

    let record: ClaudeRecord = serde_json::from_value(raw).unwrap();
    assert_eq!(record.kind(), RecordKind::Unknown);
    assert_eq!(record.record_type, "some-future-type");
}

#[test]
fn deserialize_malformed_usage_defaults_to_zero() {
    let raw = json!({
        "type": "assistant",
        "uuid": "a1",
        "message": {
            "role": "assistant",
            "content": [{ "type": "text", "text": "hi" }],
            "usage": {}
        }
    });

    let record: ClaudeRecord = serde_json::from_value(raw).unwrap();
    let usage = record.message.unwrap().usage.unwrap();
    assert_eq!(usage.input_tokens, 0);
    assert_eq!(usage.output_tokens, 0);
    assert_eq!(usage.cache_read_input_tokens, 0);
    assert_eq!(usage.cache_creation_input_tokens, 0);
}

#[test]
fn record_kind_parse_all_variants() {
    assert_eq!(RecordKind::parse("user"), RecordKind::User);
    assert_eq!(RecordKind::parse("assistant"), RecordKind::Assistant);
    assert_eq!(RecordKind::parse("system"), RecordKind::System);
    assert_eq!(RecordKind::parse("progress"), RecordKind::Progress);
    assert_eq!(RecordKind::parse("file-history-snapshot"), RecordKind::FileHistorySnapshot);
    assert_eq!(RecordKind::parse("attachment"), RecordKind::Attachment);
    assert_eq!(RecordKind::parse("custom-title"), RecordKind::CustomTitle);
    assert_eq!(RecordKind::parse("agent-name"), RecordKind::AgentName);
    assert_eq!(RecordKind::parse("last-prompt"), RecordKind::LastPrompt);
    assert_eq!(RecordKind::parse("queue-operation"), RecordKind::QueueOperation);
    assert_eq!(RecordKind::parse("permission-mode"), RecordKind::PermissionMode);
    assert_eq!(RecordKind::parse("invented"), RecordKind::Unknown);
}

#[test]
fn is_tool_result_false_for_assistant() {
    let raw = json!({
        "type": "assistant",
        "uuid": "a1",
        "message": {
            "role": "assistant",
            "content": [{ "type": "text", "text": "hi" }]
        }
    });
    let record: ClaudeRecord = serde_json::from_value(raw).unwrap();
    assert!(!record.is_tool_result());
}

#[test]
fn is_tool_result_false_for_plain_user() {
    let raw = json!({
        "type": "user",
        "uuid": "u1",
        "message": {
            "role": "user",
            "content": "hello"
        }
    });
    let record: ClaudeRecord = serde_json::from_value(raw).unwrap();
    assert!(!record.is_tool_result());
}

#[test]
fn is_tool_result_false_when_no_message() {
    let raw = json!({
        "type": "user",
        "uuid": "u1"
    });
    let record: ClaudeRecord = serde_json::from_value(raw).unwrap();
    assert!(!record.is_tool_result());
}
