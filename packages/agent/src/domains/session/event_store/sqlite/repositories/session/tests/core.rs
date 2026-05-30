use super::*;

#[test]
fn create_session() {
    let (conn, ws_id) = setup();
    let sess = create_default_session(&conn, &ws_id);

    assert!(sess.id.starts_with("sess_"));
    assert_eq!(sess.workspace_id, ws_id);
    assert_eq!(sess.latest_model, "claude-opus-4-6");
    assert_eq!(sess.title.as_deref(), Some("Test Session"));
    assert_eq!(sess.profile, crate::shared::profile::NORMAL_PROFILE);
    assert_eq!(sess.event_count, 0);
    assert!(sess.ended_at.is_none());
}

#[test]
fn create_session_with_profile_round_trips() {
    let (conn, ws_id) = setup();
    let sess = SessionRepo::create(
        &conn,
        &CreateSessionOptions {
            workspace_id: &ws_id,
            model: "llama3.2",
            working_directory: "/tmp/test",
            title: Some("Local Session"),
            tags: None,
            parent_session_id: None,
            fork_from_event_id: None,
            spawning_session_id: None,
            spawn_type: None,
            spawn_task: None,
            origin: None,
            source: None,
            profile: Some(crate::shared::profile::LOCAL_PROFILE),
            use_worktree: None,
        },
    )
    .unwrap();

    assert_eq!(sess.profile, crate::shared::profile::LOCAL_PROFILE);
    let fetched = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
    assert_eq!(fetched.profile, crate::shared::profile::LOCAL_PROFILE);
}

fn create_session_with_use_worktree(
    conn: &Connection,
    ws_id: &str,
    use_worktree: Option<bool>,
) -> SessionRow {
    SessionRepo::create(
        conn,
        &CreateSessionOptions {
            workspace_id: ws_id,
            model: "claude-opus-4-6",
            working_directory: "/tmp/test",
            title: Some("Override Test"),
            tags: None,
            parent_session_id: None,
            fork_from_event_id: None,
            spawning_session_id: None,
            spawn_type: None,
            spawn_task: None,
            origin: None,
            profile: None,
            source: None,
            use_worktree,
        },
    )
    .unwrap()
}

#[test]
fn create_session_default_use_worktree_is_none() {
    let (conn, ws_id) = setup();
    let sess = create_default_session(&conn, &ws_id);
    assert!(sess.use_worktree.is_none());

    // Round-trip through get_by_id.
    let fetched = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
    assert!(fetched.use_worktree.is_none());
}

#[test]
fn create_session_with_use_worktree_true_round_trips() {
    let (conn, ws_id) = setup();
    let sess = create_session_with_use_worktree(&conn, &ws_id, Some(true));
    assert_eq!(sess.use_worktree, Some(true));

    let fetched = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
    assert_eq!(fetched.use_worktree, Some(true));
}

#[test]
fn create_session_with_use_worktree_false_round_trips() {
    let (conn, ws_id) = setup();
    let sess = create_session_with_use_worktree(&conn, &ws_id, Some(false));
    assert_eq!(sess.use_worktree, Some(false));

    let fetched = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
    assert_eq!(fetched.use_worktree, Some(false));
}

#[test]
fn get_by_id() {
    let (conn, ws_id) = setup();
    let sess = create_default_session(&conn, &ws_id);

    let found = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
    assert_eq!(found.id, sess.id);
    assert_eq!(found.latest_model, "claude-opus-4-6");
}

#[test]
fn get_by_id_not_found() {
    let (conn, _) = setup();
    let found = SessionRepo::get_by_id(&conn, "sess_nonexistent").unwrap();
    assert!(found.is_none());
}

#[test]
fn list_sessions() {
    let (conn, ws_id) = setup();
    create_default_session(&conn, &ws_id);
    create_default_session(&conn, &ws_id);

    let sessions = SessionRepo::list(&conn, &ListSessionsOptions::default()).unwrap();
    assert_eq!(sessions.len(), 2);
}

