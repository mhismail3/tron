use super::*;

fn result(text: &str, is_error: bool, details: Value) -> CapabilityResult {
    CapabilityResult {
        content: CapabilityResultBody::Text(text.to_owned()),
        details: Some(details),
        is_error: is_error.then_some(true),
        stop_turn: None,
    }
}

fn successful_details(operation: &str) -> Value {
    match operation {
        "catalog_search" | "catalog_inspect" | "catalog_conformance" => json!({
            "primitiveOperation": operation,
            "status": "ok",
            "catalogDiscovery": {"kind": "execute_operation", "id": "execute::observe"}
        }),
        "git_status" => json!({
            "primitiveOperation": operation,
            "status": "ok",
            "git": {
                "schemaVersion": "tron.git_readonly.v1",
                "operation": "status",
                "status": "clean",
                "summary": {"stagedCount": 0},
                "evidence": {"resourceRefs": []}
            }
        }),
        "web_robots_check" => json!({
            "primitiveOperation": operation,
            "status": "ok",
            "web": {
                "schemaVersion": "tron.web_robots_policy.v1",
                "operation": operation,
                "status": "checked",
                "webRobotsPolicyResourceId": "web_robots_policy:test",
                "webRobotsPolicyVersionId": "version:test",
                "resourceRefs": []
            }
        }),
        "web_fetch" => json!({
            "primitiveOperation": operation,
            "status": "ok",
            "web": {
                "schemaVersion": "tron.web_source.v1",
                "operation": operation,
                "status": "fetched",
                "webSourceResourceId": "web_source:test",
                "webSourceVersionId": "version:test",
                "resourceRefs": []
            }
        }),
        "job_status" => json!({
            "primitiveOperation": operation,
            "status": "ok",
            "jobs": {
                "schemaVersion": "tron.jobs.provider_safe.v1",
                "job": {"state": "completed"},
                "resourceRefs": []
            }
        }),
        "job_list" => json!({
            "primitiveOperation": operation,
            "status": "ok",
            "jobs": {"schemaVersion": "tron.jobs.provider_safe.v1", "jobs": []}
        }),
        "job_log" => json!({
            "primitiveOperation": operation,
            "status": "ok",
            "jobs": {
                "schemaVersion": "tron.jobs.provider_safe.v1",
                "jobResourceId": "job_process:test",
                "jobVersionId": "version:test",
                "resourceRefs": []
            }
        }),
        "trace_list" => json!({
            "primitiveOperation": operation,
            "status": "ok",
            "projectionBoundary": {"providerVisibleProjection": true},
            "statusSummary": {"totalRecords": 0},
            "records": []
        }),
        "trace_get" => json!({
            "primitiveOperation": operation,
            "status": "ok",
            "projectionBoundary": {"providerVisibleProjection": true},
            "record": {"schemaVersion": "tron.trace.provider_safe.v1"}
        }),
        "context_control_status" => json!({
            "primitiveOperation": operation,
            "status": "ok",
            "contextControl": {
                "schemaVersion": "tron.context_control.v1",
                "projection": {"status": {"epoch": "epoch-0"}}
            }
        }),
        "capability_binding_cockpit_overview" => json!({
            "primitiveOperation": operation,
            "status": "ok",
            "capabilityBinding": {
                "summary": {"totalOperations": OperationId::ALL_NAMES.len()},
                "operations": []
            }
        }),
        _ => json!({"primitiveOperation": operation, "status": "ok", "summary": "done"}),
    }
}

#[test]
fn every_operation_has_one_closed_profiled_output_schema() {
    for operation in OperationId::ALL_NAMES {
        let schema = output_schema(operation).expect("supported output schema");
        assert_eq!(schema["additionalProperties"], false, "{operation}");
        assert_eq!(schema["properties"]["operation"]["const"], *operation);
        assert_eq!(
            schema["schemaCompleteness"], "exact_provider_operation_output",
            "{operation}"
        );
    }
}

#[test]
fn success_and_failure_outputs_are_closed_and_bounded() {
    for result in [
        result(
            "ok",
            false,
            json!({
                "primitiveOperation": "git_status",
                "status": "ok",
                "git": {
                    "schemaVersion": "tron.git_readonly.v1",
                    "operation": "status",
                    "status": "clean",
                    "summary": {"stagedCount": 0},
                    "evidence": {"resourceRefs": []}
                }
            }),
        ),
        result(
            "failed",
            true,
            json!({
                "primitiveOperation": "git_status",
                "failure": {
                    "code": "ROUTE_STALE",
                    "category": "invalid_request",
                    "message": "route evidence is stale",
                    "recoverable": true
                },
                "dynamicReplacement": {"status": "failed_closed"}
            }),
        ),
    ] {
        let rendered = render_provider_output("git_status", &result).expect("provider output");
        assert!(rendered.len() <= PROVIDER_OUTPUT_MAX_BYTES);
        let value: Value = serde_json::from_str(&rendered).expect("valid JSON");
        assert_eq!(
            value["truncation"]["serializedBytes"],
            rendered.len(),
            "serialized byte proof must describe the transmitted bytes"
        );
        let operation = OperationId::GitStatus;
        validate_provider_output(operation.as_str(), contract(operation), &value)
            .expect("valid output");
    }
}

