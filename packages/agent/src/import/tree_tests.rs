use super::*;
use serde_json::json;

fn make_record(record_type: &str, uuid: &str, parent: Option<&str>, ts: &str) -> ClaudeRecord {
    serde_json::from_value(json!({
        "type": record_type,
        "uuid": uuid,
        "parentUuid": parent,
        "timestamp": ts,
        "message": { "role": record_type, "content": "test" }
    }))
    .unwrap()
}

fn make_user(uuid: &str, parent: Option<&str>, ts: &str, prompt_id: &str) -> ClaudeRecord {
    serde_json::from_value(json!({
        "type": "user",
        "uuid": uuid,
        "parentUuid": parent,
        "timestamp": ts,
        "promptId": prompt_id,
        "message": { "role": "user", "content": "hello" }
    }))
    .unwrap()
}

fn make_assistant(uuid: &str, parent: Option<&str>, ts: &str) -> ClaudeRecord {
    serde_json::from_value(json!({
        "type": "assistant",
        "uuid": uuid,
        "parentUuid": parent,
        "timestamp": ts,
        "message": { "role": "assistant", "content": [{"type": "text", "text": "hi"}] }
    }))
    .unwrap()
}

fn make_tool_result(uuid: &str, parent: Option<&str>, ts: &str, prompt_id: &str) -> ClaudeRecord {
    serde_json::from_value(json!({
        "type": "user",
        "uuid": uuid,
        "parentUuid": parent,
        "timestamp": ts,
        "promptId": prompt_id,
        "message": {
            "role": "user",
            "content": [{ "type": "tool_result", "tool_use_id": "toolu_1", "content": "ok" }]
        }
    }))
    .unwrap()
}

#[test]
fn linearize_simple_chain() {
    let records = vec![
        make_user("u1", None, "2026-01-01T00:00:00Z", "p1"),
        make_assistant("a1", Some("u1"), "2026-01-01T00:00:01Z"),
        make_user("u2", Some("a1"), "2026-01-01T00:00:02Z", "p2"),
    ];

    let result = linearize(records);
    assert_eq!(result.len(), 3);
    assert_eq!(result[0].record.uuid.as_deref(), Some("u1"));
    assert_eq!(result[1].record.uuid.as_deref(), Some("a1"));
    assert_eq!(result[2].record.uuid.as_deref(), Some("u2"));
}

#[test]
fn linearize_branching_picks_latest() {
    // u1 → b_early (ts=01) and u1 → b_late (ts=02). Should pick b_late.
    let records = vec![
        make_user("u1", None, "2026-01-01T00:00:00Z", "p1"),
        make_assistant("b_early", Some("u1"), "2026-01-01T00:00:01Z"),
        make_assistant("b_late", Some("u1"), "2026-01-01T00:00:02Z"),
    ];

    let result = linearize(records);
    assert_eq!(result.len(), 2);
    assert_eq!(result[0].record.uuid.as_deref(), Some("u1"));
    assert_eq!(result[1].record.uuid.as_deref(), Some("b_late"));
}

#[test]
fn linearize_deep_branch() {
    // u1 → a1 → u2 → a2_early, u1 → a1 → u2 → a2_late
    let records = vec![
        make_user("u1", None, "2026-01-01T00:00:00Z", "p1"),
        make_assistant("a1", Some("u1"), "2026-01-01T00:00:01Z"),
        make_user("u2", Some("a1"), "2026-01-01T00:00:02Z", "p2"),
        make_assistant("a2_early", Some("u2"), "2026-01-01T00:00:03Z"),
        make_assistant("a2_late", Some("u2"), "2026-01-01T00:00:04Z"),
    ];

    let result = linearize(records);
    assert_eq!(result.len(), 4);
    assert_eq!(result[3].record.uuid.as_deref(), Some("a2_late"));
}

#[test]
fn linearize_single_record() {
    let records = vec![make_user("u1", None, "2026-01-01T00:00:00Z", "p1")];
    let result = linearize(records);
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].turn, 1);
}

