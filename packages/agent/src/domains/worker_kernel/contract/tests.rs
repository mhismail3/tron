use super::*;
use crate::domains::worker_kernel::types::{
    BUNDLE_SCHEMA, SourceProvenance, WorkerAgentResultMode, WorkerAgentRole, WorkerAgentRoleLimits,
    WorkerBundle, WorkerDependency, WorkerRunner, WorkerTrigger,
};
use crate::engine::{DedupeScope, DelegationPolicy, FunctionRevision};
use serde_json::Value;

#[test]
fn background_receipt_points_to_the_non_blocking_resume_primitive() {
    let message = background_worker_receipt_message("worker-run-one");

    assert!(message.contains("agent_wait"));
    assert!(message.contains(r#""kind":"worker_invocation""#));
    assert!(message.contains(r#""id":"worker-run-one""#));
    assert!(message.contains(r#""mode":"all""#));
    assert!(message.contains("Do not poll"));
    assert!(!message.contains("worker_await"));
}

#[test]
fn engine_surface_snapshot_is_client_introspection_not_model_vocabulary() {
    let definitions = function_definitions().expect("worker-kernel contracts");
    let surface = definitions
        .iter()
        .find(|definition| definition.id.as_str() == ENGINE_SURFACE_SNAPSHOT_FUNCTION)
        .expect("surface snapshot contract");
    assert_eq!(surface.id.as_str(), ENGINE_SURFACE_SNAPSHOT_FUNCTION);
    assert_eq!(surface.effect_class, EffectClass::PureRead);
    assert!(surface.model_tool.is_none());
    let schema = surface.response_schema.as_ref().expect("response schema");
    assert_eq!(schema["additionalProperties"], false);
    assert_eq!(
        schema["properties"]["surface"]["additionalProperties"],
        false
    );
    assert!(
        schema["properties"]["surface"]["properties"]
            .as_object()
            .is_some_and(|properties| !properties.contains_key("tools"))
    );
}

#[test]
fn worker_result_projection_is_internal_kernel_reconstruction_not_model_vocabulary() {
    let definitions = function_definitions().expect("worker-kernel contracts");
    let projection = definitions
        .iter()
        .find(|definition| definition.id.as_str() == WORKER_RESULT_PROJECTION_FUNCTION)
        .expect("result projection contract");
    assert_eq!(projection.visibility, FunctionVisibility::Internal);
    assert_eq!(projection.effect_class, EffectClass::PureRead);
    assert!(projection.model_tool.is_none());
    let request = projection.request_schema.as_ref().unwrap();
    assert_eq!(request["additionalProperties"], false);
    assert_eq!(
        request["properties"]["modelToolInvocationIds"]["maxItems"],
        256
    );
}

#[test]
fn native_agent_management_protocol_is_complete_and_never_model_projected() {
    let definitions = function_definitions().expect("worker-kernel contracts");
    let expected = [
        "agent::relations",
        "agent::inspect",
        "agent::assignments",
        "agent::messages",
        "agent::message_detail",
        "agent::result_read",
        "agent::operator_message",
        "agent::manage",
        "agent::retry",
        "agent::promote",
    ];
    for function_id in expected {
        let definition = definitions
            .iter()
            .find(|definition| definition.id.as_str() == function_id)
            .unwrap_or_else(|| panic!("missing {function_id}"));
        assert_eq!(definition.visibility, FunctionVisibility::NativeClient);
        assert!(definition.model_tool.is_none());
        assert_eq!(
            definition
                .request_schema
                .as_ref()
                .expect("native request schema")["additionalProperties"],
            false
        );
        let response = definition
            .response_schema
            .as_ref()
            .expect("native response schema");
        assert_eq!(response["additionalProperties"], false);
        assert!(response["required"].is_array());
    }
}

#[test]
fn reusable_agent_coordination_is_exactly_five_ordinary_contracts() {
    let definitions = function_definitions().expect("worker-kernel contracts");
    let expected = [
        ("worker_kernel::agent_discover", "agent_discover", 1_u32),
        ("worker_kernel::agent_spawn", "agent_spawn", 1),
        ("worker_kernel::agent_send", "agent_send", 2),
        ("worker_kernel::agent_wait", "agent_wait", 1),
        ("worker_kernel::agent_manage", "agent_manage", 1),
    ];
    let projected = definitions
        .iter()
        .filter_map(|definition| {
            definition.model_tool.as_ref().and_then(|tool| {
                (tool.group.as_deref() == Some("agent_coordination")).then_some((definition, tool))
            })
        })
        .collect::<Vec<_>>();
    assert_eq!(projected.len(), expected.len());
    for (function_id, model_name, revision) in expected {
        let definition = definitions
            .iter()
            .find(|definition| definition.id.as_str() == function_id)
            .unwrap_or_else(|| panic!("missing {function_id}"));
        let tool = definition.model_tool.as_ref().expect("model projection");
        assert_eq!(tool.name, model_name);
        assert!(matches!(tool.audience, ModelToolAudience::Ordinary));
        assert_eq!(definition.revision, FunctionRevision(u64::from(revision)));
        assert_eq!(definition.delegation_policy, DelegationPolicy::Inherit);
        let request = definition.request_schema.as_ref().unwrap();
        let closed = request["additionalProperties"] == false
            || request["oneOf"].as_array().is_some_and(|branches| {
                !branches.is_empty()
                    && branches
                        .iter()
                        .all(|branch| branch["additionalProperties"] == false)
            });
        assert!(closed, "{function_id} must keep a closed request envelope");
    }
}

#[test]
fn worker_discovery_declares_its_durable_session_promotion() {
    let definition = function_definitions()
        .expect("worker-kernel contracts")
        .into_iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::discover")
        .expect("worker discover definition");

    assert_eq!(definition.effect_class, EffectClass::IdempotentWrite);
}

#[test]
fn agent_discovery_declares_lazy_root_identity_materialization() {
    let definition = function_definitions()
        .expect("worker-kernel contracts")
        .into_iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::agent_discover")
        .expect("agent discover definition");

    assert_eq!(definition.effect_class, EffectClass::IdempotentWrite);
    let statuses =
        definition.request_schema.as_ref().unwrap()["properties"]["status"]["items"]["enum"]
            .as_array()
            .unwrap();
    assert!(statuses.iter().all(|status| status != "closed"));
}

#[test]
fn non_model_operator_endpoints_are_native_client_visible() {
    let definitions = function_definitions().expect("worker-kernel contracts");
    for function_id in [
        "worker_kernel::notification_device_upsert",
        "worker_kernel::notification_device_disable",
        "worker_kernel::notification_deliveries",
        "worker_kernel::notification_delivery_acknowledge",
        "worker_kernel::notification_delivery_status",
        "worker_kernel::artifact_deliveries",
        "worker_kernel::artifact_content",
        "worker_kernel::artifact_delete",
        "worker_kernel::role_reviews",
        "worker_kernel::role_review_start",
        "worker_kernel::role_review_inspect",
        "worker_kernel::role_review_apply",
        "worker_kernel::role_review_reject",
        "worker_kernel::scheduled_work",
        "worker_kernel::inbox_dismiss",
        "worker_kernel::agent_wait_for_workers",
        "worker_kernel::agent_mailbox_list",
        "worker_kernel::agent_mailbox_claim",
        "worker_kernel::result_handoff",
        "worker_kernel::detach",
        "worker_kernel::cancel",
        "worker_kernel::purge",
        "worker_kernel::webhook_rotate",
        "worker_kernel::stop_all",
    ] {
        let definition = definitions
            .iter()
            .find(|definition| definition.id.as_str() == function_id)
            .unwrap_or_else(|| panic!("missing {function_id}"));
        assert_eq!(definition.visibility, FunctionVisibility::NativeClient);
        assert!(definition.model_tool.is_none());
    }
}

#[test]
fn role_review_native_protocol_is_closed_confirmed_and_never_model_projected() {
    let definitions = function_definitions().expect("worker-kernel contracts");
    let expected = [
        "worker_kernel::role_reviews",
        "worker_kernel::role_review_start",
        "worker_kernel::role_review_inspect",
        "worker_kernel::role_review_apply",
        "worker_kernel::role_review_reject",
    ];
    for function_id in expected {
        let definition = definitions
            .iter()
            .find(|definition| definition.id.as_str() == function_id)
            .unwrap_or_else(|| panic!("missing {function_id}"));
        assert_eq!(definition.visibility, FunctionVisibility::NativeClient);
        assert!(definition.model_tool.is_none());
        assert_eq!(
            definition.request_schema.as_ref().unwrap()["additionalProperties"],
            false
        );
        assert_eq!(
            definition.response_schema.as_ref().unwrap()["additionalProperties"],
            false
        );
    }

    let list = definitions
        .iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::role_reviews")
        .unwrap();
    let list_request = list.request_schema.as_ref().unwrap();
    assert_eq!(list_request["properties"]["queueLimit"]["maximum"], 100);
    assert_eq!(list_request["properties"]["queueOffset"]["minimum"], 0);
    let list_response = list.response_schema.as_ref().unwrap();
    assert!(
        list_response["required"]
            .as_array()
            .unwrap()
            .iter()
            .any(|field| field == "queueNextOffset")
    );

    let apply = definitions
        .iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::role_review_apply")
        .unwrap();
    assert_eq!(
        apply.request_schema.as_ref().unwrap()["properties"]["confirmed"]["const"],
        true
    );
    let proposal = &apply.response_schema.as_ref().unwrap()["properties"]["proposal"];
    assert!(
        proposal["required"]
            .as_array()
            .unwrap()
            .iter()
            .any(|field| field == "reviewerInvocationId")
    );
}

#[test]
fn profile_owned_worker_mutations_do_not_require_a_session() {
    let definitions = function_definitions().expect("worker-kernel contracts");
    for function_id in [
        "worker_kernel::upsert",
        "worker_kernel::invoke",
        "worker_kernel::result_handoff",
        "worker_kernel::inbox_dismiss",
        "worker_kernel::role_review_start",
        "worker_kernel::role_review_apply",
        "worker_kernel::role_review_reject",
        "worker_kernel::detach",
        "worker_kernel::cancel",
        "worker_kernel::stop",
        "worker_kernel::disable",
        "worker_kernel::enable",
        "worker_kernel::retire",
        "worker_kernel::purge",
        "worker_kernel::rollback",
        "worker_kernel::webhook_rotate",
        "worker_kernel::stop_all",
    ] {
        let definition = definitions
            .iter()
            .find(|definition| definition.id.as_str() == function_id)
            .unwrap_or_else(|| panic!("missing {function_id}"));
        assert_eq!(
            definition
                .idempotency
                .as_ref()
                .map(|contract| contract.dedupe_scope),
            Some(DedupeScope::Profile),
            "{function_id} must work from the profile-level Engine console"
        );
    }

    for function_id in [
        "worker_kernel::filesystem_write",
        "worker_kernel::filesystem_edit",
        "worker_kernel::process_run",
        "worker_kernel::web_fetch",
    ] {
        let definition = definitions
            .iter()
            .find(|definition| definition.id.as_str() == function_id)
            .unwrap_or_else(|| panic!("missing {function_id}"));
        assert_eq!(
            definition
                .idempotency
                .as_ref()
                .map(|contract| contract.dedupe_scope),
            Some(DedupeScope::Session),
            "{function_id} must retain causal session-scoped replay"
        );
    }
}

#[test]
fn scheduled_work_and_inbox_dismissal_are_native_operator_contracts() {
    let definitions = function_definitions().expect("worker-kernel contracts");
    let scheduled = definitions
        .iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::scheduled_work")
        .expect("scheduled work contract");
    assert_eq!(scheduled.effect_class, EffectClass::PureRead);
    assert!(scheduled.model_tool.is_none());
    assert_eq!(
        scheduled.request_schema.as_ref().unwrap()["properties"]["limit"]["maximum"],
        100
    );

    let dismiss = definitions
        .iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::inbox_dismiss")
        .expect("inbox dismissal contract");
    assert_eq!(dismiss.effect_class, EffectClass::IdempotentWrite);
    assert!(dismiss.model_tool.is_none());
    assert_eq!(
        dismiss
            .idempotency
            .as_ref()
            .map(|contract| contract.dedupe_scope),
        Some(DedupeScope::Profile)
    );
}

#[test]
fn worker_invoke_admits_normal_model_overrides_but_not_retry_overrides() {
    let definitions = function_definitions().expect("worker-kernel contracts");
    let invoke = definitions
        .iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::invoke")
        .expect("worker invoke contract");
    let schema = invoke.request_schema.as_ref().expect("request schema");
    crate::engine::validate_engine_schema_payload(
        &invoke.id,
        "request",
        schema,
        &json!({
            "workerId":"research",
            "input":{},
            "idempotencyKey":"override-once",
            "mode":"wait",
            "model":"claude-sonnet-4-6",
            "reasoningLevel":"high",
            "compactResponse":true
        }),
    )
    .expect("normal invocation override");
    assert_eq!(schema["properties"]["compactResponse"]["type"], "boolean");
    let response = invoke.response_schema.as_ref().expect("response schema");
    assert!(response["properties"].get("input").is_some());
    assert!(
        !response["required"]
            .as_array()
            .unwrap()
            .iter()
            .any(|field| field == "input"),
        "compact responses may omit only the already-durable input"
    );
    let retry = json!({
        "retryOfInvocationId":"worker_run_previous",
        "mode":"wait",
        "model":"claude-sonnet-4-6"
    });
    assert!(
        crate::engine::validate_engine_schema_payload(&invoke.id, "request", schema, &retry,)
            .is_err()
    );
}

#[test]
fn upsert_exposes_the_complete_worker_bundle_authoring_schema() {
    let upsert = function_definitions()
        .unwrap()
        .into_iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::upsert")
        .expect("worker upsert contract");
    let description = &upsert.description;
    for required_guidance in [
        "Canonical authoring protocol",
        "worker_discover, worker_list, or worker_inspect",
        "semantic overlap is also checked during upsert",
        "author and exercise source in a temporary directory",
        "call worker_upsert once",
        "public worker tools to verify behavior",
        "complete authoritative authoring contract",
        "Never inspect or modify Tron databases, auth stores, binaries, runtime files, lock files, or private server endpoints",
        "report a concrete engine-contract gap instead of guessing or probing internals",
    ] {
        assert!(
            description.contains(required_guidance),
            "missing model-visible worker-authoring guidance: {required_guidance}"
        );
    }
    let schema = upsert.request_schema.expect("upsert request schema");
    let bundle = &schema["properties"]["bundle"];
    assert_eq!(bundle["additionalProperties"], false);
    assert!(
        bundle["description"]
            .as_str()
            .unwrap_or_default()
            .contains("self-contained")
    );
    assert!(
        bundle["description"]
            .as_str()
            .unwrap_or_default()
            .contains("report an engine-contract gap instead of probing Tron internals")
    );
    assert_eq!(
        bundle["properties"]["executionLimits"]["additionalProperties"],
        false
    );
    assert_eq!(
        bundle["properties"]["executionLimits"]["properties"]["maxInvocationSeconds"]["maximum"],
        7200
    );
    assert_eq!(
        bundle["properties"]["executionLimits"]["properties"]["maxAgentTurns"]["maximum"],
        250
    );
    assert_eq!(
        bundle["properties"]["executionLimits"]["properties"]["maxChildInvocations"]["maximum"],
        256
    );
    assert_eq!(
        bundle["properties"]["toolInputSchema"]["type"],
        json!("object")
    );
    assert_eq!(
        bundle["properties"]["modelExposure"]["enum"],
        json!(["direct", "internal"])
    );
    assert_eq!(
        bundle["properties"]["modelExposure"]["default"],
        json!("direct")
    );
    assert!(
        bundle["properties"]["toolInputSchema"]["description"]
            .as_str()
            .unwrap()
            .contains("Required JSON object schema")
    );
    assert_eq!(bundle["properties"]["agentTools"]["maxItems"], 32);
    assert_eq!(bundle["properties"]["agentTools"]["uniqueItems"], true);
    assert_eq!(
        bundle["properties"]["agentRole"]["oneOf"][1]["properties"]["toolCeiling"]["maxItems"],
        32
    );
    assert_eq!(
        bundle["properties"]["agentRole"]["oneOf"][1]["properties"]["limits"]["properties"]["maxQueuedAssignments"]
            ["maximum"],
        8
    );
    assert!(
        bundle["required"]
            .as_array()
            .unwrap()
            .iter()
            .any(|field| field == "provenance")
    );
    assert_eq!(
        bundle["properties"]["runner"]["oneOf"]
            .as_array()
            .unwrap()
            .len(),
        3
    );
    assert_eq!(
        bundle["properties"]["runner"]["oneOf"][0]["properties"]["reasoningLevel"]["enum"],
        json!(["none", "low", "medium", "high", "x_high", "max"])
    );
    assert_eq!(
        bundle["properties"]["triggers"]["items"]["oneOf"]
            .as_array()
            .unwrap()
            .len(),
        4
    );
    assert_eq!(
        bundle["properties"]["healthChecks"]["items"]["properties"]["timeoutSeconds"]["maximum"],
        7200
    );
    assert_eq!(
        bundle["properties"]["files"]["additionalProperties"]["type"],
        "string"
    );
    let dependency = &bundle["properties"]["dependencies"]["items"];
    assert!(
        !dependency["required"]
            .as_array()
            .unwrap()
            .iter()
            .any(|field| field == "checksum")
    );
    assert_eq!(schema["properties"]["sourceDirectory"]["type"], "string");
    let files_description = bundle["properties"]["files"]["description"]
        .as_str()
        .expect("worker files description");
    assert!(files_description.contains("non-executable"));
    assert!(files_description.contains("explicit interpreter"));
    let command_description =
        bundle["properties"]["runner"]["oneOf"][1]["properties"]["command"]["description"]
            .as_str()
            .expect("command runner description");
    assert!(command_description.contains("no shell parsing"));
    assert!(command_description.contains("python3"));
    assert_eq!(
        bundle["properties"]["engineHooks"]["items"]["enum"],
        json!([
            "agent_role_review",
            "continuity_context",
            "context_summary",
            "mailbox_curation",
            "session_organization",
            "session_title"
        ])
    );
    let hook_description = bundle["properties"]["engineHooks"]["description"]
        .as_str()
        .expect("engine hook authoring contract");
    for required_contract in [
        "agent_role_review input is a closed object requiring action:agent_role_review",
        "Output is a closed object requiring only agentRole and rationale:string(1..2000)",
        "never accepts arbitrary bundle rewrites",
        "continuity_context input is a closed object requiring action:continuity_context",
        "empty narrative means no continuity should be injected",
        "supplies the current working-directory identity as project",
        "session_organization input is a closed object",
        "sessionOrganizationMutations array(max 16)",
        "delete and arbitrary tags are not expressible",
        "session_title input is a closed object requiring userPrompt:string(max 4096) and assistantResponse:string(max 4096)",
        "output is a closed object requiring title:string(1..160)",
        "context_summary input is a closed object",
        "narrative:string(1..40000 characters)",
        "authoritative runtime ceilings of 10000 estimated tokens and 40000 UTF-8 bytes",
        "mailbox_curation input is a closed object",
        "do not inspect Tron databases, auth stores, binaries, runtime files, or private server endpoints",
    ] {
        assert!(
            hook_description.contains(required_contract),
            "missing model-visible engine-hook contract: {required_contract}"
        );
    }
    assert!(
        bundle["properties"]["dependencies"]["items"]["properties"]["source"]["description"]
            .as_str()
            .unwrap_or_default()
            .contains("../dependencies/<name>")
    );
}

#[test]
fn continuity_context_is_a_closed_internal_projection_not_model_vocabulary() {
    let definitions = function_definitions().expect("worker-kernel contracts");
    let hook = definitions
        .iter()
        .find(|definition| definition.id.as_str() == CONTINUITY_CONTEXT_FUNCTION)
        .expect("continuity context contract");
    assert_eq!(hook.visibility, FunctionVisibility::Internal);
    let request = hook.request_schema.as_ref().expect("request schema");
    assert_eq!(request["required"], json!(["query"]));
    assert_eq!(request["properties"]["query"]["maxLength"], 12000);
    assert_eq!(request["properties"]["project"]["maxLength"], 2048);
    assert_eq!(
        hook.response_schema.as_ref().expect("response schema")["properties"]["narrative"]["maxLength"],
        6000
    );
    assert!(hook.model_tool.is_none());
}

#[test]
fn context_summary_is_an_internal_worker_seam_not_a_model_primitive() {
    let definitions = function_definitions().expect("worker-kernel contracts");
    let hook = definitions
        .iter()
        .find(|definition| definition.id.as_str() == CONTEXT_SUMMARY_FUNCTION)
        .expect("context summary contract");
    assert_eq!(hook.visibility, FunctionVisibility::Internal);
    assert_eq!(
        hook.response_schema.as_ref().expect("response schema")["properties"]["narrative"]["maxLength"],
        40000
    );
    assert_eq!(CONTEXT_SUMMARY_MAX_ESTIMATED_TOKENS, 10_000);
    assert_eq!(CONTEXT_SUMMARY_MAX_NARRATIVE_BYTES, 40_000);
    assert_eq!(
        estimate_context_summary_tokens(&"x".repeat(CONTEXT_SUMMARY_MAX_NARRATIVE_BYTES)),
        CONTEXT_SUMMARY_MAX_ESTIMATED_TOKENS
    );
    assert!(hook.model_tool.is_none());
}

#[test]
fn session_title_is_an_internal_automatic_hook_not_a_model_primitive() {
    let definitions = function_definitions().expect("worker-kernel contracts");
    let hook = definitions
        .iter()
        .find(|definition| definition.id.as_str() == SESSION_TITLE_FUNCTION)
        .expect("session title hook contract");
    assert_eq!(hook.visibility, FunctionVisibility::Internal);
    assert_eq!(
        hook.request_schema.as_ref().expect("request schema")["required"],
        json!(["userPrompt", "assistantResponse"])
    );
    let response = hook.response_schema.as_ref().expect("response schema");
    assert_eq!(
        response["required"],
        json!(["handled", "queued", "updated"])
    );
    assert_eq!(response["additionalProperties"], false);
    assert!(response["properties"]["invocationId"].is_object());
    assert!(response["properties"].get("title").is_none());
    assert!(hook.model_tool.is_none());
}

#[test]
fn legacy_inbox_context_has_no_runtime_claim_boundary() {
    let definitions = function_definitions().expect("worker-kernel contracts");
    assert!(
        definitions
            .iter()
            .all(|definition| definition.id.as_str() != "worker_kernel::inbox_attach")
    );
}

#[test]
fn canonical_bundle_with_absent_optional_fields_round_trips_through_upsert_schema() {
    let bundle = WorkerBundle {
        schema_version: BUNDLE_SCHEMA.to_owned(),
        worker_id: None,
        name: "Round-trip worker".to_owned(),
        description: "Proves inspectable canonical bundles remain valid upsert input.".to_owned(),
        tool_name: None,
        model_exposure: Default::default(),
        tool_input_schema: Some(json!({
            "type":"object",
            "additionalProperties":false,
            "required":["query"],
            "properties":{"query":{"type":"string"}}
        })),
        agent_tools: Some(vec!["web_fetch".to_owned()]),
        agent_role: None,
        input_schema: json!({"type":"object"}),
        output_schema: json!({"type":"object"}),
        runner: WorkerRunner::Agent {
            instructions: "Return an object.".to_owned(),
            model: None,
            reasoning_level: None,
        },
        files: Default::default(),
        dependencies: vec![WorkerDependency {
            name: "fixture".to_owned(),
            source: "file:///tmp/fixture".to_owned(),
            version: "1".to_owned(),
            checksum: None,
            install: None,
        }],
        triggers: Vec::new(),
        secret_bindings: Vec::new(),
        smoke_tests: Vec::new(),
        health_checks: Vec::new(),
        provenance: vec![SourceProvenance {
            source: "test:round-trip".to_owned(),
            revision: None,
            checksum: None,
        }],
        engine_hooks: Vec::new(),
        engine_deliveries: Vec::new(),
        client_actions: Vec::new(),
        client_deliveries: Vec::new(),
        worker_dispatch_routes: Vec::new(),
        routing: Default::default(),
        execution_limits: Default::default(),
        presentation: None,
    };
    let mut service_bundle = bundle.clone();
    service_bundle.agent_tools = None;
    service_bundle.runner = WorkerRunner::Service {
        command: vec!["fixture-service".to_owned()],
        invoke_url: "http://127.0.0.1:9876/invoke".to_owned(),
        health_url: None,
    };
    service_bundle.triggers = vec![WorkerTrigger::Schedule {
        id: "periodic".to_owned(),
        every_seconds: 60,
        input: json!({}),
    }];
    let serialized = serde_json::to_value(bundle).expect("serialize canonical bundle");
    assert_eq!(serialized["modelExposure"], json!("direct"));
    assert_eq!(serialized["toolInputSchema"]["required"], json!(["query"]));
    assert_eq!(serialized["agentTools"], json!(["web_fetch"]));
    assert!(
        serialized
            .pointer("/provenance/0")
            .and_then(Value::as_object)
            .is_some_and(|provenance| !provenance.contains_key("checksum"))
    );
    let serialized_service =
        serde_json::to_value(service_bundle).expect("serialize service bundle");
    assert_eq!(
        serialized_service.pointer("/runner/invokeUrl"),
        Some(&json!("http://127.0.0.1:9876/invoke"))
    );
    assert!(serialized_service.pointer("/runner/healthUrl").is_none());
    assert_eq!(
        serialized_service.pointer("/triggers/0/everySeconds"),
        Some(&json!(60))
    );
    let decoded_service: WorkerBundle = serde_json::from_value(serialized_service.clone())
        .expect("deserialize canonical service bundle");
    assert!(matches!(
        decoded_service.runner,
        WorkerRunner::Service {
            health_url: None,
            ..
        }
    ));
    let mut legacy = serialized.clone();
    legacy
        .as_object_mut()
        .expect("bundle object")
        .remove("modelExposure");
    let decoded_legacy: WorkerBundle =
        serde_json::from_value(legacy).expect("decode pre-model-exposure bundle");
    assert!(decoded_legacy.exposes_model_tool());
    let upsert = function_definitions()
        .unwrap()
        .into_iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::upsert")
        .expect("worker upsert contract");
    let request_schema = upsert.request_schema.expect("upsert request schema");
    crate::engine::validate_engine_schema_payload(
        &crate::engine::FunctionId::new("worker_kernel::upsert").unwrap(),
        "request",
        &request_schema,
        &json!({"bundle":serialized}),
    )
    .expect("serialized canonical bundle remains valid worker_upsert input");
    crate::engine::validate_engine_schema_payload(
        &crate::engine::FunctionId::new("worker_kernel::upsert").unwrap(),
        "request",
        &request_schema,
        &json!({"bundle":serialized_service}),
    )
    .expect("serialized service bundle remains valid worker_upsert input");
}

#[test]
fn agent_role_is_explicit_strict_and_absent_legacy_bundles_need_review() {
    let declaration = WorkerAgentRole::Enabled {
        display_name: "Reviewer".to_owned(),
        summary: "Reviews bounded changes".to_owned(),
        discoverable: true,
        collaboration_instructions: "Report evidence and blockers.".to_owned(),
        default_model: None,
        default_reasoning_level: Some("high".to_owned()),
        tool_ceiling: vec!["filesystem_read".to_owned()],
        limits: WorkerAgentRoleLimits {
            max_assignment_seconds: Some(900),
            max_assignment_turns: Some(32),
            max_child_executions: Some(4),
            max_queued_assignments: Some(2),
        },
        result_mode: WorkerAgentResultMode::Natural,
    };
    let encoded = serde_json::to_value(declaration).expect("encode role declaration");
    assert_eq!(encoded["status"], "enabled");
    assert_eq!(encoded["toolCeiling"], json!(["filesystem_read"]));
    assert_eq!(
        serde_json::to_value(WorkerAgentRole::Disabled).unwrap(),
        json!({"status":"disabled"})
    );
}

#[test]
fn worker_upsert_exposes_only_the_closed_declarative_presentation_vocabulary() {
    let upsert = function_definitions()
        .unwrap()
        .into_iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::upsert")
        .expect("worker upsert contract");
    let request_schema = upsert.request_schema.expect("upsert request schema");
    let presentation = &request_schema["properties"]["bundle"]["properties"]["presentation"];
    assert_eq!(presentation["properties"]["sections"]["maxItems"], 24);
    assert_eq!(
        presentation["properties"]["sections"]["items"]["oneOf"]
            .as_array()
            .unwrap()
            .len(),
        9
    );
    let description = presentation["description"].as_str().unwrap();
    for forbidden in [
        "HTML",
        "JavaScript",
        "custom native code",
        "arbitrary client commands",
        "arbitrary URL schemes",
    ] {
        assert!(description.contains(forbidden), "{forbidden}");
    }

    let canonical_bundle = json!({
        "schemaVersion":"tron.worker_bundle.v1",
        "name":"Presentation worker",
        "description":"Exercises the generic native descriptor.",
        "inputSchema":{
            "type":"object","additionalProperties":false,
            "required":["action"],
            "properties":{"action":{"type":"string"}}
        },
        "outputSchema":{"type":"object"},
        "runner":{"kind":"agent","instructions":"Return a typed result."},
        "provenance":[{"source":"test:presentation"}],
        "presentation":{
            "experienceId":"generic-workflow",
            "contractVersion":1,
            "sections":[
                {"sectionId":"summary","kind":"text","valuePointer":"/summary"},
                {
                    "sectionId":"refresh","kind":"worker_action",
                    "action":{"actionId":"refresh","label":"Refresh","input":{"action":"refresh"}}
                }
            ]
        }
    });
    let function_id = crate::engine::FunctionId::new("worker_kernel::upsert").unwrap();
    crate::engine::validate_engine_schema_payload(
        &function_id,
        "request",
        &request_schema,
        &json!({"bundle":canonical_bundle.clone()}),
    )
    .expect("closed declarative presentation is admitted");

    for (field, value) in [
        ("html", json!("<script>unsafe()</script>")),
        ("javascript", json!("unsafe()")),
        ("swiftView", json!("UnsafeView")),
        ("clientCommand", json!("erase_device")),
    ] {
        let mut invalid = canonical_bundle.clone();
        invalid["presentation"]["sections"][0][field] = value;
        crate::engine::validate_engine_schema_payload(
            &function_id,
            "request",
            &request_schema,
            &json!({"bundle":invalid}),
        )
        .expect_err("undeclared native execution fields must be rejected");
    }

    let mut unsafe_url = canonical_bundle;
    unsafe_url["presentation"]["sections"][0] = json!({
        "sectionId":"source",
        "kind":"link",
        "label":"Open source",
        "url":"javascript:alert(1)"
    });
    crate::engine::validate_engine_schema_payload(
        &function_id,
        "request",
        &request_schema,
        &json!({"bundle":unsafe_url}),
    )
    .expect_err("non-HTTPS presentation links must be rejected");

    let runs = function_definitions()
        .unwrap()
        .into_iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::runs")
        .expect("worker runs contract");
    let run_node_presentation = &runs.response_schema.unwrap()["properties"]["graphs"]["items"]["properties"]
        ["nodes"]["items"]["properties"]["presentation"]["oneOf"][0];
    assert_eq!(
        run_node_presentation["properties"]["sections"]["maxItems"],
        24
    );
    assert_eq!(
        run_node_presentation["properties"]["sections"]["items"]["oneOf"]
            .as_array()
            .unwrap()
            .len(),
        9
    );
    let runs = function_definitions()
        .unwrap()
        .into_iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::runs")
        .expect("worker runs contract");
    let requested = &runs.response_schema.unwrap()["properties"]["graphs"]["items"]["properties"]["requestedInvocation"];
    assert_eq!(
        requested["properties"]["usage"]["properties"]["includesDescendants"]["type"],
        "boolean"
    );
    assert!(
        requested["required"]
            .as_array()
            .unwrap()
            .contains(&json!("effectiveModel"))
    );
    let runs = function_definitions()
        .unwrap()
        .into_iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::runs")
        .expect("worker runs contract");
    let detail_values = runs.request_schema.as_ref().unwrap()["properties"]["detail"]["enum"]
        .as_array()
        .unwrap();
    assert!(detail_values.contains(&json!("metrics")));
    let metrics = &runs.response_schema.unwrap()["properties"]["metrics"]["items"];
    assert_eq!(
        metrics["properties"]["timing"]["properties"]["wallMs"]["type"],
        "integer"
    );
    assert_eq!(
        metrics["properties"]["usage"]["properties"]["cost"]["type"],
        "number"
    );
}

#[test]
fn artifact_delivery_is_closed_and_exact_content_stays_authenticated() {
    let definitions = function_definitions().expect("worker-kernel contracts");
    let upsert = definitions
        .iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::upsert")
        .expect("worker upsert contract");
    let bundle = &upsert.request_schema.as_ref().unwrap()["properties"]["bundle"];
    assert!(
        bundle["properties"]["clientDeliveries"]["items"]["enum"]
            .as_array()
            .unwrap()
            .contains(&json!("artifact_delivery"))
    );
    let description = bundle["properties"]["clientDeliveries"]["description"]
        .as_str()
        .unwrap();
    for required in [
        "worker_result_reference",
        "current invocation",
        "RFC 6901",
        "content-addressed custody",
    ] {
        assert!(description.contains(required), "{required}");
    }
    for forbidden in ["URLs", "paths", "client commands", "draft mutations"] {
        assert!(description.contains(forbidden), "{forbidden}");
    }

    let list = definitions
        .iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::artifact_deliveries")
        .expect("artifact list contract");
    assert_eq!(list.effect_class, EffectClass::PureRead);
    assert_eq!(
        list.request_schema.as_ref().unwrap()["properties"]["limit"]["maximum"],
        200
    );
    assert_eq!(
        list.response_schema.as_ref().unwrap()["properties"]["nextOffset"]["oneOf"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    let content = definitions
        .iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::artifact_content")
        .expect("artifact content contract");
    assert_eq!(content.effect_class, EffectClass::PureRead);
    assert_eq!(
        content.response_schema.as_ref().unwrap()["properties"]["artifact"]["properties"]["contentReference"]
            ["properties"]["kind"]["const"],
        "artifact_content_reference"
    );
    assert_eq!(
        content.response_schema.as_ref().unwrap()["properties"]["data"]["maxLength"],
        2_796_204
    );
    let delete = definitions
        .iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::artifact_delete")
        .expect("artifact delete contract");
    assert_eq!(delete.effect_class, EffectClass::IdempotentWrite);
    assert_eq!(delete.risk_level, RiskLevel::Medium);
}

#[test]
fn archive_backed_worker_purge_remains_an_explicit_critical_live_state_removal() {
    let purge = function_definitions()
        .unwrap()
        .into_iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::purge")
        .expect("worker purge contract");
    assert_eq!(purge.effect_class, EffectClass::IrreversibleSideEffect);
    assert_eq!(purge.risk_level, RiskLevel::Critical);
    assert!(purge.description.contains("verified recovery archive"));
}

#[test]
fn direct_text_search_contract_exposes_shutdown_safe_ceilings() {
    let search = function_definitions()
        .unwrap()
        .into_iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::filesystem_search_text")
        .expect("direct text search contract");
    let schema = search.request_schema.expect("text search request schema");
    assert_eq!(
        schema["properties"]["timeoutSeconds"]["maximum"],
        MAX_TEXT_SEARCH_TIMEOUT_SECONDS
    );
    assert_eq!(
        schema["properties"]["maxWalkEntries"]["maximum"],
        MAX_TEXT_SEARCH_WALK_ENTRIES
    );
    assert!(search.description.contains("shutdown responsive"));
}

#[test]
fn web_fetch_defaults_protect_context_and_current_session_is_implicit() {
    let definitions = function_definitions().expect("worker-kernel contracts");
    let fetch = definitions
        .iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::web_fetch")
        .expect("web fetch contract");
    let fetch_schema = fetch.request_schema.as_ref().expect("fetch request schema");
    assert_eq!(fetch_schema["properties"]["maxBytes"]["default"], 131_072);
    assert_eq!(fetch_schema["properties"]["timeoutSeconds"]["default"], 30);
    assert!(fetch.description.contains("128 KiB"));
    assert!(
        fetch
            .response_schema
            .as_ref()
            .expect("fetch response schema")["required"]
            .as_array()
            .unwrap()
            .contains(&json!("contentSha256"))
    );
}

#[test]
fn mutation_checksum_contract_rejects_empty_or_inapplicable_preconditions() {
    let definitions = function_definitions().expect("worker-kernel contracts");
    let schema_for = |function_id: &str| {
        definitions
            .iter()
            .find(|definition| definition.id.as_str() == function_id)
            .and_then(|definition| definition.request_schema.clone())
            .unwrap_or_else(|| panic!("request schema for {function_id}"))
    };
    let write_schema = schema_for("worker_kernel::filesystem_write");
    let edit_schema = schema_for("worker_kernel::filesystem_edit");
    let write_id = crate::engine::FunctionId::new("worker_kernel::filesystem_write").unwrap();
    let edit_id = crate::engine::FunctionId::new("worker_kernel::filesystem_edit").unwrap();
    let hash = "a".repeat(64);

    for payload in [
        json!({"path":"new.txt","content":"value","expectedSha256":"absent"}),
        json!({"path":"old.txt","content":"value","expectedSha256":hash}),
    ] {
        crate::engine::validate_engine_schema_payload(
            &write_id,
            "request",
            &write_schema,
            &payload,
        )
        .expect("write checksum form is valid");
    }
    crate::engine::validate_engine_schema_payload(
        &edit_id,
        "request",
        &edit_schema,
        &json!({
            "path":"old.txt",
            "expectedSha256":format!("sha256:{}", "b".repeat(64)),
            "replacements":[{"oldText":"before","newText":"after"}]
        }),
    )
    .expect("edit hash form is valid");

    for (function_id, schema, payload) in [
        (
            &write_id,
            &write_schema,
            json!({"path":"new.txt","content":"value","expectedSha256":""}),
        ),
        (
            &edit_id,
            &edit_schema,
            json!({
                "path":"old.txt",
                "expectedSha256":"absent",
                "replacements":[{"oldText":"before","newText":"after"}]
            }),
        ),
    ] {
        crate::engine::validate_engine_schema_payload(function_id, "request", schema, &payload)
            .expect_err("invalid checksum precondition must fail at the tool boundary");
    }
}

#[test]
fn every_fixed_model_primitive_has_a_closed_top_level_response_contract() {
    let definitions = function_definitions().expect("worker-kernel contracts");
    for definition in definitions
        .iter()
        .filter(|definition| definition.model_tool.is_some())
    {
        let model_name = &definition.model_tool.as_ref().unwrap().name;
        let response = definition
            .response_schema
            .as_ref()
            .unwrap_or_else(|| panic!("missing response schema for {model_name}"));
        assert_eq!(
            response["additionalProperties"], false,
            "{} response must reject undeclared top-level fields",
            model_name
        );
        assert!(
            response["required"].is_array(),
            "{} response must name required observations",
            model_name
        );
    }
}

#[test]
fn worker_result_read_is_bounded_and_integrity_bound() {
    let definitions = function_definitions().expect("worker-kernel contracts");
    let read = definitions
        .iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::result_read")
        .expect("worker result read contract");
    assert_eq!(read.effect_class, EffectClass::PureRead);
    let request = read.request_schema.as_ref().expect("result read request");
    assert_eq!(request["properties"]["limit"]["maximum"], 20);
    assert_eq!(request["properties"]["pointer"]["maxLength"], 2_048);
    assert!(read.description.contains("JSON path/page"));
    let response = read.response_schema.as_ref().expect("result read response");
    assert_eq!(
        response["properties"]["reference"]["oneOf"][0]["properties"]["kind"]["const"],
        "worker_result_reference"
    );
    assert_eq!(
        response["properties"]["reference"]["oneOf"][0]["properties"]["contentSha256"]["pattern"],
        "^sha256:[0-9a-f]{64}$"
    );
    assert_eq!(
        response["properties"]["reference"]["oneOf"][0]["properties"]["outputSchemaSha256"]["pattern"],
        "^sha256:[0-9a-f]{64}$"
    );
}

#[test]
fn worker_result_handoff_is_client_only_and_profile_idempotent() {
    let definitions = function_definitions().expect("worker-kernel contracts");
    let handoff = definitions
        .iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::result_handoff")
        .expect("worker result handoff contract");

    assert_eq!(handoff.effect_class, EffectClass::IdempotentWrite);
    assert!(handoff.model_tool.is_none());
    assert_eq!(
        handoff
            .idempotency
            .as_ref()
            .map(|contract| contract.dedupe_scope),
        Some(DedupeScope::Profile)
    );
    let request = handoff.request_schema.as_ref().expect("handoff request");
    assert_eq!(request["additionalProperties"], false);
    assert_eq!(
        request["required"],
        json!(["invocationId", "workingDirectory", "model", "title"])
    );
    let response = handoff.response_schema.as_ref().expect("handoff response");
    assert_eq!(response["additionalProperties"], false);
    assert_eq!(response["properties"]["workspaceId"]["type"], "string");
}

#[test]
fn worker_history_defaults_to_compact_bounded_observations() {
    let definitions = function_definitions().expect("worker-kernel contracts");
    for function_id in ["worker_kernel::runs", "worker_kernel::inbox"] {
        let definition = definitions
            .iter()
            .find(|definition| definition.id.as_str() == function_id)
            .unwrap_or_else(|| panic!("missing {function_id}"));
        let request = definition.request_schema.as_ref().expect("request schema");
        assert_eq!(request["properties"]["limit"]["maximum"], 20);
        assert_eq!(request["properties"]["offset"]["minimum"], 0);
        assert_eq!(request["properties"]["detail"]["default"], "summary");
        let expected_detail = if function_id == "worker_kernel::runs" {
            json!(["summary", "metrics", "full", "graph"])
        } else {
            json!(["summary", "full"])
        };
        assert_eq!(request["properties"]["detail"]["enum"], expected_detail);
        assert!(definition.description.contains("bounded"));
        assert!(definition.description.contains("filtered"));
        let response = definition
            .response_schema
            .as_ref()
            .expect("response schema");
        assert!(
            response["required"]
                .as_array()
                .unwrap()
                .contains(&json!("truncated"))
        );
        assert!(
            response["required"]
                .as_array()
                .unwrap()
                .contains(&json!("contentTruncated"))
        );
        assert!(
            response["required"]
                .as_array()
                .unwrap()
                .contains(&json!("nextOffset"))
        );
    }
    let runs = definitions
        .iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::runs")
        .and_then(|definition| definition.request_schema.as_ref())
        .expect("runs request schema");
    assert_eq!(
        runs["properties"]["status"]["enum"],
        json!(["queued", "running", "completed", "failed", "cancelled"])
    );
    assert_eq!(
        runs["properties"]["originSessionId"]["type"],
        json!("string")
    );
    assert_eq!(runs["properties"]["invocationId"]["type"], json!("string"));
    assert_eq!(
        runs["properties"]["modelToolInvocationId"]["type"],
        json!("string")
    );
    let inbox = definitions
        .iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::inbox")
        .and_then(|definition| definition.request_schema.as_ref())
        .expect("inbox request schema");
    assert_eq!(
        inbox["properties"]["severity"]["enum"],
        json!(["info", "error"])
    );
    assert_eq!(inbox["properties"]["contextAttached"]["type"], "boolean");
    assert_eq!(inbox["properties"]["attentionOnly"]["type"], "boolean");
}

#[test]
fn worker_inspection_defaults_to_the_context_safe_contract_projection() {
    let definitions = function_definitions().expect("worker-kernel contracts");
    let inspect = definitions
        .iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::inspect")
        .expect("worker inspection contract");
    let request = inspect.request_schema.as_ref().expect("request schema");
    assert_eq!(request["properties"]["detail"]["default"], "contract");
    assert_eq!(
        request["properties"]["detail"]["enum"],
        json!(["contract", "full"])
    );
    assert!(inspect.description.contains("context-safe default"));
    let response = inspect.response_schema.as_ref().expect("response schema");
    assert!(
        response["required"]
            .as_array()
            .unwrap()
            .contains(&json!("detail"))
    );
    assert!(
        !response["required"]
            .as_array()
            .unwrap()
            .contains(&json!("audit"))
    );
}