#[test]
fn raw_details_cannot_bypass_provider_evidence_algebra() {
    let result = result(
        "done",
        false,
        json!({
            "primitiveOperation": "observe",
            "status": "ok",
            "summary": "safe",
            "command": "secret command",
            "workingDirectory": "/private/example",
            "apiKey": "sk-example-secret-value"
        }),
    );
    let rendered = render_provider_output("observe", &result).expect("provider output");
    assert!(!rendered.contains("secret command"));
    assert!(!rendered.contains("/private/example"));
    assert!(!rendered.contains("sk-example-secret-value"));
}

#[test]
fn common_only_summary_evidence_remains_semantically_complete() {
    let result = result(
        "Observation recorded.",
        false,
        json!({
            "primitiveOperation": "observe",
            "status": "ok"
        }),
    );
    let rendered = render_provider_output("observe", &result).expect("provider output");
    let value: Value = serde_json::from_str(&rendered).expect("valid provider JSON");

    assert_eq!(value["ok"], true);
    assert!(value["evidence"]["facts"].as_array().is_some_and(|facts| {
        facts
            .iter()
            .any(|fact| fact["field"] == "primitiveOperation" && fact["value"] == "observe")
    }));
}

#[test]
fn catalog_inspect_synthesizes_common_facts_from_the_canonical_envelope() {
    let result = result(
        "Catalog execute_operation inspected: execute::git_status.",
        false,
        json!({
            "catalogDiscovery": {
                "kind": "execute_operation",
                "id": "execute::git_status",
                "operation": "git_status",
                "providerCallable": true,
                "inputSchema": {
                    "type": "object",
                    "required": ["operation"]
                }
            }
        }),
    );

    let rendered = render_provider_output("catalog_inspect", &result)
        .expect("real catalog-inspect details must satisfy the canonical output contract");
    let value: Value = serde_json::from_str(&rendered).expect("valid provider JSON");

    assert_eq!(value["ok"], true);
    assert_eq!(value["status"], "ok");
    assert!(value["evidence"]["facts"].as_array().is_some_and(|facts| {
        facts
            .iter()
            .any(|fact| fact["field"] == "primitiveOperation" && fact["value"] == "catalog_inspect")
            && facts
                .iter()
                .any(|fact| fact["field"] == "status" && fact["value"] == "ok")
    }));
}

#[test]
fn raw_content_is_sanitized_at_the_provider_boundary() {
    let result = result(
        "authority grant grant_123456789 at /private/example; providerInvocationId=call_123456789; token sk-example-secret-value",
        false,
        json!({
            "primitiveOperation": "observe",
            "status": "ok",
            "summary": "safe"
        }),
    );
    let rendered = render_provider_output("observe", &result).expect("provider output");
    assert!(!rendered.contains("grant_123456789"));
    assert!(!rendered.contains("/private/example"));
    assert!(!rendered.contains("call_123456789"), "{rendered}");
    assert!(!rendered.contains("sk-example-secret-value"));
}

#[test]
fn inline_image_blocks_fail_closed_to_text_only_transport() {
    let result = CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::image(
            "base64-data",
            "image/png",
        )]),
        details: Some(successful_details("observe")),
        is_error: None,
        stop_turn: None,
    };
    let CapabilityResultMessageContent::Text(rendered) =
        provider_result_content("observe", &result)
    else {
        panic!("provider transport must be text only");
    };
    assert!(rendered.contains("PROVIDER_OUTPUT_UNCUSTODIED_MEDIA"));
    assert!(!rendered.contains("base64-data"));
}

#[test]
fn large_outputs_are_structurally_truncated_as_valid_json() {
    let values = (0..1_000)
            .map(|index| json!({"kind": "record", "resourceId": format!("record-{index}"), "summary": "x".repeat(1_000)}))
            .collect::<Vec<_>>();
    let result = result(
        "large",
        false,
        json!({
            "primitiveOperation": "module_list",
            "status": "ok",
            "records": values
        }),
    );
    let rendered = render_provider_output("module_list", &result).expect("provider output");
    assert!(rendered.len() <= PROVIDER_OUTPUT_MAX_BYTES);
    let value: Value = serde_json::from_str(&rendered).expect("valid JSON");
    assert_eq!(value["truncation"]["truncated"], true);
}

