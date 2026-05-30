use super::support::*;

#[test]
fn registry_defaults_contract_and_implementation_from_function() {
    let function = test_function("filesystem::read_file");
    let entry =
        crate::domains::capability::registry::CapabilityRegistryEntry::from_function(function, 7);
    assert_eq!(entry.contract_id, "filesystem::read_file");
    assert_eq!(
        entry.implementation_id,
        "first_party.filesystem.v1.read_file"
    );
    assert_eq!(entry.plugin_id, "first_party.filesystem");
    assert_eq!(entry.catalog_revision, 7);
    assert!(!entry.schema_digest.is_empty());
}

#[test]
fn search_queries_supports_batch_without_splitting_into_many_primitive_calls() {
    let queries = search_queries(&json!({
        "query": "ignored when batch is present",
        "queries": [
            "notify",
            "ask user",
            "spawn subagent",
            "wait job",
            "display image",
            "computer action",
            "web fetch",
            "read file",
            "extra ignored by schema cap"
        ]
    }))
    .expect("queries");

    assert_eq!(queries.len(), 8);
    assert_eq!(queries[0], "notify");
    assert_eq!(queries[7], "read file");
}

#[test]
fn inspect_targets_accepts_string_shorthand_and_dedupes_targets() {
    let targets = inspect_targets(&json!({
        "targets": [
            "process::run",
            {"contractId": "process::run"},
            "process::run",
            {"functionId": "filesystem::read_file"}
        ]
    }))
    .expect("valid targets")
    .expect("targets");

    assert_eq!(targets.len(), 3);
    assert_eq!(targets[0]["capabilityId"], json!("process::run"));
    assert_eq!(targets[1]["contractId"], json!("process::run"));
    assert_eq!(targets[2]["functionId"], json!("filesystem::read_file"));
}

#[test]
fn render_batch_search_preserves_per_query_statuses() {
    let ready_status = CapabilityIndexStatus {
        lexical: true,
        local_vector: true,
        cloud_embeddings: false,
        vector_store: "sqlite-vec:vec0".to_owned(),
        embedding_model: "fastembed:test".to_owned(),
        state: "ready".to_owned(),
        degraded_reason: None,
    };
    let degraded_status = CapabilityIndexStatus {
        lexical: true,
        local_vector: false,
        cloud_embeddings: false,
        vector_store: "none".to_owned(),
        embedding_model: "none".to_owned(),
        state: "unavailable".to_owned(),
        degraded_reason: Some("embedding assets unavailable".to_owned()),
    };
    let hit = CapabilityIndexHit {
        kind: "implementation".to_owned(),
        capability_id: "process::run".to_owned(),
        contract_id: "process::run".to_owned(),
        implementation_id: "first_party.process.v1.run".to_owned(),
        plugin_id: "first_party.process".to_owned(),
        worker_id: "process".to_owned(),
        function_id: "process::run".to_owned(),
        catalog_revision: 7,
        schema_digest: "digest".to_owned(),
        trust_tier: "first_party_signed".to_owned(),
        health: "Healthy".to_owned(),
        visibility: "system".to_owned(),
        effect_class: "external_side_effect".to_owned(),
        risk_level: "low".to_owned(),
        lexical_score: 1.0,
        vector_score: Some(0.5),
        fused_score: 1.5,
        matched_by: "hybrid".to_owned(),
        snippet: "Run a process".to_owned(),
        requires_inspect: false,
        recipe: None,
    };

    let value = render_search_result_value(
        vec![
            (
                "process".to_owned(),
                crate::domains::capability::registry::CapabilityIndexSearchResult {
                    hits: vec![hit],
                    status: ready_status,
                },
            ),
            (
                "notify".to_owned(),
                crate::domains::capability::registry::CapabilityIndexSearchResult {
                    hits: Vec::new(),
                    status: degraded_status,
                },
            ),
        ],
        7,
        0,
        10,
    )
    .expect("result");
    let details = value["details"].as_object().expect("details");
    let queries = details["queries"].as_array().expect("batch queries");

    assert_eq!(queries.len(), 2);
    assert_eq!(queries[0]["query"], json!("process"));
    assert_eq!(queries[0]["searchMode"]["state"], json!("ready"));
    assert_eq!(queries[1]["query"], json!("notify"));
    assert_eq!(
        queries[1]["searchMode"]["degradedReason"],
        json!("embedding assets unavailable")
    );
}

