//! Concern-owned tests for this module.

use std::sync::Arc;

use super::*;
use crate::engine::{EffectClass, FunctionDefinition, WorkerId};

struct InboxAttachHandler;

#[async_trait::async_trait]
impl crate::engine::InProcessFunctionHandler for InboxAttachHandler {
    async fn invoke(&self, _invocation: crate::engine::Invocation) -> crate::engine::Result<Value> {
        Ok(serde_json::json!({
            "handled":true,
            "items": [{"workerId":"background-worker","resultPreview":"{\"summary\":\"ready\"}"}],
            "narrative":"Background worker is ready."
        }))
    }
}

struct ContinuityContextHandler {
    handled: bool,
}

#[async_trait::async_trait]
impl crate::engine::InProcessFunctionHandler for ContinuityContextHandler {
    async fn invoke(&self, invocation: crate::engine::Invocation) -> crate::engine::Result<Value> {
        assert_eq!(invocation.payload["query"], "notification acceptance");
        assert_eq!(invocation.payload["project"], "/workspace/example");
        if self.handled {
            Ok(serde_json::json!({
                "handled":true,
                "workerId":"continuity-curator",
                "workerVersion":"version-a",
                "narrative":"- [project] Physical-device acceptance is required."
            }))
        } else {
            Ok(serde_json::json!({"handled":false}))
        }
    }
}

fn register_continuity_context(host: &EngineHostHandle, handled: bool) {
    let definition = FunctionDefinition::new(
        FunctionId::new(crate::domains::worker_kernel::CONTINUITY_CONTEXT_FUNCTION)
            .expect("function id"),
        WorkerId::new("worker_kernel").expect("worker id"),
        "Recall continuity",
        crate::engine::FunctionVisibility::Internal,
        EffectClass::ExternalSideEffect,
    )
    .with_idempotency(crate::engine::IdempotencyContract::session())
    .with_request_schema(serde_json::json!({"type":"object"}))
    .with_response_schema(serde_json::json!({"type":"object"}));
    host.register_function_for_setup(definition, Arc::new(ContinuityContextHandler { handled }))
        .expect("continuity function");
}

fn register_worker_primitive(
    host: &EngineHostHandle,
    function_name: &str,
    tool_name: &str,
    description: &str,
    dynamic: bool,
    worker_id: &str,
    routing: Value,
) {
    register_worker_primitive_with_visibility(
        host,
        function_name,
        tool_name,
        description,
        dynamic,
        worker_id,
        routing,
        crate::engine::FunctionVisibility::Public,
    );
}

#[allow(clippy::too_many_arguments)]
fn register_worker_primitive_with_visibility(
    host: &EngineHostHandle,
    function_name: &str,
    tool_name: &str,
    description: &str,
    dynamic: bool,
    worker_id: &str,
    routing: Value,
    visibility: crate::engine::FunctionVisibility,
) {
    let function_id =
        FunctionId::new(format!("worker_kernel::{function_name}")).expect("worker function id");
    let mut definition = FunctionDefinition::new(
        function_id,
        WorkerId::new("worker_kernel").expect("worker id"),
        description,
        visibility,
        EffectClass::PureRead,
    )
    .with_request_schema(serde_json::json!({
        "type": "object",
        "properties": {"query": {"type": "string"}},
        "required": ["query"],
        "additionalProperties": false
    }));
    definition.model_tool = Some(crate::engine::ModelToolContract {
        name: tool_name.to_owned(),
        audience: crate::engine::ModelToolAudience::Ordinary,
        order: None,
        group: None,
        worker: dynamic.then(|| crate::engine::DirectWorkerToolContract {
            worker_id: worker_id.to_owned(),
            worker_name: tool_name.to_owned(),
            worker_description: description.to_owned(),
            worker_version: "v1".to_owned(),
            runner_kind: "command".to_owned(),
            updated_at: String::new(),
            intents: routing
                .get("intents")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(ToOwned::to_owned)
                .collect(),
            examples: routing
                .get("examples")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(ToOwned::to_owned)
                .collect(),
            provenance: vec!["test fixture".to_owned()],
        }),
    });
    host.register_function_for_setup(definition, Arc::new(InboxAttachHandler))
        .expect("worker function");
}