#[test]
fn list_by_workspace() {
    let (conn, ws_id) = setup();
    create_default_session(&conn, &ws_id);

    let ws2 = WorkspaceRepo::create(
        &conn,
        &CreateWorkspaceOptions {
            path: "/tmp/other",
            name: None,
        },
    )
    .unwrap();
    SessionRepo::create(
        &conn,
        &CreateSessionOptions {
            workspace_id: &ws2.id,
            model: "claude-3",
            working_directory: "/tmp/other",
            title: None,
            tags: None,
            parent_session_id: None,
            fork_from_event_id: None,
            spawning_session_id: None,
            spawn_type: None,
            spawn_task: None,
            origin: None,
            profile: None,
            source: None,
            use_worktree: None,
        },
    )
    .unwrap();

    let sessions = SessionRepo::list(
        &conn,
        &ListSessionsOptions {
            workspace_id: Some(&ws_id),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(sessions.len(), 1);
}

#[test]
fn list_by_working_directory_and_offset() {
    let (conn, ws_id) = setup();
    create_default_session(&conn, &ws_id);

    let ws2 = WorkspaceRepo::create(
        &conn,
        &CreateWorkspaceOptions {
            path: "/tmp/other",
            name: None,
        },
    )
    .unwrap();
    SessionRepo::create(
        &conn,
        &CreateSessionOptions {
            workspace_id: &ws2.id,
            model: "claude-3",
            working_directory: "/tmp/other",
            title: None,
            tags: None,
            parent_session_id: None,
            fork_from_event_id: None,
            spawning_session_id: None,
            spawn_type: None,
            spawn_task: None,
            origin: None,
            profile: None,
            source: None,
            use_worktree: None,
        },
    )
    .unwrap();

    let filtered = SessionRepo::list(
        &conn,
        &ListSessionsOptions {
            working_directory: Some("/tmp/other"),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(filtered.len(), 1);
    assert_eq!(filtered[0].working_directory, "/tmp/other");

    let paged = SessionRepo::list(
        &conn,
        &ListSessionsOptions {
            limit: Some(1),
            offset: Some(1),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(paged.len(), 1);

    let offset_without_limit = SessionRepo::list(
        &conn,
        &ListSessionsOptions {
            offset: Some(1),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(offset_without_limit.len(), 1);
}

#[test]
fn list_ended_filter() {
    let (conn, ws_id) = setup();
    let s1 = create_default_session(&conn, &ws_id);
    create_default_session(&conn, &ws_id);

    SessionRepo::mark_ended(&conn, &s1.id).unwrap();

    let active = SessionRepo::list(
        &conn,
        &ListSessionsOptions {
            ended: Some(false),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(active.len(), 1);

    let ended = SessionRepo::list(
        &conn,
        &ListSessionsOptions {
            ended: Some(true),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(ended.len(), 1);
}

#[test]
fn update_head_and_root() {
    let (conn, ws_id) = setup();
    let sess = create_default_session(&conn, &ws_id);

    SessionRepo::update_head(&conn, &sess.id, "evt_head").unwrap();
    SessionRepo::update_root(&conn, &sess.id, "evt_root").unwrap();

    let found = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
    assert_eq!(found.head_event_id.as_deref(), Some("evt_head"));
    assert_eq!(found.root_event_id.as_deref(), Some("evt_root"));
}

#[test]
fn mark_and_clear_ended() {
    let (conn, ws_id) = setup();
    let sess = create_default_session(&conn, &ws_id);

    SessionRepo::mark_ended(&conn, &sess.id).unwrap();
    let found = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
    assert!(found.ended_at.is_some());

    SessionRepo::clear_ended(&conn, &sess.id).unwrap();
    let found = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
    assert!(found.ended_at.is_none());
}

#[test]
fn update_latest_model() {
    let (conn, ws_id) = setup();
    let sess = create_default_session(&conn, &ws_id);

    SessionRepo::update_latest_model(&conn, &sess.id, "claude-sonnet-4-5-20250929").unwrap();
    let found = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
    assert_eq!(found.latest_model, "claude-sonnet-4-5-20250929");
}

#[test]
fn update_title() {
    let (conn, ws_id) = setup();
    let sess = create_default_session(&conn, &ws_id);

    SessionRepo::update_title(&conn, &sess.id, Some("New Title")).unwrap();
    let found = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
    assert_eq!(found.title.as_deref(), Some("New Title"));

    SessionRepo::update_title(&conn, &sess.id, None).unwrap();
    let found = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
    assert!(found.title.is_none());
}

#[test]
fn update_source() {
    let (conn, ws_id) = setup();
    let sess = create_default_session(&conn, &ws_id);

    SessionRepo::update_source(&conn, &sess.id, "cron").unwrap();
    let found = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
    assert_eq!(found.source.as_deref(), Some("cron"));
}

#[test]
fn update_spawn_info() {
    let (conn, ws_id) = setup();
    let parent = create_default_session(&conn, &ws_id);
    let child = create_default_session(&conn, &ws_id);

    SessionRepo::update_spawn_info(&conn, &child.id, &parent.id, "query", "summarize history")
        .unwrap();

    let found = SessionRepo::get_by_id(&conn, &child.id).unwrap().unwrap();
    assert_eq!(
        found.spawning_session_id.as_deref(),
        Some(parent.id.as_str())
    );
    assert_eq!(found.spawn_type.as_deref(), Some("query"));
    assert_eq!(found.spawn_task.as_deref(), Some("summarize history"));
}

#[test]
fn increment_counters() {
    let (conn, ws_id) = setup();
    let sess = create_default_session(&conn, &ws_id);

    SessionRepo::increment_counters(
        &conn,
        &sess.id,
        &IncrementCounters {
            event_count: Some(5),
            message_count: Some(2),
            turn_count: Some(1),
            input_tokens: Some(1000),
            output_tokens: Some(500),
            cost: Some(0.05),
            cache_read_tokens: Some(200),
            ..Default::default()
        },
    )
    .unwrap();

    let found = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
    assert_eq!(found.event_count, 5);
    assert_eq!(found.message_count, 2);
    assert_eq!(found.turn_count, 1);
    assert_eq!(found.total_input_tokens, 1000);
    assert_eq!(found.total_output_tokens, 500);
    assert!((found.total_cost - 0.05).abs() < f64::EPSILON);
    assert_eq!(found.total_cache_read_tokens, 200);
}

#[test]
fn increment_counters_accumulates() {
    let (conn, ws_id) = setup();
    let sess = create_default_session(&conn, &ws_id);

    SessionRepo::increment_counters(
        &conn,
        &sess.id,
        &IncrementCounters {
            event_count: Some(3),
            ..Default::default()
        },
    )
    .unwrap();
    SessionRepo::increment_counters(
        &conn,
        &sess.id,
        &IncrementCounters {
            event_count: Some(2),
            ..Default::default()
        },
    )
    .unwrap();

    let found = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
    assert_eq!(found.event_count, 5);
}

#[test]
fn last_turn_input_tokens_is_set_not_increment() {
    let (conn, ws_id) = setup();
    let sess = create_default_session(&conn, &ws_id);

    SessionRepo::increment_counters(
        &conn,
        &sess.id,
        &IncrementCounters {
            last_turn_input_tokens: Some(500),
            ..Default::default()
        },
    )
    .unwrap();
    SessionRepo::increment_counters(
        &conn,
        &sess.id,
        &IncrementCounters {
            last_turn_input_tokens: Some(300),
            ..Default::default()
        },
    )
    .unwrap();

    let found = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
    assert_eq!(found.last_turn_input_tokens, 300); // SET, not 800
}

#[test]
fn exists_session() {
    let (conn, ws_id) = setup();
    let sess = create_default_session(&conn, &ws_id);

    assert!(SessionRepo::exists(&conn, &sess.id).unwrap());
    assert!(!SessionRepo::exists(&conn, "sess_nonexistent").unwrap());
}

#[test]
fn delete_session() {
    let (conn, ws_id) = setup();
    let sess = create_default_session(&conn, &ws_id);

    assert!(SessionRepo::delete(&conn, &sess.id).unwrap());
    assert!(!SessionRepo::exists(&conn, &sess.id).unwrap());
}

#[test]
fn list_subagents() {
    let (conn, ws_id) = setup();
    let parent = create_default_session(&conn, &ws_id);

    SessionRepo::create(
        &conn,
        &CreateSessionOptions {
            workspace_id: &ws_id,
            model: "claude-3",
            working_directory: "/tmp/test",
            title: None,
            tags: None,
            parent_session_id: None,
            fork_from_event_id: None,
            spawning_session_id: Some(&parent.id),
            spawn_type: Some("query"),
            spawn_task: Some("do something"),
            origin: None,
            profile: None,
            source: None,
            use_worktree: None,
        },
    )
    .unwrap();

    let subagents = SessionRepo::list_subagents(&conn, &parent.id).unwrap();
    assert_eq!(subagents.len(), 1);
    assert_eq!(subagents[0].spawn_type.as_deref(), Some("query"));
}

#[test]
fn exclude_subagents_filter() {
    let (conn, ws_id) = setup();
    let parent = create_default_session(&conn, &ws_id);

    SessionRepo::create(
        &conn,
        &CreateSessionOptions {
            workspace_id: &ws_id,
            model: "claude-3",
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

    let all = SessionRepo::list(&conn, &ListSessionsOptions::default()).unwrap();
    assert_eq!(all.len(), 2);

    let no_subagents = SessionRepo::list(
        &conn,
        &ListSessionsOptions {
            exclude_subagents: Some(true),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(no_subagents.len(), 1);
}

// ── Batch operations ─────────────────────────────────────────────

#[test]
fn get_by_ids_basic() {
    let (conn, ws_id) = setup();
    let s1 = create_default_session(&conn, &ws_id);
    let s2 = create_default_session(&conn, &ws_id);

    let ids = [s1.id.as_str(), s2.id.as_str()];
    let map = SessionRepo::get_by_ids(&conn, &ids).unwrap();
    assert_eq!(map.len(), 2);
    assert!(map.contains_key(&s1.id));
    assert!(map.contains_key(&s2.id));
}

#[test]
fn get_by_ids_empty() {
    let (conn, _) = setup();
    let map = SessionRepo::get_by_ids(&conn, &[]).unwrap();
    assert!(map.is_empty());
}

#[test]
fn get_by_ids_missing_ids_omitted() {
    let (conn, ws_id) = setup();
    let s1 = create_default_session(&conn, &ws_id);

    let ids = [s1.id.as_str(), "sess_nonexistent"];
    let map = SessionRepo::get_by_ids(&conn, &ids).unwrap();
    assert_eq!(map.len(), 1);
    assert!(map.contains_key(&s1.id));
}
