use super::support::*;

#[test]
fn sol_session_event_store_lifecycle_is_source_backed() {
    let lifecycle_mod = read_repo_file("packages/agent/src/domains/session/lifecycle/mod.rs");
    for required in [
        "## Submodules",
        "`archive`",
        "`create`",
        "`delete`",
        "`fork`",
        "Archive/unarchive is reversible session-row state (`ended_at`)",
        "Deleting a session is the only physical event-row cleanup path",
        "Fork-inherited ancestor history stays",
        "`message.deleted` event",
        "Runtime sequence counters and compaction handlers are projections",
    ] {
        assert!(
            lifecycle_mod.contains(required),
            "session lifecycle module docs missing `{required}`"
        );
    }

    let session_manager =
        read_repo_file("packages/agent/src/domains/agent/loop/orchestrator/session_manager/mod.rs");
    assert_contains_in_order(
        "session manager create/resume/end lifecycle",
        &session_manager,
        &[
            "pub(crate) fn create_session",
            ".create_session(model, workspace_path, title, None)",
            "cached_sessions",
            "pub(in crate::domains) fn resume_session",
            "session_reconstructor::reconstruct",
            "fn end_session",
            "cached_sessions.remove(session_id)",
            ".append(&AppendOptions",
            "EventType::SessionEnd",
            ".end_session(session_id)",
        ],
    );
    for required in [
        "pub(in crate::domains) fn archive_session",
        "cached_sessions.remove(session_id)",
        ".end_session(session_id)",
        "pub(in crate::domains) fn delete_session",
        ".delete_session(session_id)",
        "pub(crate) fn evict_idle_sessions",
        "retain(|session_id, cached|",
        "pub(in crate::domains::agent) fn resume_session_for_prompt",
        "pub(in crate::domains) fn invalidate_session",
    ] {
        assert!(
            session_manager.contains(required),
            "session manager lifecycle missing `{required}`"
        );
    }

    let lifecycle = read_repo_file(
        "packages/agent/src/domains/session/event_store/store/event_store/session_lifecycle.rs",
    );
    assert_contains_in_order(
        "event store create session transaction",
        &lifecycle,
        &[
            "create_session_in_tx_with_identity",
            "WorkspaceRepo::get_or_create_with_identity",
            "SessionRepo::create_with_identity",
            "EventType::SessionStart",
            "sequence: 0",
            "EventRepo::insert(tx, &event)",
            "SessionRepo::update_root",
            "SessionRepo::update_head_at",
            "SessionRepo::increment_counters_at",
            "tx.commit()",
        ],
    );
    assert_contains_in_order(
        "event store fork transaction",
        &lifecycle,
        &[
            "pub fn fork_with_identity",
            "EventRepo::get_by_id(&tx, from_event_id)",
            "SessionRepo::get_by_id(&tx, &source_event.session_id)",
            "parent_session_id: Some(&source_session.id)",
            "fork_from_event_id: Some(from_event_id)",
            "parent_id: Some(from_event_id.to_string())",
            "EventType::SessionFork",
            "EventRepo::insert(&tx, &fork_event)",
            "SessionRepo::update_root",
            "SessionRepo::update_head_at",
            "tx.commit()",
        ],
    );
    assert_contains_in_order(
        "event store archive/delete lifecycle",
        &lifecycle,
        &[
            "pub fn end_session",
            "with_session_write_lock(session_id",
            "SessionRepo::mark_ended",
            "pub fn clear_session_ended",
            "SessionRepo::clear_ended",
            "pub fn delete_session",
            "EventRepo::delete_by_session",
            "SessionRepo::delete",
            "tx.commit()",
            "self.remove_session_write_lock(session_id)",
            "pub(crate) fn get_session_message_previews(",
            "pub(crate) fn get_session_activity_summaries(",
            "pub(crate) fn get_session_activity_summaries_batch(",
        ],
    );

    let event_log = read_repo_file(
        "packages/agent/src/domains/session/event_store/store/event_store/event_log.rs",
    );
    for required in [
        "with_session_write_lock(opts.session_id",
        "SELECT MAX(sequence) FROM events WHERE session_id = ?1",
        "UNIQUE(session_id, sequence)",
        "EventRepo::insert(tx, &event)",
        "SessionRepo::update_head",
        "SessionRepo::increment_counters",
        "EventType::MessageDeleted",
    ] {
        assert!(
            event_log.contains(required),
            "event append lifecycle missing `{required}`"
        );
    }

    let event_repo = read_repo_file(
        "packages/agent/src/domains/session/event_store/sqlite/repositories/event/crud.rs",
    );
    for required in ["store_json_value", "\"session_event\"", "\"audit\""] {
        assert!(
            event_repo.contains(required),
            "event repository payload lifecycle missing `{required}`"
        );
    }
    assert!(
        !event_repo.contains("pub fn delete(conn: &Connection, event_id: &str)"),
        "single-event physical delete must not exist; use message.deleted or session-scoped delete"
    );
    assert!(
        event_repo.contains("pub fn delete_by_session"),
        "session-scoped delete path must remain explicit"
    );

    let event_repo_docs = read_repo_file(
        "packages/agent/src/domains/session/event_store/sqlite/repositories/event/mod.rs",
    );
    assert!(
        event_repo_docs.contains("session-scoped delete"),
        "event repository docs must distinguish session-scoped delete from append-only event lifecycle"
    );

    let schema = read_repo_file(
        "packages/agent/src/domains/session/event_store/sqlite/migrations/v001_schema.sql",
    );
    for required in [
        "CREATE TABLE IF NOT EXISTS sessions",
        "head_event_id",
        "root_event_id",
        "parent_session_id",
        "fork_from_event_id",
        "ended_at",
        "CREATE TABLE IF NOT EXISTS events",
        "session_id            TEXT    NOT NULL REFERENCES sessions(id)",
        "parent_id             TEXT    REFERENCES events(id)",
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_events_session_sequence_unique",
        "ON events(session_id, sequence)",
    ] {
        assert!(
            schema.contains(required),
            "session/event schema missing `{required}`"
        );
    }

    let lifecycle_archive =
        read_repo_file("packages/agent/src/domains/session/lifecycle/archive.rs");
    for required in [
        "SessionLifecycleService::archive",
        "archive_session(&session_id_for_archive)",
        "remove_sequence_counter(&session_id)",
        "remove_compaction_handler(&session_id)",
        "TronEvent::SessionArchived",
        "clear_session_ended(&session_id_for_unarchive)",
        "TronEvent::SessionUnarchived",
        "archive_older_than",
        "ended: Some(false)",
        "Self::archive(deps, session_id.clone()).await",
    ] {
        assert!(
            lifecycle_archive.contains(required),
            "session archive lifecycle missing `{required}`"
        );
    }
    let lifecycle_delete = read_repo_file("packages/agent/src/domains/session/lifecycle/delete.rs");
    for required in [
        "delete_session(&session_id_for_delete)",
        "remove_sequence_counter(&session_id)",
        "remove_compaction_handler(&session_id)",
        "TronEvent::SessionDeleted",
    ] {
        assert!(
            lifecycle_delete.contains(required),
            "session delete lifecycle missing `{required}`"
        );
    }
    let lifecycle_create = read_repo_file("packages/agent/src/domains/session/lifecycle/create.rs");
    for required in [
        "normalize_working_directory",
        "create_session(&model, &stored_working_directory",
        "TronEvent::SessionCreated",
        "init_sequence_counter(&session_id, 0)",
    ] {
        assert!(
            lifecycle_create.contains(required),
            "session create lifecycle missing `{required}`"
        );
    }
    let lifecycle_fork = read_repo_file("packages/agent/src/domains/session/lifecycle/fork.rs");
    for required in [
        "get_session(&session_id_for_fork)",
        "head_event_id",
        "ForkOptions",
        ".fork(",
        "init_sequence_counter(&new_session_id, 0)",
        "TronEvent::SessionForked",
    ] {
        assert!(
            lifecycle_fork.contains(required),
            "session fork lifecycle missing `{required}`"
        );
    }

    let reconstruction = read_repo_file("packages/agent/src/domains/session/reconstruction/mod.rs");
    for required in [
        "MAX_RECONSTRUCT_EVENTS",
        ".clamp(0, MAX_RECONSTRUCT_EVENTS)",
        "session.parent_session_id.is_some()",
        "event_store.get_ancestors(head_id)",
        "paginate_ordered_chain",
        "get_events_before",
        "has_events_before",
        "get_latest_events",
        "resolve_event_payloads",
        "current_sequence(&session_id)",
        "turn_accumulators()",
        ".get_state(&session_id)",
        "Self::reconcile_in_flight",
    ] {
        assert!(
            reconstruction.contains(required),
            "session reconstruction lifecycle missing `{required}`"
        );
    }

    let event_state =
        read_repo_file("packages/agent/src/domains/session/event_store/store/event_store/state.rs");
    for required in [
        "get_messages_at_head",
        "get_ancestors(&conn, head_id)",
        "event_rows_to_session_events_with_conn",
        "resolve_stored_json_value",
        "reconstruct_from_events(&events)",
        "build_session_state",
    ] {
        assert!(
            event_state.contains(required),
            "event-store reconstruction state missing `{required}`"
        );
    }

    let query = read_repo_file("packages/agent/src/domains/session/query/mod.rs");
    for required in [
        "pub(crate) async fn resume",
        "resume_session(&session_id_for_resume)",
        "pub(crate) async fn list",
        "get_session_message_previews",
        "get_session_activity_summaries_batch",
        "pub(crate) async fn export",
        "\"format\": \"tron.session.v1\"",
        "get_events_by_session",
        "resolve_event_payloads",
    ] {
        assert!(
            query.contains(required),
            "session query lifecycle missing `{required}`"
        );
    }

    let session_update =
        read_repo_file("packages/agent/src/domains/agent/runtime/runtime/session_update.rs");
    let update_loader_signature = session_update
        .split_once("pub(in crate::domains::agent::runtime) async fn load_session_update_event(")
        .expect("session-update loader must remain runtime-owned")
        .1
        .split_once(") ->")
        .expect("session-update loader signature missing")
        .0;
    assert!(update_loader_signature.contains("event_store: Arc<EventStore>"));
    assert!(
        !update_loader_signature.contains("session_manager"),
        "durable session-update reads must not advertise session-cache ownership"
    );
    assert!(session_update.contains("TronEvent::SessionUpdated"));
    assert!(!session_update.contains("struct SessionUpdateData"));

    let completion =
        read_repo_file("packages/agent/src/domains/agent/runtime/service/completion.rs");
    assert!(
        !completion.contains("session_manager"),
        "prompt completion must depend on EventStore, not SessionManager"
    );
    assert!(!completion.contains("TronEvent::SessionUpdated"));
}
