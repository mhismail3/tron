//! Tests for the M28 dry-run validator.

use super::*;
use crate::domains::import::errors::ImportError;
use serde_json::json;
use std::io::Write;
use tempfile::tempdir;

fn write_clean_session(path: &Path) -> std::path::PathBuf {
    let file = path.join("clean.jsonl");
    let mut f = std::fs::File::create(&file).unwrap();

    writeln!(
        f,
        "{}",
        json!({
            "type": "user",
            "uuid": "u1",
            "timestamp": "2026-01-01T00:00:00Z",
            "promptId": "p1",
            "message": { "role": "user", "content": "Hi" }
        })
    )
    .unwrap();

    writeln!(
        f,
        "{}",
        json!({
            "type": "assistant",
            "uuid": "a1",
            "parentUuid": "u1",
            "timestamp": "2026-01-01T00:00:01Z",
            "message": {
                "id": "msg_01",
                "role": "assistant",
                "content": [{ "type": "text", "text": "Hello" }],
                "stop_reason": "end_turn",
                "usage": { "input_tokens": 10, "output_tokens": 5 },
                "model": "claude-opus-4-6"
            }
        })
    )
    .unwrap();

    file
}

#[test]
fn validate_clean_session_returns_no_warnings() {
    let dir = tempdir().unwrap();
    let path = write_clean_session(dir.path());

    let validation = validate_session(&path).expect("clean session validates");

    assert!(
        validation.warnings.is_empty(),
        "expected no warnings, got: {:?}",
        validation.warnings
    );
    assert!(
        validation.events_ready > 0,
        "events_ready should be non-zero"
    );
    assert_eq!(validation.records_parsed, validation.lines_total);
    assert_eq!(validation.preview.model, "claude-opus-4-6");
}

#[test]
fn validate_reports_unparseable_lines_with_line_numbers() {
    let dir = tempdir().unwrap();
    let file = dir.path().join("with-garbage.jsonl");
    let mut f = std::fs::File::create(&file).unwrap();

    // line 1: good user message
    writeln!(
        f,
        "{}",
        json!({
            "type": "user",
            "uuid": "u1",
            "timestamp": "2026-01-01T00:00:00Z",
            "promptId": "p1",
            "message": { "role": "user", "content": "Question" }
        })
    )
    .unwrap();

    // line 2: garbage
    writeln!(f, "this is not json at all").unwrap();

    // line 3: truncated JSON
    writeln!(f, "{{\"type\":\"user\",\"uuid\":\"trunc\",").unwrap();

    // line 4: good assistant message
    writeln!(
        f,
        "{}",
        json!({
            "type": "assistant",
            "uuid": "a1",
            "parentUuid": "u1",
            "timestamp": "2026-01-01T00:00:01Z",
            "message": {
                "id": "msg_01",
                "role": "assistant",
                "content": [{ "type": "text", "text": "Answer" }],
                "stop_reason": "end_turn",
                "usage": { "input_tokens": 10, "output_tokens": 5 },
                "model": "claude-opus-4-6"
            }
        })
    )
    .unwrap();

    let validation = validate_session(&file).expect("validates with warnings");

    let unparseable: Vec<_> = validation
        .warnings
        .iter()
        .filter_map(|w| match w.kind {
            ImportWarningKind::UnparseableLine { line_number } => Some(line_number),
            _ => None,
        })
        .collect();

    assert_eq!(unparseable, vec![2, 3]);
    assert_eq!(validation.records_parsed, 2);
    assert_eq!(validation.lines_total, 4);
}

