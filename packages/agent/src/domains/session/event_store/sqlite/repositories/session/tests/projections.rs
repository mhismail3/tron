use super::*;

// ── Message previews ─────────────────────────────────────────────

fn insert_event(
    conn: &Connection,
    session_id: &str,
    ws_id: &str,
    seq: i64,
    event_type: &str,
    payload: &str,
) {
    conn.execute(
        "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id)
         VALUES (?1, ?2, ?3, ?4, datetime('now'), ?5, ?6)",
        rusqlite::params![
            format!("evt_{seq}_{session_id}"),
            session_id,
            seq,
            event_type,
            payload,
            ws_id,
        ],
    )
    .unwrap();
}

#[test]
fn get_message_previews_basic() {
    let (conn, ws_id) = setup();
    let s1 = create_default_session(&conn, &ws_id);

    insert_event(
        &conn,
        &s1.id,
        &ws_id,
        1,
        "message.user",
        r#"{"content": "Hello world"}"#,
    );
    insert_event(
        &conn,
        &s1.id,
        &ws_id,
        2,
        "message.assistant",
        r#"{"content": "Hi there!"}"#,
    );

    let ids = [s1.id.as_str()];
    let previews = SessionRepo::get_message_previews(&conn, &ids).unwrap();
    let preview = previews.get(&s1.id).unwrap();
    assert_eq!(preview.last_user_prompt.as_deref(), Some("Hello world"));
    assert_eq!(
        preview.last_assistant_response.as_deref(),
        Some("Hi there!")
    );
}

#[test]
fn get_message_previews_array_content() {
    let (conn, ws_id) = setup();
    let s1 = create_default_session(&conn, &ws_id);

    insert_event(
        &conn,
        &s1.id,
        &ws_id,
        1,
        "message.user",
        r#"{"content": "Hello"}"#,
    );
    insert_event(
        &conn,
        &s1.id,
        &ws_id,
        2,
        "message.assistant",
        r#"{"content": [{"type": "text", "text": "Part 1"}, {"type": "text", "text": " Part 2"}]}"#,
    );

    let ids = [s1.id.as_str()];
    let previews = SessionRepo::get_message_previews(&conn, &ids).unwrap();
    let preview = previews.get(&s1.id).unwrap();
    assert_eq!(
        preview.last_assistant_response.as_deref(),
        Some("Part 1 Part 2")
    );
}

#[test]
fn get_message_previews_uses_latest() {
    let (conn, ws_id) = setup();
    let s1 = create_default_session(&conn, &ws_id);

    insert_event(
        &conn,
        &s1.id,
        &ws_id,
        1,
        "message.user",
        r#"{"content": "First"}"#,
    );
    insert_event(
        &conn,
        &s1.id,
        &ws_id,
        2,
        "message.user",
        r#"{"content": "Second"}"#,
    );

    let ids = [s1.id.as_str()];
    let previews = SessionRepo::get_message_previews(&conn, &ids).unwrap();
    let preview = previews.get(&s1.id).unwrap();
    assert_eq!(preview.last_user_prompt.as_deref(), Some("Second"));
}

#[test]
fn get_message_previews_empty() {
    let (conn, _) = setup();
    let previews = SessionRepo::get_message_previews(&conn, &[]).unwrap();
    assert!(previews.is_empty());
}

#[test]
fn get_message_previews_no_messages() {
    let (conn, ws_id) = setup();
    let s1 = create_default_session(&conn, &ws_id);

    let ids = [s1.id.as_str()];
    let previews = SessionRepo::get_message_previews(&conn, &ids).unwrap();
    let preview = previews.get(&s1.id).unwrap();
    assert!(preview.last_user_prompt.is_none());
    assert!(preview.last_assistant_response.is_none());
}

#[test]
fn get_message_previews_multiple_sessions() {
    let (conn, ws_id) = setup();
    let s1 = create_default_session(&conn, &ws_id);
    let s2 = create_default_session(&conn, &ws_id);

    insert_event(
        &conn,
        &s1.id,
        &ws_id,
        1,
        "message.user",
        r#"{"content": "S1 user"}"#,
    );
    insert_event(
        &conn,
        &s2.id,
        &ws_id,
        1,
        "message.user",
        r#"{"content": "S2 user"}"#,
    );

    let ids = [s1.id.as_str(), s2.id.as_str()];
    let previews = SessionRepo::get_message_previews(&conn, &ids).unwrap();
    assert_eq!(
        previews.get(&s1.id).unwrap().last_user_prompt.as_deref(),
        Some("S1 user")
    );
    assert_eq!(
        previews.get(&s2.id).unwrap().last_user_prompt.as_deref(),
        Some("S2 user")
    );
}

#[test]
fn activity_summary_batch_matches_single_queries_and_uses_one_json_parameter() {
    let (conn, ws_id) = setup();
    let first = create_default_session(&conn, &ws_id);
    let second = create_default_session(&conn, &ws_id);
    insert_event(
        &conn,
        &first.id,
        &ws_id,
        1,
        "message.user",
        r#"{"content":"first"}"#,
    );
    insert_event(
        &conn,
        &second.id,
        &ws_id,
        1,
        "message.user",
        r#"{"content":"second"}"#,
    );

    let ids = [first.id.as_str(), second.id.as_str()];
    let batch = SessionRepo::get_activity_summaries_batch(&conn, &ids).unwrap();
    for session_id in ids {
        assert_eq!(
            batch.get(session_id).unwrap(),
            &SessionRepo::get_activity_summaries(&conn, session_id).unwrap()
        );
    }

    let many_ids = (0..2_000)
        .map(|index| format!("missing-{index}"))
        .collect::<Vec<_>>();
    let many_refs = many_ids.iter().map(String::as_str).collect::<Vec<_>>();
    let empty = SessionRepo::get_activity_summaries_batch(&conn, &many_refs).unwrap();
    assert_eq!(empty.len(), 2_000);
    assert!(empty.values().all(Vec::is_empty));
}

// ── Text extraction helper ───────────────────────────────────────

#[test]
fn extract_text_string_content() {
    let text = extract_text_from_payload(r#"{"content": "hello"}"#);
    assert_eq!(text, "hello");
}

#[test]
fn extract_text_array_content() {
    let text = extract_text_from_payload(
        r#"{"content": [{"type": "text", "text": "a"}, {"type": "text", "text": "b"}]}"#,
    );
    assert_eq!(text, "ab");
}

#[test]
fn extract_text_skips_non_text_blocks() {
    let text = extract_text_from_payload(
        r#"{"content": [{"type": "text", "text": "hi"}, {"type": "tool_invocation", "name": "test_tool"}]}"#,
    );
    assert_eq!(text, "hi");
}

#[test]
fn extract_text_invalid_json() {
    let text = extract_text_from_payload("not json");
    assert_eq!(text, "");
}

#[test]
fn extract_text_missing_content() {
    let text = extract_text_from_payload(r#"{"other": "field"}"#);
    assert_eq!(text, "");
}