#[test]
fn byte_budget_omission_proof_counts_each_removed_item_once() {
    let mut output = ProviderOperationOutput {
        schema_version: PROVIDER_OUTPUT_SCHEMA_VERSION,
        operation: "observe".to_owned(),
        profile: "summary",
        ok: true,
        status: "ok".to_owned(),
        summary: "x".repeat(PROVIDER_OUTPUT_MAX_BYTES),
        evidence: ProviderEvidence {
            facts: Vec::new(),
            resources: Vec::new(),
            collections: vec![ProviderCollection {
                field: "records".to_owned(),
                total: 100,
                returned: 12,
                truncated: true,
                items: vec![ProviderCollectionItem::default(); 12],
            }],
        },
        next_actions: vec![ProviderNextAction {
            source: "agentNextStep".to_owned(),
            summary: "inspect".repeat(200),
            operation: Some("catalog_inspect".to_owned()),
            inspect_id: Some("execute::observe".to_owned()),
            arguments: None,
        }],
        truncation: ProviderTruncation {
            truncated: true,
            omitted_items: 88,
            max_bytes: PROVIDER_OUTPUT_MAX_BYTES,
            ..ProviderTruncation::default()
        },
        error: None,
    };

    fit_output_budget(&mut output, &[], &[]).expect("output fits after structural removal");

    assert_eq!(output.truncation.omitted_collections, 1);
    assert_eq!(output.truncation.omitted_items, 100);
    assert_eq!(output.truncation.omitted_actions, 1);
    assert_eq!(output.truncation.omitted_facts, 0);
}

#[test]
fn byte_budget_never_removes_required_semantic_facts() {
    let mut facts = vec![
        ProviderFact {
            field: "primitiveOperation".to_owned(),
            value: json!("observe"),
        },
        ProviderFact {
            field: "status".to_owned(),
            value: json!("ok"),
        },
    ];
    facts.extend((0..80).map(|index| ProviderFact {
        field: format!("extra.{index}"),
        value: json!("x".repeat(800)),
    }));
    let mut output = ProviderOperationOutput {
        schema_version: PROVIDER_OUTPUT_SCHEMA_VERSION,
        operation: "observe".to_owned(),
        profile: "summary",
        ok: true,
        status: "ok".to_owned(),
        summary: "done".to_owned(),
        evidence: ProviderEvidence {
            facts,
            resources: Vec::new(),
            collections: Vec::new(),
        },
        next_actions: Vec::new(),
        truncation: ProviderTruncation {
            max_bytes: PROVIDER_OUTPUT_MAX_BYTES,
            ..ProviderTruncation::default()
        },
        error: None,
    };

    fit_output_budget(&mut output, &["primitiveOperation", "status"], &[])
        .expect("non-required facts make the envelope reducible");

    assert!(
        output
            .evidence
            .facts
            .iter()
            .any(|fact| fact.field == "primitiveOperation")
    );
    assert!(
        output
            .evidence
            .facts
            .iter()
            .any(|fact| fact.field == "status")
    );
    assert!(output.truncation.omitted_facts > 0);
}

#[test]
fn byte_budget_preserves_newest_item_in_required_collection() {
    let items = (0..12)
        .map(|index| ProviderCollectionItem {
            facts: vec![
                ProviderFact {
                    field: "traceRecordId".to_owned(),
                    value: json!(format!("trace-record-{index}")),
                },
                ProviderFact {
                    field: "operation".to_owned(),
                    value: json!("trace_list"),
                },
                ProviderFact {
                    field: "verboseProof".to_owned(),
                    value: json!("x".repeat(800)),
                },
            ],
            resources: Vec::new(),
        })
        .collect::<Vec<_>>();
    let mut output = ProviderOperationOutput {
        schema_version: PROVIDER_OUTPUT_SCHEMA_VERSION,
        operation: "trace_list".to_owned(),
        profile: "trace_audit",
        ok: true,
        status: "ok".to_owned(),
        summary: "x".repeat(PROVIDER_OUTPUT_MAX_BYTES),
        evidence: ProviderEvidence {
            facts: Vec::new(),
            resources: Vec::new(),
            collections: vec![ProviderCollection {
                field: "records".to_owned(),
                total: items.len(),
                returned: items.len(),
                truncated: false,
                items,
            }],
        },
        next_actions: Vec::new(),
        truncation: ProviderTruncation {
            max_bytes: PROVIDER_OUTPUT_MAX_BYTES,
            ..ProviderTruncation::default()
        },
        error: None,
    };

    fit_output_budget(&mut output, &[], &["records"])
        .expect("required collection has a reducible bounded representation");

    let records = &output.evidence.collections[0];
    assert_eq!(records.field, "records");
    assert_eq!(records.returned, 1);
    assert_eq!(records.items[0].facts[0].value, "trace-record-0");
    assert!(records.truncated);
    assert_eq!(output.truncation.omitted_items, 11);
}

