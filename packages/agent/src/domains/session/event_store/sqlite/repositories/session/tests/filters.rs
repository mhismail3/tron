use super::*;

// ── Origin tracking ─────────────────────────────────────────────

#[test]
fn create_session_with_origin() {
    let (conn, ws_id) = setup();
    let sess = SessionRepo::create(
        &conn,
        &CreateSessionOptions {
            workspace_id: &ws_id,
            model: "claude-opus-4-6",
            working_directory: "/tmp/test",
            title: None,
            tags: None,
            parent_session_id: None,
            fork_from_event_id: None,
            spawning_session_id: None,
            spawn_type: None,
            spawn_task: None,
            origin: Some("localhost:9847"),
            profile: None,
            source: None,
            use_worktree: None,
        },
    )
    .unwrap();
    assert_eq!(sess.origin.as_deref(), Some("localhost:9847"));

    let found = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
    assert_eq!(found.origin.as_deref(), Some("localhost:9847"));
}

#[test]
fn create_session_without_origin() {
    let (conn, ws_id) = setup();
    let sess = create_default_session(&conn, &ws_id);
    assert!(sess.origin.is_none());

    let found = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
    assert!(found.origin.is_none());
}

#[test]
fn list_sessions_filter_by_origin() {
    let (conn, ws_id) = setup();

    SessionRepo::create(
        &conn,
        &CreateSessionOptions {
            workspace_id: &ws_id,
            model: "claude-opus-4-6",
            working_directory: "/tmp/test",
            title: None,
            tags: None,
            parent_session_id: None,
            fork_from_event_id: None,
            spawning_session_id: None,
            spawn_type: None,
            spawn_task: None,
            origin: Some("localhost:9847"),
            profile: None,
            source: None,
            use_worktree: None,
        },
    )
    .unwrap();
    SessionRepo::create(
        &conn,
        &CreateSessionOptions {
            workspace_id: &ws_id,
            model: "claude-opus-4-6",
            working_directory: "/tmp/test",
            title: None,
            tags: None,
            parent_session_id: None,
            fork_from_event_id: None,
            spawning_session_id: None,
            spawn_type: None,
            spawn_task: None,
            origin: Some("localhost:9846"),
            profile: None,
            source: None,
            use_worktree: None,
        },
    )
    .unwrap();

    let prod = SessionRepo::list(
        &conn,
        &ListSessionsOptions {
            origin: Some("localhost:9847"),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(prod.len(), 1);
    assert_eq!(prod[0].origin.as_deref(), Some("localhost:9847"));

    let dev = SessionRepo::list(
        &conn,
        &ListSessionsOptions {
            origin: Some("localhost:9846"),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(dev.len(), 1);
}

#[test]
fn list_sessions_no_origin_filter() {
    let (conn, ws_id) = setup();

    SessionRepo::create(
        &conn,
        &CreateSessionOptions {
            workspace_id: &ws_id,
            model: "claude-opus-4-6",
            working_directory: "/tmp/test",
            title: None,
            tags: None,
            parent_session_id: None,
            fork_from_event_id: None,
            spawning_session_id: None,
            spawn_type: None,
            spawn_task: None,
            origin: Some("localhost:9847"),
            profile: None,
            source: None,
            use_worktree: None,
        },
    )
    .unwrap();
    SessionRepo::create(
        &conn,
        &CreateSessionOptions {
            workspace_id: &ws_id,
            model: "claude-opus-4-6",
            working_directory: "/tmp/test",
            title: None,
            tags: None,
            parent_session_id: None,
            fork_from_event_id: None,
            spawning_session_id: None,
            spawn_type: None,
            spawn_task: None,
            origin: Some("localhost:9846"),
            profile: None,
            source: None,
            use_worktree: None,
        },
    )
    .unwrap();

    let all = SessionRepo::list(&conn, &ListSessionsOptions::default()).unwrap();
    assert_eq!(all.len(), 2);
}

// ── Source filtering ────────────────────────────────────────────

#[test]
fn create_session_with_source() {
    let (conn, ws_id) = setup();
    let sess = SessionRepo::create(
        &conn,
        &CreateSessionOptions {
            workspace_id: &ws_id,
            model: "claude-opus-4-6",
            working_directory: "/tmp/test",
            title: Some("Cron: daily"),
            tags: None,
            parent_session_id: None,
            fork_from_event_id: None,
            spawning_session_id: None,
            spawn_type: None,
            spawn_task: None,
            origin: None,
            profile: None,
            source: Some("cron"),
            use_worktree: None,
        },
    )
    .unwrap();
    assert_eq!(sess.source.as_deref(), Some("cron"));

    let found = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
    assert_eq!(found.source.as_deref(), Some("cron"));
}

#[test]
fn create_session_without_source() {
    let (conn, ws_id) = setup();
    let sess = create_default_session(&conn, &ws_id);
    assert!(sess.source.is_none());

    let found = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
    assert!(found.source.is_none());
}

#[test]
fn list_user_only_excludes_cron() {
    let (conn, ws_id) = setup();
    create_default_session(&conn, &ws_id);
    create_default_session(&conn, &ws_id);
    SessionRepo::create(
        &conn,
        &CreateSessionOptions {
            workspace_id: &ws_id,
            model: "claude-opus-4-6",
            working_directory: "/tmp/test",
            title: Some("Cron: daily"),
            tags: None,
            parent_session_id: None,
            fork_from_event_id: None,
            spawning_session_id: None,
            spawn_type: None,
            spawn_task: None,
            origin: None,
            profile: None,
            source: Some("cron"),
            use_worktree: None,
        },
    )
    .unwrap();

    let user_only = SessionRepo::list(
        &conn,
        &ListSessionsOptions {
            user_only: Some(true),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(user_only.len(), 2);
}

#[test]
fn list_without_user_only_shows_all() {
    let (conn, ws_id) = setup();
    create_default_session(&conn, &ws_id);
    SessionRepo::create(
        &conn,
        &CreateSessionOptions {
            workspace_id: &ws_id,
            model: "claude-opus-4-6",
            working_directory: "/tmp/test",
            title: Some("Cron: daily"),
            tags: None,
            parent_session_id: None,
            fork_from_event_id: None,
            spawning_session_id: None,
            spawn_type: None,
            spawn_task: None,
            origin: None,
            profile: None,
            source: Some("cron"),
            use_worktree: None,
        },
    )
    .unwrap();

    let all = SessionRepo::list(&conn, &ListSessionsOptions::default()).unwrap();
    assert_eq!(all.len(), 2);
}

#[test]
fn list_user_only_with_subagent_filter() {
    let (conn, ws_id) = setup();
    let parent = create_default_session(&conn, &ws_id);

    // Cron session
    SessionRepo::create(
        &conn,
        &CreateSessionOptions {
            workspace_id: &ws_id,
            model: "claude-opus-4-6",
            working_directory: "/tmp/test",
            title: Some("Cron: daily"),
            tags: None,
            parent_session_id: None,
            fork_from_event_id: None,
            spawning_session_id: None,
            spawn_type: None,
            spawn_task: None,
            origin: None,
            profile: None,
            source: Some("cron"),
            use_worktree: None,
        },
    )
    .unwrap();

    // Subagent session
    SessionRepo::create(
        &conn,
        &CreateSessionOptions {
            workspace_id: &ws_id,
            model: "claude-opus-4-6",
            working_directory: "/tmp/test",
            title: None,
            tags: None,
            parent_session_id: None,
            fork_from_event_id: None,
            spawning_session_id: Some(&parent.id),
            spawn_type: Some("query"),
            spawn_task: None,
            origin: None,
            profile: None,
            source: None,
            use_worktree: None,
        },
    )
    .unwrap();

    // Both filters stack: user_only + exclude_subagents
    let filtered = SessionRepo::list(
        &conn,
        &ListSessionsOptions {
            user_only: Some(true),
            exclude_subagents: Some(true),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(filtered.len(), 1);
    assert_eq!(filtered[0].id, parent.id);
}

#[test]
fn list_user_only_with_archived_filter() {
    let (conn, ws_id) = setup();
    let user_sess = create_default_session(&conn, &ws_id);
    SessionRepo::create(
        &conn,
        &CreateSessionOptions {
            workspace_id: &ws_id,
            model: "claude-opus-4-6",
            working_directory: "/tmp/test",
            title: Some("Cron: daily"),
            tags: None,
            parent_session_id: None,
            fork_from_event_id: None,
            spawning_session_id: None,
            spawn_type: None,
            spawn_task: None,
            origin: None,
            profile: None,
            source: Some("cron"),
            use_worktree: None,
        },
    )
    .unwrap();

    SessionRepo::mark_ended(&conn, &user_sess.id).unwrap();

    // user_only + ended filter
    let ended_user = SessionRepo::list(
        &conn,
        &ListSessionsOptions {
            user_only: Some(true),
            ended: Some(true),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(ended_user.len(), 1);
    assert_eq!(ended_user[0].id, user_sess.id);
}
