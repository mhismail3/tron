use super::*;

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