#[tokio::test]
async fn non_model_functions_are_not_projected() {
    let host = EngineHostHandle::new_in_memory().expect("host");
    let old_builtin_like_function = FunctionDefinition::new(
        FunctionId::new("demo::read").expect("function id"),
        WorkerId::new("demo").expect("worker id"),
        "Should not be provider-facing",
        crate::engine::FunctionVisibility::Public,
        EffectClass::PureRead,
    );
    host.register_function_for_setup(old_builtin_like_function, Arc::new(InboxAttachHandler))
        .expect("nonprimitive function");

    let surface = resolve_provider_primitive_surface(&host, "session-a")
        .await
        .expect("surface");
    assert!(surface.tools.is_empty());
}

#[tokio::test]
async fn engine_owned_inbox_attachment_crosses_internal_visibility_for_trusted_runtime() {
    let host = EngineHostHandle::new_in_memory().expect("host");
    register_worker_primitive(
        &host,
        "inbox",
        "worker_inbox",
        "Read durable worker results",
        false,
        "kernel",
        serde_json::json!({}),
    );
    let attach = FunctionDefinition::new(
        FunctionId::new("worker_kernel::inbox_attach").expect("function id"),
        WorkerId::new("worker_kernel").expect("worker id"),
        "Attach unseen inbox results",
        crate::engine::FunctionVisibility::Internal,
        EffectClass::IdempotentWrite,
    )
    .with_idempotency(crate::engine::IdempotencyContract::profile())
    .with_request_schema(serde_json::json!({"type":"object"}))
    .with_response_schema(serde_json::json!({"type":"object"}));
    host.register_function_for_setup(attach, Arc::new(InboxAttachHandler))
        .expect("internal inbox attachment");

    let surface = resolve_provider_primitive_surface(&host, "session-a")
        .await
        .expect("surface");
    let primer = take_worker_inbox_context(
        &host,
        &surface,
        "session-a",
        1,
        Some("background"),
        None,
        None,
        None,
    )
    .await;

    assert_eq!(
        primer.narrative.as_deref(),
        Some("Background worker is ready.")
    );
    assert_eq!(primer.outcome, "injected");
}

#[tokio::test]
async fn continuity_projection_crosses_internal_visibility_and_is_context_only() {
    let host = EngineHostHandle::new_in_memory().expect("host");
    register_continuity_context(&host, true);
    let narrative = take_continuity_context(
        &host,
        "session-a",
        1,
        Some("notification acceptance"),
        Some("/workspace/example"),
        None,
        None,
        None,
    )
    .await;
    let narrative = narrative.narrative.expect("continuity narrative");
    assert!(narrative.starts_with("Saved continuity (redacted user-authored context"));
    assert!(narrative.contains("Physical-device acceptance"));
}

#[tokio::test]
async fn empty_or_unhandled_continuity_has_no_deterministic_fallback_text() {
    let host = EngineHostHandle::new_in_memory().expect("host");
    register_continuity_context(&host, false);
    assert!(
        take_continuity_context(
            &host,
            "session-a",
            1,
            Some("notification acceptance"),
            Some("/workspace/example"),
            None,
            None,
            None,
        )
        .await
        .narrative
        .is_none()
    );
    assert!(
        take_continuity_context(
            &host,
            "session-a",
            2,
            None,
            Some("/workspace/example"),
            None,
            None,
            None,
        )
        .await
        .narrative
        .is_none()
    );
}

