use super::{
    ContextArtifactsService, RuleFileLevel, RulesIndex, collect_dynamic_rule_paths,
    load_session_context_artifacts_with_home,
};
use crate::events::{AppendOptions, EventType};
use crate::server::shared::test_support::make_test_context;

#[tokio::test]
async fn loads_rules_from_project_and_global() {
    let ctx = make_test_context();
    let mut settings = crate::settings::TronSettings::default();
    settings.context.rules.discover_standalone_files = true;

    let home_dir = tempfile::tempdir().unwrap();
    let rules_dir = home_dir.path().join(".tron").join("memory").join("rules");
    std::fs::create_dir_all(&rules_dir).unwrap();
    std::fs::write(rules_dir.join("AGENTS.md"), "global rules").unwrap();

    let working_dir = tempfile::tempdir().unwrap();
    let agent_dir = working_dir.path().join(".agent");
    std::fs::create_dir_all(&agent_dir).unwrap();
    std::fs::write(agent_dir.join("AGENTS.md"), "project rules").unwrap();

    let artifacts = load_session_context_artifacts_with_home(
        ctx.event_store.as_ref(),
        working_dir.path().to_str().unwrap(),
        &settings,
        Some(home_dir.path()),
    );

    assert_eq!(artifacts.rules.files.len(), 2);
    assert!(
        artifacts
            .rules
            .files
            .iter()
            .any(|f| f.level == RuleFileLevel::Global)
    );
    assert!(
        artifacts.rules.files.iter().any(|f| {
            f.level == RuleFileLevel::Global && f.relative_path == ".tron/memory/rules/AGENTS.md"
        }),
        "global rules should resolve from ~/.tron/memory/rules"
    );
    assert!(
        artifacts
            .rules
            .files
            .iter()
            .any(|f| f.level == RuleFileLevel::Project)
    );
    assert!(
        artifacts
            .rules
            .merged_content
            .as_deref()
            .unwrap_or("")
            .contains("global rules")
    );
    assert!(
        artifacts
            .rules
            .merged_content
            .as_deref()
            .unwrap_or("")
            .contains("project rules")
    );
}

#[tokio::test]
async fn dynamic_rules_reset_after_compaction_boundary() {
    let ctx = make_test_context();
    let session_id = ctx
        .session_manager
        .create_session("claude-sonnet-4-20250514", "/tmp", Some("test"), None)
        .unwrap();

    let _ = ctx.event_store.append(&AppendOptions {
        session_id: &session_id,
        event_type: EventType::RulesActivated,
        payload: serde_json::json!({
            "rules": [{"relativePath": "a/AGENTS.md", "scopeDir": "a"}]
        }),
        parent_id: None,
        sequence: None,
    });
    let _ = ctx.event_store.append(&AppendOptions {
        session_id: &session_id,
        event_type: EventType::CompactBoundary,
        payload: serde_json::json!({
            "originalTokens": 0,
            "compactedTokens": 0,
            "reason": "manual",
        }),
        parent_id: None,
        sequence: None,
    });
    let _ = ctx.event_store.append(&AppendOptions {
        session_id: &session_id,
        event_type: EventType::RulesActivated,
        payload: serde_json::json!({
            "rules": [{"relativePath": "b/AGENTS.md", "scopeDir": "b"}]
        }),
        parent_id: None,
        sequence: None,
    });

    let paths = collect_dynamic_rule_paths(ctx.event_store.as_ref(), &session_id);
    assert_eq!(paths, vec!["b/AGENTS.md"]);
}

#[test]
fn service_invalidates_cached_root_rules_when_project_rules_appear() {
    let ctx = make_test_context();
    let service = ContextArtifactsService::new();
    let settings = crate::settings::TronSettings::default();
    let working_dir = tempfile::tempdir().unwrap();
    let working_dir_str = working_dir.path().to_str().unwrap();

    let first = service.load(ctx.event_store.as_ref(), working_dir_str, &settings);
    assert!(first.session.rules.merged_content.is_none());

    let rules_dir = working_dir.path().join(".agent");
    std::fs::create_dir_all(&rules_dir).unwrap();
    std::fs::write(rules_dir.join("AGENTS.md"), "project rules").unwrap();

    let second = service.load(ctx.event_store.as_ref(), working_dir_str, &settings);
    assert!(
        second
            .session
            .rules
            .merged_content
            .as_deref()
            .unwrap_or("")
            .contains("project rules")
    );
}

#[test]
fn service_invalidates_cached_rules_index_when_scoped_rules_appear() {
    let ctx = make_test_context();
    let service = ContextArtifactsService::new();
    let settings = crate::settings::TronSettings::default();
    let working_dir = tempfile::tempdir().unwrap();
    let working_dir_str = working_dir.path().to_str().unwrap();

    let first = service.load(ctx.event_store.as_ref(), working_dir_str, &settings);
    assert!(first.rules_index.is_none());

    let scoped_rules_dir = working_dir.path().join("src").join(".claude");
    std::fs::create_dir_all(&scoped_rules_dir).unwrap();
    std::fs::write(scoped_rules_dir.join("AGENTS.md"), "scoped rules").unwrap();

    let second = service.load(ctx.event_store.as_ref(), working_dir_str, &settings);
    assert_eq!(
        second.rules_index.as_ref().map(RulesIndex::total_count),
        Some(1)
    );
}
