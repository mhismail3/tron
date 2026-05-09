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
fn validate_reports_orphan_tool_result() {
    let dir = tempdir().unwrap();
    let file = dir.path().join("orphan-result.jsonl");
    let mut f = std::fs::File::create(&file).unwrap();

    // user question
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

    // assistant with ONE tool call
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
                    { "type": "tool_use", "id": "toolu_real", "name": "Read", "input": { "path": "a.txt" } }
                ],
                "stop_reason": "tool_use",
                "usage": { "input_tokens": 10, "output_tokens": 5 },
                "model": "claude-opus-4-6"
            }
        })
    )
    .unwrap();

    // user tool_result referencing an id that does NOT exist in any tool_use
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
                    { "type": "tool_result", "tool_use_id": "toolu_ghost", "content": "impossible" }
                ]
            }
        })
    )
    .unwrap();

    // orphan tool_use_id `toolu_real` — no matching result
    // orphan tool_result referencing `toolu_ghost`
    let validation = validate_session(&file).expect("validates with orphans");

    let orphan_results: Vec<_> = validation
        .warnings
        .iter()
        .filter_map(|w| match &w.kind {
            ImportWarningKind::OrphanToolResult { tool_call_id } => Some(tool_call_id.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(orphan_results, vec!["toolu_ghost".to_string()]);

    let orphan_uses: Vec<_> = validation
        .warnings
        .iter()
        .filter_map(|w| match &w.kind {
            ImportWarningKind::OrphanToolUse { tool_call_id } => Some(tool_call_id.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(orphan_uses, vec!["toolu_real".to_string()]);
}

#[test]
fn validate_reports_orphan_tool_use_alone() {
    // Interrupted-turn fixture: tool call but no result.
    let dir = tempdir().unwrap();
    let file = dir.path().join("interrupted.jsonl");
    let mut f = std::fs::File::create(&file).unwrap();

    writeln!(
        f,
        "{}",
        json!({
            "type": "user",
            "uuid": "u1",
            "timestamp": "2026-01-01T00:00:00Z",
            "promptId": "p1",
            "message": { "role": "user", "content": "run a bash" }
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
                    { "type": "tool_use", "id": "toolu_lost", "name": "Bash", "input": { "command": "ls" } }
                ],
                "stop_reason": "tool_use",
                "usage": { "input_tokens": 10, "output_tokens": 5 },
                "model": "claude-opus-4-6"
            }
        })
    )
    .unwrap();

    let validation = validate_session(&file).expect("validates interrupted turn");
    let ids: Vec<_> = validation
        .warnings
        .iter()
        .filter_map(|w| match &w.kind {
            ImportWarningKind::OrphanToolUse { tool_call_id } => Some(tool_call_id.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(ids, vec!["toolu_lost".to_string()]);
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
fn validate_duplicate_ids_dedup_to_single_warning() {
    // Same orphan tool_use_id appears on multiple content blocks —
    // deterministic dedup, stable order.
    let dir = tempdir().unwrap();
    let file = dir.path().join("dup.jsonl");
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
                    { "type": "tool_use", "id": "toolu_lonely", "name": "Read", "input": { "path": "a.txt" } },
                    { "type": "tool_use", "id": "toolu_lonely", "name": "Read", "input": { "path": "b.txt" } }
                ],
                "stop_reason": "tool_use",
                "usage": { "input_tokens": 10, "output_tokens": 5 },
                "model": "claude-opus-4-6"
            }
        })
    )
    .unwrap();

    let validation = validate_session(&file).expect("validates");
    let uses: Vec<_> = validation
        .warnings
        .iter()
        .filter_map(|w| match &w.kind {
            ImportWarningKind::OrphanToolUse { tool_call_id } => Some(tool_call_id.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(
        uses.len(),
        1,
        "duplicate id must be reported exactly once; got {uses:?}"
    );
    assert_eq!(uses[0], "toolu_lonely");
}

#[test]
fn validate_matched_tool_call_and_result_emits_no_warning() {
    // Regression guard: clean pairing must not trip the orphan detector.
    let dir = tempdir().unwrap();
    let file = dir.path().join("matched.jsonl");
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
                    { "type": "tool_use", "id": "toolu_paired", "name": "Read", "input": { "path": "a.txt" } }
                ],
                "stop_reason": "tool_use",
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
                    { "type": "tool_result", "tool_use_id": "toolu_paired", "content": "ok" }
                ]
            }
        })
    )
    .unwrap();

    let validation = validate_session(&file).expect("validates");
    assert!(
        !validation.warnings.iter().any(|w| matches!(
            w.kind,
            ImportWarningKind::OrphanToolUse { .. } | ImportWarningKind::OrphanToolResult { .. }
        )),
        "matched pair must not produce orphan warnings: {:?}",
        validation.warnings
    );
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