#[test]
fn search_visible_content_contains_actionable_recipe() {
    let process_spec = crate::domains::process::contract::capabilities()
        .expect("process specs")
        .into_iter()
        .find(|spec| spec.function_id.as_str() == "process::run")
        .expect("process::run spec");
    let function = crate::domains::contract::function_definition_for_capability(&process_spec);
    let entry = CapabilityRegistryEntry::from_function(function, 9);
    let recipe = entry.agent_recipe();
    let hit = CapabilityIndexHit {
        kind: "implementation".to_owned(),
        capability_id: entry.capability_id(),
        contract_id: entry.contract_id.clone(),
        implementation_id: entry.implementation_id.clone(),
        plugin_id: entry.plugin_id.clone(),
        worker_id: entry.worker_id.clone(),
        function_id: entry.function_id.clone(),
        catalog_revision: entry.catalog_revision,
        schema_digest: entry.schema_digest.clone(),
        trust_tier: entry.trust_tier.clone(),
        health: "Healthy".to_owned(),
        visibility: "system".to_owned(),
        effect_class: "external_side_effect".to_owned(),
        risk_level: "high".to_owned(),
        lexical_score: 1.0,
        vector_score: None,
        fused_score: 1.0,
        matched_by: "local_lexical".to_owned(),
        snippet: "Run a bounded shell command".to_owned(),
        requires_inspect: false,
        recipe: Some(recipe),
    };
    let status = CapabilityIndexStatus {
        lexical: true,
        local_vector: false,
        cloud_embeddings: false,
        vector_store: "none".to_owned(),
        embedding_model: "none".to_owned(),
        state: "ready".to_owned(),
        degraded_reason: None,
    };

    let value = render_search_result_value(
        vec![(
            "process run shell command date".to_owned(),
            crate::domains::capability::registry::CapabilityIndexSearchResult {
                hits: vec![hit],
                status,
            },
        )],
        9,
        0,
        10,
    )
    .expect("search result");
    let content = value["content"][0]["text"].as_str().expect("text content");

    assert!(content.contains("process::run"));
    assert!(content.contains("intent, optional target"));
    assert!(content.contains("Do not wrap another `capability::execute` call"));
    assert!(content.contains("do not run example/probe calls"));
    assert!(
        content.contains("\"arguments\":{\"command\":\"date\",\"executionMode\":\"read_only\"}")
    );
    assert!(content.contains("Required arguments: command: string"));
    assert!(content.contains("executionMode: string"));
    assert!(!content.contains("process::run -> process::run"));
    assert_eq!(
        value["details"]["results"][0]["recipe"]["contractId"],
        json!("process::run")
    );
    let required_payload = value["details"]["results"][0]["recipe"]["requiredPayload"]
        .as_array()
        .expect("required payload summaries");
    let required_command = required_payload
        .iter()
        .filter_map(|summary| summary.as_str())
        .find(|summary| summary.starts_with("command: string"))
        .expect("required command summary");
    assert!(required_command.starts_with("command: string"));
    let command_summary = required_command.to_ascii_lowercase();
    assert!(command_summary.contains("shell command to run"));
    assert!(command_summary.contains("date"));
    assert!(
        required_payload
            .iter()
            .filter_map(|summary| summary.as_str())
            .any(|summary| {
                summary.starts_with("executionMode: string")
                    && summary.contains("read_only")
                    && summary.contains("sandbox_materialized")
            })
    );
}

#[test]
fn explicit_implementation_id_can_address_function_ids() {
    let params = json!({"implementationId": "function:filesystem::read_file"});
    let target = parse_target(&params).expect("target");
    assert!(matches!(
        target,
        crate::domains::capability::registry::CapabilityTarget::Implementation(value)
            if value == "function:filesystem::read_file"
    ));
}

#[test]
fn parse_target_ignores_blank_higher_priority_fields() {
    let params = json!({
        "functionId": "",
        "implementationId": "   ",
        "contractId": "",
        "capabilityId": " process::run "
    });
    let target = parse_target(&params).expect("target");
    assert!(matches!(
        target,
        crate::domains::capability::registry::CapabilityTarget::Capability(value)
            if value == "process::run"
    ));
}