#[tokio::test]
async fn worker_agent_sessions_skip_all_automatic_context_hooks() {
    let host = EngineHostHandle::new_in_memory().expect("host");
    let surface = resolve_provider_primitive_surface(&host, "worker-session")
        .await
        .expect("empty surface");

    assert!(
        take_continuity_context(
            &host,
            "worker-session",
            1,
            Some("bounded worker input"),
            Some("/workspace/example"),
            Some("worker-a"),
            None,
            None,
        )
        .await
        .narrative
        .is_none()
    );
    assert!(
        take_worker_inbox_context(
            &host,
            &surface,
            "worker-session",
            1,
            Some("bounded worker input"),
            Some("worker-a"),
            None,
            None,
        )
        .await
        .narrative
        .is_none()
    );
}

#[tokio::test]
async fn direct_surface_hides_wrapper_and_selects_relevant_typed_workers() {
    let host = EngineHostHandle::new_in_memory().expect("host");
    register_worker_primitive(
        &host,
        "worker_upsert",
        "worker_upsert",
        "Create or update a persistent worker",
        false,
        "kernel",
        serde_json::json!({}),
    );
    register_worker_primitive(
        &host,
        "dynamic_recent_research",
        "recent_research",
        "Research recent sources and synthesize findings",
        true,
        "recent-research",
        serde_json::json!({"keywords": ["recent", "research", "sources"]}),
    );
    register_worker_primitive(
        &host,
        "dynamic_formatter",
        "format_notes",
        "Format prose notes into a clean document",
        true,
        "formatter",
        serde_json::json!({"keywords": ["format", "document"]}),
    );

    let surface = resolve_provider_primitive_surface_for_query(
        &host,
        "worker-surface-session",
        Some("perform recent research with sources"),
        None,
        None,
    )
    .await
    .expect("direct surface");

    assert!(surface.targets_by_name.contains_key("worker_upsert"));
    assert!(surface.targets_by_name.contains_key("recent_research"));
    assert!(!surface.targets_by_name.contains_key("format_notes"));
    assert_eq!(surface.snapshot.fixed_tool_count, 1);
    assert_eq!(surface.snapshot.projected_worker_count, 1);
    assert_eq!(surface.snapshot.available_worker_count, 2);
    assert!(
        surface
            .snapshot
            .tools
            .iter()
            .any(|tool| tool.model_name == "worker_upsert")
    );
    assert_eq!(
        surface
            .snapshot
            .tools
            .iter()
            .find(|tool| tool.model_name == "recent_research")
            .expect("relevant worker")
            .selection_reason,
        "relevance"
    );
    assert_eq!(surface.snapshot.surface_hash.len(), 64);
    assert_eq!(
        surface.presentation_hints("worker_upsert"),
        Some(serde_json::json!({
            "surfaceKind": "core",
            "primitiveGroup": null,
        }))
    );
    assert_eq!(
        surface.presentation_hints("recent_research"),
        Some(serde_json::json!({
            "surfaceKind": "worker",
            "workerId": "recent-research",
            "workerName": "recent_research",
            "workerVersion": "v1",
            "runnerKind": "command",
        }))
    );
    let schema = surface
        .tools
        .iter()
        .find(|tool| tool.name == "recent_research")
        .expect("worker schema");
    assert_eq!(schema.parameters.schema_type, "object");
    assert_eq!(schema.parameters.required, Some(vec!["query".to_owned()]));
}

