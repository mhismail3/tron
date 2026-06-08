use super::*;
use crate::domains::agent::runner::context::types::{CompactionConfig, ContextManagerConfig};

fn test_config() -> ContextManagerConfig {
    ContextManagerConfig {
        model: "test-model".into(),
        system_prompt: Some("soul".into()),
        working_directory: Some("/tmp".into()),
        capabilities: vec![],
        compaction: CompactionConfig {
            threshold: 0.70,
            preserve_recent_turns: 2,
            context_limit: 10_000,
        },
    }
}

fn manager() -> ContextManager {
    ContextManager::new(test_config())
}

#[test]
fn working_directory_defaults_to_home_workspace_when_none() {
    let mut config = test_config();
    config.working_directory = None;
    let manager = ContextManager::new(config);
    assert!(manager.get_working_directory().ends_with("/Workspace"));
}

#[test]
fn message_store_updates_tokens_and_count() {
    let mut manager = manager();
    assert_eq!(manager.message_count(), 0);
    manager.add_message(crate::shared::protocol::messages::Message::user("hello"));
    assert_eq!(manager.message_count(), 1);
    assert!(manager.get_messages_tokens() > 0);
    manager.clear_messages();
    assert_eq!(manager.message_count(), 0);
}

#[test]
fn snapshot_breakdown_has_only_primitive_context_rows() {
    let mut manager = manager();
    manager.add_message(crate::shared::protocol::messages::Message::user("hello"));
    let snapshot = manager.get_snapshot();
    assert_eq!(
        snapshot.breakdown.system_prompt,
        manager.estimate_system_prompt_tokens()
    );
    assert_eq!(snapshot.breakdown.capabilities, 0);
    assert_eq!(
        snapshot.breakdown.environment,
        manager.estimate_environment_tokens()
    );
    assert_eq!(snapshot.breakdown.messages, manager.get_messages_tokens());
    assert_eq!(snapshot.breakdown.total(), snapshot.current_tokens);
}

#[test]
fn build_base_context_contains_soul_and_environment_only() {
    let manager = manager();
    let context = manager.build_base_context();
    assert_eq!(context.system_prompt.as_deref(), Some("soul"));
    assert_eq!(context.working_directory.as_deref(), Some("/tmp"));
    assert!(context.messages.is_empty());
    assert!(context.capabilities.is_none());
    assert!(context.agent_state_context.is_none());
    assert!(context.server_origin.is_none());
}

#[test]
fn api_context_tokens_override_estimates_until_messages_change() {
    let mut manager = manager();
    manager.set_api_context_tokens(1234);
    assert_eq!(manager.get_current_tokens(), 1234);
    manager.add_message(crate::shared::protocol::messages::Message::user("new"));
    assert_eq!(manager.get_current_tokens(), 1234);
    manager.set_messages(vec![]);
    assert_ne!(manager.get_current_tokens(), 1234);
}

#[test]
fn turn_shape_refresh_tracks_generation() {
    let mut manager = manager();
    assert!(!manager.volatile_tokens_fresh_for_current_turn());
    manager.begin_turn();
    assert!(!manager.volatile_tokens_fresh_for_current_turn());
    manager.set_volatile_tokens(0, 0, 0);
    assert!(manager.volatile_tokens_fresh_for_current_turn());
}

#[test]
fn capability_result_budget_truncates_large_content() {
    let manager = manager();
    let large = "x".repeat(1_000_000);
    let result = manager.process_capability_result("call-1", &large);
    assert!(result.truncated);
    assert_eq!(result.original_size, Some(large.len()));
}

#[test]
fn switch_model_updates_context_limit_and_clears_api_tokens() {
    let mut manager = manager();
    manager.set_api_context_tokens(42);
    manager.switch_model("other".into(), 123);
    assert_eq!(manager.get_model(), "other");
    assert_eq!(manager.get_context_limit(), 123);
    assert!(manager.get_api_context_tokens().is_none());
}
