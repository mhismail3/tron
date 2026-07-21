use super::*;
use crate::domains::agent::context::types::{CompactionConfig, ContextManagerConfig};

fn test_config() -> ContextManagerConfig {
    ContextManagerConfig {
        system_prompt: Some("product intent".into()),
        working_directory: Some("/tmp".into()),
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
    manager.add_message(crate::shared::protocol::messages::Message::user("hello"));
    assert!(manager.get_messages_tokens() > 0);
    assert_eq!(manager.messages_slice().len(), 1);
}

#[test]
fn build_base_context_contains_product_intent_and_environment_only() {
    let manager = manager();
    let context = manager.build_base_context();
    assert_eq!(context.system_prompt.as_deref(), Some("product intent"));
    assert_eq!(context.working_directory.as_deref(), Some("/tmp"));
    assert!(context.messages.is_empty());
    assert!(context.capabilities.is_none());
    assert!(context.server_origin.is_none());
}

#[test]
fn live_capability_surface_participates_in_token_accounting() {
    let mut manager = manager();
    manager.set_api_context_tokens(1234);
    manager.set_capabilities(vec![
        crate::shared::protocol::model_capabilities::ModelCapability {
            name: "worker_recent_research".to_owned(),
            description: "Research recent changes".to_owned(),
            parameters: crate::shared::protocol::model_capabilities::CapabilityParameterSchema {
                schema_type: "object".to_owned(),
                properties: None,
                required: None,
                description: None,
                extra: Default::default(),
            },
        },
    ]);

    assert!(manager.get_api_context_tokens().is_none());
    assert!(manager.estimate_capabilities_tokens() > 0);
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
