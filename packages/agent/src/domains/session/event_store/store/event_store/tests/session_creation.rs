use super::*;
use crate::domains::session::event_store::{
    EventIdentity, SessionCreationIdentity, SessionIdentity, WorkspaceIdentity,
};

// ── Session creation ──────────────────────────────────────────────

#[test]
fn create_session_basic() {
    let store = setup();
    let result = store
        .create_session("claude-opus-4-6", "/tmp/project", Some("Test"), None)
        .unwrap();

    assert!(result.session.id.starts_with("sess_"));
    assert!(result.root_event.id.starts_with("evt_"));
    assert_eq!(result.session.latest_model, "claude-opus-4-6");
    assert_eq!(result.session.title.as_deref(), Some("Test"));
    assert_eq!(result.session.event_count, 1);
    assert_eq!(
        result.session.head_event_id.as_deref(),
        Some(result.root_event.id.as_str())
    );
    assert_eq!(
        result.session.root_event_id.as_deref(),
        Some(result.root_event.id.as_str())
    );
}

#[test]
fn nested_agent_session_is_hidden_until_same_transcript_is_promoted() {
    let store = setup();
    let visible = store
        .create_session("claude-opus-4-6", "/tmp/project", Some("Visible"), None)
        .unwrap();
    let nested = store
        .create_agent_session(
            "claude-opus-4-6",
            "/tmp/project",
            Some("Nested agent"),
            None,
        )
        .unwrap();
    assert!(nested.session.is_agent_session());
    assert!(nested.session.is_internal_session());
    assert!(!nested.session.is_worker_session());

    let ordinary = store
        .list_sessions(&ListSessionsOptions::default())
        .unwrap();
    assert_eq!(ordinary.len(), 1);
    assert_eq!(ordinary[0].id, visible.session.id);

    let promoted = store.promote_agent_session(&nested.session.id).unwrap();
    assert_eq!(promoted.id, nested.session.id);
    assert!(!promoted.is_agent_session());
    assert!(!promoted.is_internal_session());
    let replay = store.promote_agent_session(&nested.session.id).unwrap();
    assert_eq!(replay.id, promoted.id);
    assert_eq!(replay.tags, promoted.tags);
    assert!(
        store
            .promote_agent_session(&visible.session.id)
            .unwrap_err()
            .to_string()
            .contains("not a nested agent transcript"),
        "an ordinary session without a promotion receipt must not be accepted as replay"
    );
    let ordinary = store
        .list_sessions(&ListSessionsOptions::default())
        .unwrap();
    assert_eq!(ordinary.len(), 2);
    assert!(
        ordinary
            .iter()
            .any(|session| session.id == nested.session.id)
    );
}

#[test]
fn create_session_with_identity_persists_explicit_replay_fields() {
    let store = setup();
    let result = store
        .create_session_with_identity(
            "claude-opus-4-6",
            "/tmp/project",
            Some("Test"),
            Some("anthropic"),
            SessionCreationIdentity::new(
                WorkspaceIdentity::new("ws_replay_fixed", "2026-06-09T12:00:00Z"),
                SessionIdentity::new("sess_replay_fixed", "2026-06-09T12:00:01Z"),
                EventIdentity::new("evt_replay_root", "2026-06-09T12:00:02Z"),
            ),
        )
        .unwrap();

    assert_eq!(result.session.id, "sess_replay_fixed");
    assert_eq!(result.session.workspace_id, "ws_replay_fixed");
    assert_eq!(result.session.created_at, "2026-06-09T12:00:01Z");
    assert_eq!(result.session.last_activity_at, "2026-06-09T12:00:02Z");
    assert_eq!(result.root_event.id, "evt_replay_root");
    assert_eq!(result.root_event.timestamp, "2026-06-09T12:00:02Z");
    assert_eq!(
        result.session.head_event_id.as_deref(),
        Some("evt_replay_root")
    );
    assert_eq!(
        result.session.root_event_id.as_deref(),
        Some("evt_replay_root")
    );

    let workspace = store
        .get_workspace_by_path("/tmp/project")
        .unwrap()
        .expect("workspace should exist");
    assert_eq!(workspace.id, "ws_replay_fixed");
    assert_eq!(workspace.created_at, "2026-06-09T12:00:00Z");
    assert_eq!(workspace.last_activity_at, "2026-06-09T12:00:00Z");
}

#[test]
fn create_session_with_explicit_provider() {
    let store = setup();
    let result = store
        .create_session("claude-opus-4-6", "/tmp/project", None, Some("openai"))
        .unwrap();

    let payload_str: String = result.root_event.payload;
    let payload: serde_json::Value = serde_json::from_str(&payload_str).unwrap();
    assert_eq!(
        payload["provider"].as_str(),
        Some("openai"),
        "explicit provider should override model-prefix heuristic"
    );
}

#[test]
fn create_session_creates_workspace() {
    let store = setup();
    store
        .create_session("claude-opus-4-6", "/tmp/project", None, None)
        .unwrap();

    let ws = store.get_workspace_by_path("/tmp/project").unwrap();
    assert!(ws.is_some());
}

#[test]
fn create_session_reuses_workspace() {
    let store = setup();
    let r1 = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None)
        .unwrap();
    let r2 = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None)
        .unwrap();

    assert_eq!(r1.session.workspace_id, r2.session.workspace_id);
    assert_ne!(r1.session.id, r2.session.id);
}

#[test]
fn create_session_root_event_has_correct_fields() {
    let store = setup();
    let result = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None)
        .unwrap();

    assert!(result.root_event.parent_id.is_none());
    assert_eq!(result.root_event.sequence, 0);
    assert_eq!(result.root_event.depth, 0);
    assert_eq!(result.root_event.event_type, "session.start");
    assert_eq!(result.root_event.session_id, result.session.id);
}

#[test]
fn create_session_detects_ollama_provider() {
    let store = setup();
    let result = store
        .create_session("gemma4:e4b", "/tmp/project", None, None)
        .unwrap();

    let payload_str: String = result.root_event.payload;
    let payload: serde_json::Value = serde_json::from_str(&payload_str).unwrap();
    assert_eq!(
        payload["provider"].as_str(),
        Some("ollama"),
        "gemma4:e4b should be detected as Ollama provider, not anthropic"
    );
}

#[test]
fn create_session_detects_anthropic_provider() {
    let store = setup();
    let result = store
        .create_session("claude-opus-4-6", "/tmp/project", None, None)
        .unwrap();

    let payload_str: String = result.root_event.payload;
    let payload: serde_json::Value = serde_json::from_str(&payload_str).unwrap();
    assert_eq!(payload["provider"].as_str(), Some("anthropic"));
}

#[test]
fn create_session_detects_google_provider() {
    let store = setup();
    let result = store
        .create_session("gemini-2.5-flash", "/tmp/project", None, None)
        .unwrap();

    let payload_str: String = result.root_event.payload;
    let payload: serde_json::Value = serde_json::from_str(&payload_str).unwrap();
    assert_eq!(payload["provider"].as_str(), Some("google"));
}
