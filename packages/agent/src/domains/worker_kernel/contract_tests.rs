use super::*;
use crate::domains::worker_kernel::types::{
    BUNDLE_SCHEMA, SourceProvenance, WorkerBundle, WorkerDependency, WorkerRunner, WorkerTrigger,
};

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
    assert!(
        bundle["properties"]["dependencies"]["items"]["properties"]["source"]["description"]
            .as_str()
            .unwrap_or_default()
            .contains("../dependencies/<name>")
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
        routing: Default::default(),
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
fn permanent_worker_purge_is_explicitly_irreversible() {
    let purge = function_definitions()
        .unwrap()
        .into_iter()
        .find(|definition| definition.id.as_str() == "worker_kernel::purge")
        .expect("worker purge contract");
    assert_eq!(purge.effect_class, EffectClass::IrreversibleSideEffect);
    assert_eq!(purge.risk_level, RiskLevel::Critical);
    assert!(purge.description.contains("Permanently purge"));
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