#[test]
fn validate_refuses_provider_capability_history() {
    let dir = tempdir().unwrap();
    let file = dir.path().join("provider-capability-history.jsonl");
    let mut f = std::fs::File::create(&file).unwrap();

    writeln!(
        f,
        "{}",
        json!({
            "type": "user",
            "uuid": "u1",
            "timestamp": "2026-01-01T00:00:00Z",
            "promptId": "p1",
            "message": { "role": "user", "content": "Q" }
        })
    )
    .unwrap();

    writeln!(
        f,
        "{}",
        json!({
            "type": "assistant",
            "uuid": "a1",
            "parentUuid": "u1",
            "timestamp": "2026-01-01T00:00:01Z",
            "message": {
                "id": "msg_01",
                "role": "assistant",
                "content": [
                    { "type": "capability_invocation", "id": "provider_cap_1", "name": "filesystem::read_file", "input": { "path": "a.txt" } }
                ],
                "stop_reason": "capability_invocation",
                "usage": { "input_tokens": 10, "output_tokens": 5 },
                "model": "claude-opus-4-6"
            }
        })
    )
    .unwrap();

    writeln!(
        f,
        "{}",
        json!({
            "type": "user",
            "uuid": "tr1",
            "parentUuid": "a1",
            "timestamp": "2026-01-01T00:00:02Z",
            "promptId": "p1",
            "message": {
                "role": "user",
                "content": [
                    { "type": "capability_result", "capability_invocation_id": "provider_cap_1", "content": "ok" }
                ]
            }
        })
    )
    .unwrap();

    assert!(matches!(
        validate_session(&file),
        Err(ImportError::UnsupportedProviderCapabilityHistory { block_count: 2 })
    ));
}

#[test]
fn validate_reports_missing_model() {
    let dir = tempdir().unwrap();
    let file = dir.path().join("no-model.jsonl");
    let mut f = std::fs::File::create(&file).unwrap();

    writeln!(
        f,
        "{}",
        json!({
            "type": "user",
            "uuid": "u1",
            "timestamp": "2026-01-01T00:00:00Z",
            "promptId": "p1",
            "message": { "role": "user", "content": "Hi" }
        })
    )
    .unwrap();

    // Assistant message with NO model field.
    writeln!(
        f,
        "{}",
        json!({
            "type": "assistant",
            "uuid": "a1",
            "parentUuid": "u1",
            "timestamp": "2026-01-01T00:00:01Z",
            "message": {
                "id": "msg_01",
                "role": "assistant",
                "content": [{ "type": "text", "text": "Hello" }],
                "stop_reason": "end_turn",
                "usage": { "input_tokens": 10, "output_tokens": 5 }
            }
        })
    )
    .unwrap();

    let validation = validate_session(&file).expect("validates missing-model");
    assert!(
        validation
            .warnings
            .iter()
            .any(|w| matches!(w.kind, ImportWarningKind::AssistantMissingModel)),
        "expected AssistantMissingModel warning; got {:?}",
        validation.warnings
    );
    assert_eq!(validation.preview.model, "claude-sonnet-4-20250514");
}

#[test]
fn validate_empty_session_returns_error() {
    let dir = tempdir().unwrap();
    let file = dir.path().join("empty.jsonl");
    std::fs::File::create(&file).unwrap();

    let result = validate_session(&file);
    assert!(matches!(result, Err(ImportError::EmptySession)));
}

#[test]
fn parse_warning_message_includes_line_number_and_snippet() {
    let dir = tempdir().unwrap();
    let file = dir.path().join("gib.jsonl");
    let mut f = std::fs::File::create(&file).unwrap();

    writeln!(
        f,
        "{}",
        json!({
            "type": "user",
            "uuid": "u1",
            "timestamp": "2026-01-01T00:00:00Z",
            "promptId": "p1",
            "message": { "role": "user", "content": "Q" }
        })
    )
    .unwrap();

    let long_garbage = "x".repeat(200);
    writeln!(f, "{long_garbage}").unwrap();

    writeln!(
        f,
        "{}",
        json!({
            "type": "assistant",
            "uuid": "a1",
            "parentUuid": "u1",
            "timestamp": "2026-01-01T00:00:01Z",
            "message": {
                "id": "msg_01",
                "role": "assistant",
                "content": [{ "type": "text", "text": "ok" }],
                "stop_reason": "end_turn",
                "usage": { "input_tokens": 10, "output_tokens": 5 },
                "model": "claude-opus-4-6"
            }
        })
    )
    .unwrap();

    let validation = validate_session(&file).expect("validates");
    let parse_warning = validation
        .warnings
        .iter()
        .find(|w| matches!(w.kind, ImportWarningKind::UnparseableLine { .. }))
        .expect("expected one UnparseableLine warning");

    assert!(
        parse_warning.message.contains("Line 2"),
        "message should name line 2; got: {}",
        parse_warning.message
    );
    // Snippet is truncated to 120 chars with a trailing ellipsis
    assert!(
        parse_warning.message.contains("…"),
        "long line should produce a truncated snippet; got: {}",
        parse_warning.message
    );
}