#[test]
fn collection_normalization_prioritizes_core_navigation_facts() {
    let mut record = serde_json::Map::new();
    for index in 0..40 {
        record.insert(format!("auditField{index:02}"), json!(index));
    }
    record.insert("traceRecordId".to_owned(), json!("trace-record-1"));
    record.insert("traceId".to_owned(), json!("trace-1"));
    record.insert("invocationId".to_owned(), json!("invocation-1"));
    record.insert("operation".to_owned(), json!("trace_list"));
    record.insert("status".to_owned(), json!("ok"));

    let (evidence, truncation) = normalize_evidence(Some(json!({
        "records": [Value::Object(record)]
    })));
    let facts = &evidence.collections[0].items[0].facts;

    for field in [
        "traceRecordId",
        "traceId",
        "invocationId",
        "operation",
        "status",
    ] {
        assert!(
            facts.iter().any(|fact| fact.field == field),
            "missing {field}"
        );
    }
    assert_eq!(facts.len(), 32);
    assert!(truncation.truncated);
    assert_eq!(truncation.omitted_facts, 13);
}

#[test]
fn schema_rejects_wrong_operation_and_extra_fields() {
    let result = result("ok", false, successful_details("git_status"));
    let rendered = render_provider_output("git_status", &result).expect("provider output");
    let mut value: Value = serde_json::from_str(&rendered).expect("valid JSON");
    value["operation"] = json!("git_diff");
    assert!(
        validate_provider_output("git_status", contract(OperationId::GitStatus), &value).is_err()
    );
    value["operation"] = json!("git_status");
    value["unexpected"] = json!(true);
    assert!(
        validate_provider_output("git_status", contract(OperationId::GitStatus), &value).is_err()
    );
}

#[test]
fn unsupported_operation_errors_keep_safe_recovery_evidence() {
    let result = result(
        "unsupported operation",
        true,
        json!({
            "failure": {
                "code": "INVALID_PARAMS",
                "category": "invalid_request",
                "message": "Unsupported operation. Use catalog_search.",
                "recoverable": true,
                "suggestion": "Call catalog_search with the intended user goal."
            }
        }),
    );
    let rendered =
        render_provider_output("guessed_operation", &result).expect("common failure envelope");
    let value: Value = serde_json::from_str(&rendered).expect("valid JSON");
    assert_eq!(value["operation"], "guessed_operation");
    assert_eq!(value["profile"], "summary");
    assert_eq!(value["error"]["recoverable"], true);
    assert!(rendered.contains("catalog_search"));
    assert_eq!(value["nextActions"][0]["operation"], "catalog_search");
    assert_eq!(
        value["nextActions"][0]["arguments"],
        json!({"operation": "catalog_search", "text": "guessed_operation"})
    );
    validate_provider_output("guessed_operation", unsupported_contract(), &value)
        .expect("valid common failure envelope");
}

#[test]
fn every_operation_renders_a_valid_failure_envelope() {
    for operation in OperationId::ALL_NAMES {
        let result = result(
            "request failed",
            true,
            json!({
                "primitiveOperation": operation,
                "failure": {
                    "code": "INVALID_PARAMS",
                    "category": "invalid_request",
                    "message": "Inspect the exact operation contract and retry.",
                    "recoverable": true
                }
            }),
        );
        let rendered = render_provider_output(operation, &result)
            .unwrap_or_else(|error| panic!("{operation}: {error}"));
        assert!(rendered.len() <= PROVIDER_OUTPUT_MAX_BYTES, "{operation}");
        let value: Value =
            serde_json::from_str(&rendered).unwrap_or_else(|error| panic!("{operation}: {error}"));
        let operation_id = OperationId::parse(operation).expect("registered operation");
        validate_provider_output(operation, contract(operation_id), &value)
            .unwrap_or_else(|error| panic!("{operation}: {error}"));
        assert_eq!(
            value["truncation"]["serializedBytes"],
            rendered.len(),
            "{operation}"
        );
    }
}

#[test]
fn every_output_profile_renders_required_success_semantics() {
    for operation in [
        "observe",
        "catalog_search",
        "filesystem_read",
        "git_status",
        "job_status",
        "trace_list",
        "context_control_status",
        "goal_list",
        "capability_binding_cockpit_overview",
        "web_robots_check",
    ] {
        let rendered = render_provider_output(
            operation,
            &result("completed", false, successful_details(operation)),
        )
        .unwrap_or_else(|error| panic!("{operation}: {error}"));
        let value: Value = serde_json::from_str(&rendered).expect("valid JSON");
        assert_eq!(value["ok"], true, "{operation}");
        assert_eq!(value["operation"], operation, "{operation}");
    }
}
