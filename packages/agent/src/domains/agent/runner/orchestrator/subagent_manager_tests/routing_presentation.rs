use super::*;
use crate::domains::capability_support::implementations::traits::SubagentTaskProfile;

#[tokio::test]
async fn spawn_persists_task_profile_and_model_routing_to_events_and_resource() {
    let (manager, session_mgr, store) = make_subagent_manager(Arc::new(MockProvider));
    let engine_host = crate::engine::EngineHostHandle::new_in_memory().unwrap();
    manager.set_engine_host(engine_host.clone());

    let parent_sid = session_mgr
        .create_session("mock-model", "/tmp", None, None)
        .unwrap();

    let mut config = make_config("review this implementation");
    config.parent_session_id = Some(parent_sid.clone());
    config.model_preset = Some(crate::domains::model::presets::ModelPreset::Balanced);
    config.task_profile = Some(SubagentTaskProfile::from_id("review").unwrap());
    let handle = manager.spawn(config).await.unwrap();

    assert_eq!(
        handle
            .task_profile
            .as_ref()
            .map(|profile| profile.label.as_str()),
        Some("Review")
    );
    let handle_route = handle.model_routing.as_ref().unwrap();
    assert_eq!(handle_route.preset_label.as_deref(), Some("Balanced"));
    assert_eq!(handle_route.selection_status, "selected");
    assert!(handle_route.selected_model.is_some());

    let spawned = store
        .get_events_by_type(&parent_sid, &["subagent.spawned"], None)
        .unwrap();
    let spawned_payload: serde_json::Value = serde_json::from_str(&spawned[0].payload).unwrap();
    assert_eq!(spawned_payload["taskProfile"]["label"], "Review");
    assert_eq!(spawned_payload["modelRouting"]["presetLabel"], "Balanced");

    let completed = store
        .get_events_by_type(&parent_sid, &["subagent.completed"], None)
        .unwrap();
    let completed_payload: serde_json::Value = serde_json::from_str(&completed[0].payload).unwrap();
    assert_eq!(completed_payload["taskProfile"]["label"], "Review");
    assert_eq!(
        completed_payload["modelRouting"]["selectedModel"],
        handle_route.selected_model.as_deref().unwrap()
    );

    let resource_id =
        crate::domains::agent::lineage::subagent_result_resource_id(&handle.session_id);
    let inspected = engine_host
        .invoke(crate::engine::Invocation::new_sync(
            crate::engine::FunctionId::new("resource::inspect").unwrap(),
            serde_json::json!({"resourceId": resource_id}),
            crate::engine::CausalContext::new(
                crate::engine::ActorId::new("system:test").unwrap(),
                crate::engine::ActorKind::System,
                crate::engine::AuthorityGrantId::new("engine-system").unwrap(),
                crate::engine::TraceId::generate(),
            )
            .with_session_id(parent_sid)
            .with_scope("resource.read"),
        ))
        .await;
    assert_eq!(inspected.error, None);
    let metadata =
        &inspected.value.as_ref().unwrap()["inspection"]["versions"][0]["payload"]["metadata"];
    assert_eq!(metadata["taskProfile"]["label"], "Review");
    assert_eq!(metadata["modelRouting"]["presetLabel"], "Balanced");
}