#[tokio::test]
async fn agent_runner_allowlist_filters_fixed_and_dynamic_tools_exactly() {
    let host = EngineHostHandle::new_in_memory().expect("host");
    register_worker_primitive(
        &host,
        "worker_upsert",
        "worker_upsert",
        "Create or update a persistent worker",
        false,
        "kernel",
        serde_json::json!({}),
    );
    register_worker_primitive(
        &host,
        "worker_list",
        "worker_list",
        "List persistent workers",
        false,
        "kernel",
        serde_json::json!({}),
    );
    register_worker_primitive(
        &host,
        "dynamic_recent_research",
        "recent_research",
        "Research recent sources",
        true,
        "recent-research",
        serde_json::json!({"keywords":["research"]}),
    );
    register_worker_primitive(
        &host,
        "dynamic_formatter",
        "format_notes",
        "Format a document",
        true,
        "formatter",
        serde_json::json!({"keywords":["format"]}),
    );
    let allowed = vec!["worker_upsert".to_owned(), "format_notes".to_owned()];
    let surface = resolve_provider_primitive_surface_for_query(
        &host,
        "closed-agent-session",
        Some("research recent sources"),
        Some("closed-agent"),
        Some(&allowed),
    )
    .await
    .expect("allowlisted surface");

    assert_eq!(
        surface.targets_by_name.keys().cloned().collect::<Vec<_>>(),
        vec!["format_notes".to_owned(), "worker_upsert".to_owned()]
    );
    assert!(!surface.targets_by_name.contains_key("worker_list"));
    assert!(!surface.targets_by_name.contains_key("recent_research"));
    assert_eq!(surface.snapshot.fixed_tool_count, 1);
    assert_eq!(surface.snapshot.projected_worker_count, 1);
    assert_eq!(surface.snapshot.available_worker_count, 1);
    assert_eq!(
        surface
            .snapshot
            .tools
            .iter()
            .find(|tool| tool.model_name == "format_notes")
            .expect("allowlisted dynamic tool")
            .selection_reason,
        "agent_allowlist"
    );

    let empty = Vec::new();
    let empty_surface = resolve_provider_primitive_surface_for_query(
        &host,
        "closed-agent-empty",
        Some("research recent sources"),
        Some("closed-agent"),
        Some(&empty),
    )
    .await
    .expect("explicit empty allowlist");
    assert!(empty_surface.tools.is_empty());
    assert!(empty_surface.targets_by_name.is_empty());
}

#[tokio::test]
async fn exact_worker_allowlist_can_select_one_internal_worker_without_publishing_it() {
    let host = EngineHostHandle::new_in_memory().expect("host");
    for (function_name, tool_name, worker_id) in [
        (
            "dynamic_internal_review",
            "worker_internal_review",
            "internal-review",
        ),
        (
            "dynamic_internal_citation",
            "worker_internal_citation",
            "internal-citation",
        ),
    ] {
        register_worker_primitive_with_visibility(
            &host,
            function_name,
            tool_name,
            "Internal specialist",
            true,
            worker_id,
            serde_json::json!({"keywords":["internal"]}),
            crate::engine::FunctionVisibility::Internal,
        );
    }

    let ordinary = resolve_provider_primitive_surface_for_query(
        &host,
        "ordinary-session",
        Some("internal review"),
        None,
        None,
    )
    .await
    .expect("ordinary agent surface");
    assert!(ordinary.tools.is_empty());

    let allowed = vec!["worker_internal_review".to_owned()];
    let worker_surface = resolve_provider_primitive_surface_for_query(
        &host,
        "worker-session",
        Some("internal review and citation"),
        Some("research-coordinator"),
        Some(&allowed),
    )
    .await
    .expect("trusted worker surface");
    assert_eq!(
        worker_surface
            .targets_by_name
            .keys()
            .cloned()
            .collect::<Vec<_>>(),
        vec!["worker_internal_review".to_owned()]
    );
    assert!(
        !worker_surface
            .targets_by_name
            .contains_key("worker_internal_citation")
    );
    assert_eq!(
        worker_surface
            .targets_by_name
            .get("worker_internal_review")
            .expect("internal target")
            .function
            .visibility,
        crate::engine::FunctionVisibility::Internal
    );
}