#[test]
fn inspection_summary_surfaces_copyable_execute_requirements() {
    let details = json!({
        "contract": {
            "contractId": "process::run",
            "effectClass": "external_side_effect",
            "riskLevel": "high",
            "inputSchema": {
                "type": "object",
                "required": ["command"]
            }
        },
        "implementation": {
            "functionId": "process::run"
        },
        "recipe": {
            "executeTemplate": {
                "intent": "Run a read-only process command.",
                "target": "process::run",
                "arguments": {
                    "command": "date",
                    "executionMode": "read_only"
                }
            },
            "requiredPayload": [
                "command: string",
                "executionMode: string [read_only|sandbox_materialized]"
            ],
            "optionalPayload": [
                "expectedOutputs: array<object>",
                "cwd: string"
            ]
        },
        "executionRequirements": {
            "approvalRequired": true,
            "expectedRevision": 1,
            "expectedSchemaDigest": "digest-123",
            "freshInspectionRequired": true,
            "idempotencyKeyRequired": true,
            "inspectionHandle": "capability-inspection:v1:test"
        }
    });

    let summary = render_inspection_summary(&details);

    assert!(summary.contains("inspectionHandle=capability-inspection:v1:test"));
    assert!(summary.contains("\"target\":\"process::run\""));
    assert!(summary.contains("\"executionMode\":\"read_only\""));
    assert!(summary.contains("do not set target to `capability::execute`"));
    assert!(summary.contains("do not run example/probe calls"));
    assert!(summary.contains("expectedRevision=1"));
    assert!(summary.contains("expectedSchemaDigest=digest-123"));
    assert!(summary.contains("Execute arguments must include: command: string, executionMode: string [read_only|sandbox_materialized]."));
    assert!(
        summary
            .contains("Optional arguments include: expectedOutputs: array<object>, cwd: string.")
    );
    assert!(summary.contains("For sandbox_materialized process::run, include expectedOutputs exactly as an array of objects"));
    assert!(summary.contains("materializedOutputs"));
    assert!(summary.contains("idempotencyKey is required"));
    assert!(summary.contains("approvalRequired=true"));
}

#[test]
fn inspection_summary_explains_conditional_approval() {
    let details = json!({
        "contract": {
            "contractId": "process::run",
            "effectClass": "external_side_effect",
            "riskLevel": "high",
            "inputSchema": {
                "type": "object",
                "required": ["command"]
            }
        },
        "implementation": {
            "functionId": "process::run"
        },
        "executionRequirements": {
            "approvalMode": "conditional",
            "approvalRequired": false,
            "expectedRevision": 1,
            "expectedSchemaDigest": "digest-123",
            "freshInspectionRequired": true,
            "idempotencyKeyRequired": true,
            "inspectionHandle": "capability-inspection:v1:test"
        }
    });

    let summary = render_inspection_summary(&details);

    assert!(summary.contains("approvalMode=conditional"));
    assert!(summary.contains("safe read-only payloads run directly"));
}

#[test]
fn missing_inspection_error_reports_exact_missing_execute_fields() {
    let mut function = test_function("process::run");
    function.effect_class = EffectClass::ExternalSideEffect;
    function.risk_level = RiskLevel::High;
    let entry = crate::domains::capability::registry::CapabilityRegistryEntry::from_function(
        function.clone(),
        303,
    );

    let error = missing_inspection_requirements_error(&function, &entry, Some(1), None, None);

    match error {
        CapabilityError::Custom {
            code,
            message,
            details: Some(details),
        } => {
            assert_eq!(code, "INSPECTION_REQUIRED");
            assert!(message.contains("copy inspectionHandle"));
            assert_eq!(
                details["missingFields"],
                json!(["inspectionHandle", "expectedSchemaDigest"])
            );
            assert_eq!(details["inspect"]["functionId"], json!("process::run"));
            assert_eq!(details["inspect"]["expectedRevision"], json!(1));
            assert_eq!(
                details["inspect"]["expectedSchemaDigest"],
                json!(entry.schema_digest)
            );
        }
        other => panic!("unexpected error: {other:?}"),
    }
}

#[test]
fn inspection_summary_keeps_low_risk_capabilities_concise() {
    let details = json!({
        "contract": {
            "contractId": "filesystem::read_file",
            "effectClass": "pure_read",
            "riskLevel": "low"
        },
        "implementation": {
            "functionId": "filesystem::read_file"
        },
        "executionRequirements": {
            "approvalRequired": false,
            "expectedRevision": 1,
            "expectedSchemaDigest": "digest-read",
            "freshInspectionRequired": false,
            "idempotencyKeyRequired": false,
            "inspectionHandle": "capability-inspection:v1:read"
        }
    });

    let summary = render_inspection_summary(&details);

    assert!(summary.contains("filesystem::read_file is implemented by filesystem::read_file"));
    assert!(!summary.contains("inspectionHandle="));
    assert!(!summary.contains("idempotencyKey is required"));
}

#[test]
fn function_target_accepts_implementation_id_for_model_recovery() {
    let function = test_function("process::run");
    let entry =
        crate::domains::capability::registry::CapabilityRegistryEntry::from_function(function, 7);
    let target = crate::domains::capability::registry::CapabilityTarget::Function(
        "first_party.process.v1.run".to_owned(),
    );
    assert!(target.matches(&entry));
}
