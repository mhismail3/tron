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
fn activity_summary_batch_is_bounded_per_session_and_uses_sequence_index() {
    let (conn, ws_id) = setup();
    let first = create_default_session(&conn, &ws_id);
    let second = create_default_session(&conn, &ws_id);
    for session in [&first, &second] {
        for sequence in 1..=30 {
            insert_event(
                &conn,
                &session.id,
                &ws_id,
                sequence,
                "message.user",
                &format!(r#"{{"content":"{}-{sequence}"}}"#, session.id),
            );
        }
    }

    let ids = [first.id.as_str(), second.id.as_str()];
    let summaries = SessionRepo::get_activity_summaries_batch(&conn, &ids).unwrap();
    for session in [&first, &second] {
        let lines = &summaries[&session.id];
        assert_eq!(lines.len(), 5);
        assert_eq!(
            lines.last().and_then(|line| line.text.as_deref()),
            Some(format!("{}-30", session.id).as_str())
        );
    }

    let sql = super::super::projections::activity_summary_batch_sql(ids.len());
    let explain = format!("EXPLAIN QUERY PLAN {sql}");
    let params = ids
        .iter()
        .map(|session_id| session_id as &dyn rusqlite::types::ToSql)
        .collect::<Vec<_>>();
    let mut statement = conn.prepare(&explain).unwrap();
    let plan = statement
        .query_map(params.as_slice(), |row| row.get::<_, String>(3))
        .unwrap()
        .collect::<std::result::Result<Vec<_>, _>>()
        .unwrap()
        .join("\n");
    assert!(
        plan.contains("idx_events_session_seq"),
        "bounded recent-event projection missed the sequence index:\n{plan}"
    );
    assert!(
        plan.contains("CORRELATED LIST SUBQUERY"),
        "projection is no longer one bounded correlated batch query:\n{plan}"
    );
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
        r#"{"content": [{"type": "text", "text": "hi"}, {"type": "capability_invocation", "name": "execute"}]}"#,
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
