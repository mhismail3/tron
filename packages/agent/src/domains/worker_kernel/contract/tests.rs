use super::*;
use crate::domains::worker_kernel::types::{
    BUNDLE_SCHEMA, SourceProvenance, WorkerBundle, WorkerDependency, WorkerRunner, WorkerTrigger,
};
use crate::engine::DedupeScope;

#[test]
fn engine_surface_snapshot_is_client_introspection_not_model_vocabulary() {
    let definitions = function_definitions().expect("worker-kernel contracts");
    let surface = definitions
        .iter()
        .find(|definition| definition.id.as_str() == ENGINE_SURFACE_SNAPSHOT_FUNCTION)
        .expect("surface snapshot contract");
    assert_eq!(surface.id.as_str(), ENGINE_SURFACE_SNAPSHOT_FUNCTION);
    assert_eq!(surface.effect_class, EffectClass::PureRead);
    assert!(
        core_primitives()
            .iter()
            .all(|descriptor| descriptor.model_name != "engine_surface_snapshot")
    );
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
fn profile_owned_worker_mutations_do_not_require_a_session() {
    let definitions = function_definitions().expect("worker-kernel contracts");
    for function_id in [
        "worker_kernel::upsert",
        "worker_kernel::invoke",
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
        "worker_kernel::session_set_title",
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
fn upsert_exposes_the_complete_worker_bundle_authoring_schema() {
    let upsert = function_definitions()
        .unwrap()
        .into_iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::upsert")
        .expect("worker upsert contract");
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
        json!(["context_summary", "inbox_context", "worker_relevance"])
    );
    assert!(
        bundle["properties"]["dependencies"]["items"]["properties"]["source"]["description"]
            .as_str()
            .unwrap_or_default()
            .contains("../dependencies/<name>")
    );
}

#[test]
fn context_summary_is_an_internal_worker_seam_not_a_model_primitive() {
    let definitions = function_definitions().expect("worker-kernel contracts");
    let hook = definitions
        .iter()
        .find(|definition| definition.id.as_str() == CONTEXT_SUMMARY_FUNCTION)
        .expect("context summary contract");
    assert_eq!(hook.visibility, FunctionVisibility::Internal);
    assert!(
        core_primitives()
            .iter()
            .all(|primitive| primitive.function_id != CONTEXT_SUMMARY_FUNCTION)
    );
}

#[test]
fn worker_relevance_is_internal_policy_not_provider_ceremony() {
    let definitions = function_definitions().expect("worker-kernel contracts");
    let hook = definitions
        .iter()
        .find(|definition| definition.id.as_str() == WORKER_RELEVANCE_FUNCTION)
        .expect("worker relevance contract");
    assert_eq!(hook.visibility, FunctionVisibility::Internal);
    assert!(
        core_primitives()
            .iter()
            .all(|primitive| primitive.function_id != WORKER_RELEVANCE_FUNCTION)
    );
}

#[test]
fn inbox_context_is_worker_owned_policy_behind_an_internal_claim_boundary() {
    let definitions = function_definitions().expect("worker-kernel contracts");
    let attach = definitions
        .iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::inbox_attach")
        .expect("inbox attachment contract");
    assert_eq!(attach.visibility, FunctionVisibility::Internal);
    assert!(
        core_primitives()
            .iter()
            .all(|primitive| primitive.function_id != "worker_kernel::inbox_attach")
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
        input_schema: json!({"type":"object"}),
        output_schema: json!({"type":"object"}),
        runner: WorkerRunner::Agent {
            instructions: "Return an object.".to_owned(),
            model: None,
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
        routing: Default::default(),
        presentation: None,
    };
    let mut service_bundle = bundle.clone();
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

    let title = definitions
        .iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::session_set_title")
        .expect("session title contract");
    let title_schema = title.request_schema.as_ref().expect("title request schema");
    assert_eq!(title_schema["required"], json!(["title"]));
    assert_eq!(
        title_schema["properties"]
            .as_object()
            .unwrap()
            .keys()
            .collect::<Vec<_>>(),
        vec!["title"]
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
    for descriptor in core_primitives() {
        let function_id = descriptor.function_id;
        let definition = definitions
            .iter()
            .find(|definition| definition.id.as_str() == function_id)
            .unwrap_or_else(|| panic!("missing contract for {}", descriptor.model_name));
        let response = definition
            .response_schema
            .as_ref()
            .unwrap_or_else(|| panic!("missing response schema for {}", descriptor.model_name));
        assert_eq!(
            response["additionalProperties"], false,
            "{} response must reject undeclared top-level fields",
            descriptor.model_name
        );
        assert!(
            response["required"].is_array(),
            "{} response must name required observations",
            descriptor.model_name
        );
    }
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
        assert_eq!(
            request["properties"]["detail"]["enum"],
            json!(["summary", "full"])
        );
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