#[test]
fn linearize_empty_input() {
    let result = linearize(vec![]);
    assert!(result.is_empty());
}

#[test]
fn linearize_filters_progress_records() {
    let records = vec![
        make_user("u1", None, "2026-01-01T00:00:00Z", "p1"),
        make_record("progress", "pr1", Some("u1"), "2026-01-01T00:00:01Z"),
        make_assistant("a1", Some("pr1"), "2026-01-01T00:00:02Z"),
    ];

    let result = linearize(records);
    // progress record filtered out
    assert_eq!(result.len(), 2);
    assert_eq!(result[0].record.record_type, "user");
    assert_eq!(result[1].record.record_type, "assistant");
}

#[test]
fn linearize_filters_file_history_snapshots() {
    // file-history-snapshot records have no uuid, so they're partitioned out
    let snapshot: ClaudeRecord = serde_json::from_value(json!({
        "type": "file-history-snapshot",
        "messageId": "m1",
        "snapshot": { "trackedFileBackups": {} },
        "isSnapshotUpdate": false
    }))
    .unwrap();

    let records = vec![
        make_user("u1", None, "2026-01-01T00:00:00Z", "p1"),
        snapshot,
    ];

    let result = linearize(records);
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].record.record_type, "user");
}

#[test]
fn turn_assignment_increments_on_new_prompt_id() {
    let records = vec![
        make_user("u1", None, "2026-01-01T00:00:00Z", "p1"),
        make_assistant("a1", Some("u1"), "2026-01-01T00:00:01Z"),
        make_user("u2", Some("a1"), "2026-01-01T00:00:02Z", "p2"),
        make_assistant("a2", Some("u2"), "2026-01-01T00:00:03Z"),
        make_user("u3", Some("a2"), "2026-01-01T00:00:04Z", "p3"),
    ];

    let result = linearize(records);
    assert_eq!(result[0].turn, 1); // u1, prompt p1
    assert_eq!(result[1].turn, 1); // a1, inherits turn 1
    assert_eq!(result[2].turn, 2); // u2, prompt p2
    assert_eq!(result[3].turn, 2); // a2, inherits turn 2
    assert_eq!(result[4].turn, 3); // u3, prompt p3
}

#[test]
fn turn_assignment_meta_records_dont_advance() {
    let meta: ClaudeRecord = serde_json::from_value(json!({
        "type": "user",
        "uuid": "meta1",
        "parentUuid": "u1",
        "timestamp": "2026-01-01T00:00:01Z",
        "promptId": "p1",
        "isMeta": true,
        "message": { "role": "user", "content": "<system-reminder>context</system-reminder>" }
    }))
    .unwrap();

    let records = vec![
        make_user("u1", None, "2026-01-01T00:00:00Z", "p1"),
        meta,
        make_assistant("a1", Some("meta1"), "2026-01-01T00:00:02Z"),
    ];

    let result = linearize(records);
    assert_eq!(result.len(), 3);
    // All on turn 1 — the meta record doesn't advance
    assert_eq!(result[0].turn, 1);
    assert_eq!(result[1].turn, 1);
    assert_eq!(result[2].turn, 1);
}

#[test]
fn turn_assignment_tool_results_inherit_turn() {
    let records = vec![
        make_user("u1", None, "2026-01-01T00:00:00Z", "p1"),
        make_assistant("a1", Some("u1"), "2026-01-01T00:00:01Z"),
        make_tool_result("tr1", Some("a1"), "2026-01-01T00:00:02Z", "p1"),
    ];

    let result = linearize(records);
    assert_eq!(result.len(), 3);
    assert_eq!(result[2].turn, 1); // tool result inherits turn
}

#[test]
fn orphan_records_skipped() {
    // orphan has parentUuid pointing to nonexistent node
    let records = vec![
        make_user("u1", None, "2026-01-01T00:00:00Z", "p1"),
        make_assistant("orphan", Some("nonexistent"), "2026-01-01T00:00:01Z"),
    ];

    let result = linearize(records);
    // orphan is never reached because the tree walk starts from root
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].record.uuid.as_deref(), Some("u1"));
}
