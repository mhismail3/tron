//! Provider surface selection, promotion, and audience tests.

use super::promotions::MAX_STORED_SESSION_PROMOTIONS;
use super::*;
use crate::engine::{DirectWorkerToolContract, FunctionDefinition};

fn conditional_definition() -> FunctionDefinition {
    let mut definition = FunctionDefinition::new(
        crate::engine::FunctionId::new("worker_kernel::session_set_title").unwrap(),
        crate::engine::WorkerId::new("worker_kernel").unwrap(),
        "Explicit conversation rename",
        crate::engine::FunctionVisibility::Public,
        crate::engine::EffectClass::IdempotentWrite,
    );
    definition.model_tool = Some(crate::engine::ModelToolContract {
        name: "conditional".to_owned(),
        audience: crate::engine::ModelToolAudience::Conditional {
            latest_user_intent_phrases: vec!["rename this conversation".to_owned()],
        },
        order: Some(1),
        group: Some("host".to_owned()),
        worker: None,
    });
    definition
}

#[test]
fn latest_user_intent_exposure_hides_normal_chat_and_admits_explicit_requests() {
    let definition = conditional_definition();
    assert!(!model_tool_exposure_allows(
        &definition,
        Some("What's happening in the news today?"),
        false,
    ));
    assert!(model_tool_exposure_allows(
        &definition,
        Some("Please rename this conversation to Daily Briefing"),
        false,
    ));
    assert!(model_tool_exposure_allows(&definition, None, true));
}

#[test]
fn surface_hash_is_stable_and_contract_sensitive() {
    let tool = SurfaceToolSnapshot {
        model_name: "worker_demo".to_owned(),
        function_id: "worker::demo".to_owned(),
        function_revision: 1,
        owner_worker: "demo".to_owned(),
        description: "Demo worker".to_owned(),
        input_schema: serde_json::json!({"type":"object"}),
        input_schema_sha256: schema_digest(&serde_json::json!({"type":"object"}))
            .expect("input digest"),
        output_schema: Some(serde_json::json!({"type":"object"})),
        output_schema_sha256: Some(
            schema_digest(&serde_json::json!({"type":"object"})).expect("output digest"),
        ),
        effect_class: "PureRead".to_owned(),
        risk: "low".to_owned(),
        exposed: true,
        worker_id: Some("demo".to_owned()),
        worker_version: Some("abc".to_owned()),
        primitive_group: None,
        audience: "ordinary".to_owned(),
        access_path: "dynamic_worker".to_owned(),
        selection_reason: "relevance".to_owned(),
        omission_reason: None,
    };
    let first = surface_hash(std::slice::from_ref(&tool)).expect("hash");
    let second = surface_hash(std::slice::from_ref(&tool)).expect("hash");
    assert_eq!(first, second);

    let mut changed = tool;
    changed.function_revision = 2;
    assert_ne!(first, surface_hash(&[changed]).expect("changed hash"));
}

#[test]
fn deterministic_routing_uses_canonical_worker_description() {
    let mut function = FunctionDefinition::new(
        crate::engine::FunctionId::new("worker_kernel::dynamic_research").unwrap(),
        crate::engine::WorkerId::new("worker_kernel").unwrap(),
        "Canonical research purpose\nPersistent worker: activeVersion=abc; provenance=test. Agent-runner work begins durably in the background.",
        crate::engine::FunctionVisibility::Public,
        crate::engine::EffectClass::ExternalSideEffect,
    );
    let worker = DirectWorkerToolContract {
        worker_id: "research".to_owned(),
        worker_name: "Research".to_owned(),
        worker_description: "Canonical research purpose".to_owned(),
        worker_version: "abc".to_owned(),
        runner_kind: "agent".to_owned(),
        updated_at: "2026-07-27T00:00:00Z".to_owned(),
        intents: vec!["research".to_owned()],
        examples: Vec::new(),
        provenance: vec!["test".to_owned()],
    };
    function.model_tool = Some(crate::engine::ModelToolContract {
        name: "worker_research".to_owned(),
        audience: crate::engine::ModelToolAudience::Ordinary,
        order: None,
        group: None,
        worker: Some(worker.clone()),
    });

    let document = retrieval_document(&function, &worker, None);
    assert_eq!(document.description, "Canonical research purpose");
    assert!(
        function.description.contains("activeVersion"),
        "provider-facing function description remains unchanged"
    );
}

#[tokio::test]
async fn session_promotion_storage_prunes_oldest_records() {
    let host = EngineHostHandle::new_in_memory().expect("host");
    for index in 0..55 {
        promote_worker_for_session(
            &host,
            "promotion-retention",
            &format!("worker-{index:02}"),
            "v1",
        )
        .await
        .expect("promotion");
    }

    let promotions = session_worker_promotions(&host, "promotion-retention")
        .await
        .expect("promotions");
    assert_eq!(promotions.len(), MAX_STORED_SESSION_PROMOTIONS);
    assert!(promotions.contains("worker-54"));
    assert!(!promotions.contains("worker-00"));
}