#[tokio::test]
async fn worker_discovery_promotion_changes_the_live_session_surface() {
    let host = EngineHostHandle::new_in_memory().expect("host");
    register_worker_primitive(
        &host,
        "worker_upsert",
        "worker_upsert",
        "Create or update a persistent worker",
        false,
        "kernel",
        serde_json::json!({}),
    );
    register_worker_primitive(
        &host,
        "dynamic_formatter_promoted",
        "format_notes_promoted",
        "Format prose notes into a clean document",
        true,
        "formatter-promoted",
        serde_json::json!({"keywords": ["format", "document"]}),
    );

    let before = resolve_provider_primitive_surface_for_query(
        &host,
        "promotion-session",
        Some("astronomy ephemeris"),
        None,
        None,
    )
    .await
    .expect("surface before promotion");
    assert!(!before.targets_by_name.contains_key("format_notes_promoted"));

    promote_worker_for_session(&host, "promotion-session", "formatter-promoted").await;
    let after = resolve_provider_primitive_surface_for_query(
        &host,
        "promotion-session",
        Some("astronomy ephemeris"),
        None,
        None,
    )
    .await
    .expect("surface after promotion");
    assert!(after.targets_by_name.contains_key("format_notes_promoted"));
    assert_eq!(
        after
            .snapshot
            .tools
            .iter()
            .find(|tool| tool.model_name == "format_notes_promoted")
            .expect("promoted tool")
            .selection_reason,
        "session_promotion"
    );
}

#[tokio::test]
async fn worker_discovery_promotion_survives_engine_restart() {
    let directory = tempfile::tempdir().expect("temporary engine state");
    let path = directory.path().join("engine.sqlite3");
    {
        let host = EngineHostHandle::open_sqlite(&path).expect("durable host");
        register_worker_primitive(
            &host,
            "dynamic_durable_formatter",
            "durable_formatter",
            "Format prose notes into a clean document",
            true,
            "durable-formatter",
            serde_json::json!({"keywords": ["format", "document"]}),
        );
        promote_worker_for_session(&host, "durable-session", "durable-formatter").await;
    }

    let reopened = EngineHostHandle::open_sqlite(&path).expect("reopened durable host");
    register_worker_primitive(
        &reopened,
        "dynamic_durable_formatter",
        "durable_formatter",
        "Format prose notes into a clean document",
        true,
        "durable-formatter",
        serde_json::json!({"keywords": ["format", "document"]}),
    );

    let surface = resolve_provider_primitive_surface_for_query(
        &reopened,
        "durable-session",
        Some("astronomy ephemeris"),
        None,
        None,
    )
    .await
    .expect("surface after restart");
    assert_eq!(
        surface
            .snapshot
            .tools
            .iter()
            .find(|tool| tool.model_name == "durable_formatter")
            .expect("durably promoted tool")
            .selection_reason,
        "session_promotion"
    );
}

#[tokio::test]
async fn repeated_promotions_keep_the_complete_dynamic_surface_bounded() {
    let host = EngineHostHandle::new_in_memory().expect("host");
    for index in 0..15 {
        let worker_id = format!("promoted-{index:02}");
        register_worker_primitive(
            &host,
            &format!("dynamic_promoted_{index:02}"),
            &format!("promoted_tool_{index:02}"),
            "Explicitly promoted worker",
            true,
            &worker_id,
            serde_json::json!({"keywords": ["unrelated"]}),
        );
        promote_worker_for_session(&host, "bounded-session", &worker_id).await;
    }

    let surface = resolve_provider_primitive_surface_for_query(
        &host,
        "bounded-session",
        Some("astronomy ephemeris"),
        None,
        None,
    )
    .await
    .expect("bounded surface");

    assert_eq!(surface.snapshot.projected_worker_count, 12);
    assert_eq!(
        surface
            .snapshot
            .available_workers
            .iter()
            .filter(|worker| worker.projected)
            .count(),
        12
    );
    assert!(surface.targets_by_name.contains_key("promoted_tool_14"));
    assert!(!surface.targets_by_name.contains_key("promoted_tool_00"));
}

#[tokio::test]
async fn promotion_for_an_old_worker_version_does_not_revive_a_recreated_worker() {
    let host = EngineHostHandle::new_in_memory().expect("host");
    register_worker_primitive(
        &host,
        "dynamic_recreated",
        "recreated_tool",
        "Recreated worker",
        true,
        "recreated",
        serde_json::json!({"keywords": ["format"]}),
    );
    crate::domains::worker_kernel::promote_worker_for_session(
        &host,
        "recreated-session",
        "recreated",
        "retired-version",
    )
    .await
    .expect("stale promotion record");

    let surface = resolve_provider_primitive_surface_for_query(
        &host,
        "recreated-session",
        Some("astronomy ephemeris"),
        None,
        None,
    )
    .await
    .expect("surface");
    assert!(!surface.targets_by_name.contains_key("recreated_tool"));
    let worker = surface
        .snapshot
        .available_workers
        .iter()
        .find(|worker| worker.worker_id == "recreated")
        .expect("available worker");
    assert!(!worker.promoted);
    assert!(!worker.projected);
}

#[test]
fn surface_primer_is_stable_and_omits_volatile_catalog_evidence() {
    let primer = surface_context_primer(&crate::domains::worker_kernel::EngineSurfaceSnapshot {
        catalog_revision: 42,
        surface_hash: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef".to_owned(),
        fixed_tool_count: 29,
        ordinary_fixed_tool_count: 11,
        specialist_fixed_tool_count: 13,
        conditional_fixed_tool_count: 1,
        projected_worker_count: 1,
        available_worker_count: 7,
        ranking_mechanism: "semantic_hook".to_owned(),
        router_worker_id: Some("worker-relevance-router".to_owned()),
        router_worker_version: Some("abcdef1234567890".to_owned()),
        router_invocation_id: Some("invocation-1".to_owned()),
        tools: vec![crate::domains::worker_kernel::SurfaceToolSnapshot {
            model_name: "worker_discover".to_owned(),
            function_id: "worker_kernel::dynamic_recent".to_owned(),
            function_revision: 2,
            owner_worker: "worker_kernel".to_owned(),
            description: "Recent research".to_owned(),
            input_schema: serde_json::json!({"type":"object"}),
            input_schema_sha256: "input-digest".to_owned(),
            output_schema: Some(serde_json::json!({"type":"object"})),
            output_schema_sha256: Some("output-digest".to_owned()),
            effect_class: "ExternalSideEffect".to_owned(),
            risk: "high".to_owned(),
            exposed: true,
            worker_id: Some("recent".to_owned()),
            worker_version: Some("abcdef1234567890".to_owned()),
            primitive_group: None,
            audience: "ordinary".to_owned(),
            access_path: "dynamic_worker".to_owned(),
            selection_reason: "relevance".to_owned(),
            omission_reason: None,
        }],
        fixed_tools: Vec::new(),
        available_workers: vec![crate::domains::worker_kernel::AvailableWorkerToolSnapshot {
            worker_id: "recent".to_owned(),
            model_name: "worker_recent_research".to_owned(),
            function_id: "worker_kernel::dynamic_recent".to_owned(),
            function_revision: 2,
            worker_version: Some("abcdef1234567890".to_owned()),
            promoted: false,
            projected: true,
            selection_reason: Some("relevance".to_owned()),
            omission_reason: None,
            ranking_mechanism: "semantic_hook".to_owned(),
            relevance_score: 8,
            router_explanation: Some("Matches recent research".to_owned()),
            completed_runs: 4,
        }],
    });
    assert_eq!(
        primer,
        "Use only the typed tools supplied in this request. Use worker_discover when a dynamic \
         capability is omitted. Use Engine Steward for worker diagnosis and Worker Forge for \
         worker changes; permanent deletion, secret rotation, and engine-wide stop remain \
         authenticated dashboard actions."
    );
    for volatile in ["r42", "1/7 workers", "abcdef12", "runs=4"] {
        assert!(!primer.contains(volatile));
    }
}
