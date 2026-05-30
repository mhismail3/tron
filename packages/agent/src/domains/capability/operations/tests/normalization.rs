use super::support::*;

#[test]
fn orchestrated_execute_normalizes_common_shape_mistakes() {
    let input = parse_orchestrated_execute_input(&json!({
        "intent": "write a sandboxed output file",
        "payload": {
            "contractId": "process::run",
            "command": "printf hi > out.txt",
            "executionMode": "sandbox_materialized",
            "expectedOutputs": [
                {"path": "out.txt", "kind": "materialized_file", "role": "updated", "type": "file"}
            ],
            "idempotencyKey": "write-out",
            "reason": "Create a declared output"
        }
    }))
    .expect("normalized input");
    assert_eq!(
        input.target_params,
        Some(json!({"contractId": "process::run"}))
    );
    assert_eq!(input.idempotency_key.as_deref(), Some("write-out"));
    assert_eq!(input.reason.as_deref(), Some("Create a declared output"));
    assert_eq!(input.arguments["command"], json!("printf hi > out.txt"));
    let kinds = input
        .corrections
        .iter()
        .filter_map(|correction| correction["kind"].as_str())
        .collect::<Vec<_>>();
    assert!(kinds.contains(&"payload_to_arguments"));
    assert!(kinds.contains(&"nested_target_to_target"));
    assert!(kinds.contains(&"nested_idempotency_key_to_wrapper"));
    assert!(kinds.contains(&"nested_reason_to_wrapper"));

    let process_spec = crate::domains::process::contract::capabilities()
        .expect("process specs")
        .into_iter()
        .find(|spec| spec.function_id.as_str() == "process::run")
        .expect("process::run spec");
    let function = crate::domains::contract::function_definition_for_capability(&process_spec);
    let mut arguments = input.arguments;
    let mut corrections = input.corrections;
    normalize_target_specific_arguments(&function, &mut arguments, &mut corrections);
    assert!(arguments["expectedOutputs"][0].get("kind").is_none());
    assert!(arguments["expectedOutputs"][0].get("role").is_none());
    assert!(arguments["expectedOutputs"][0].get("type").is_none());
    assert!(
        corrections
            .iter()
            .any(|correction| correction["kind"] == json!("process_expected_outputs_shape"))
    );
}

#[test]
fn orchestrated_execute_normalizes_flattened_target_arguments() {
    let input = parse_orchestrated_execute_input(&json!({
        "path": "packages/agent/src",
        "pattern": "FunctionDefinition",
        "context": 2,
        "maxResults": 20,
        "reason": "Search source for function definitions."
    }))
    .expect("flattened target arguments are accepted");

    assert!(input.target_params.is_none());
    assert_eq!(input.arguments["path"], json!("packages/agent/src"));
    assert_eq!(input.arguments["pattern"], json!("FunctionDefinition"));
    assert_eq!(input.arguments["context"], json!(2));
    assert_eq!(input.arguments["maxResults"], json!(20));
    assert_eq!(
        input.reason.as_deref(),
        Some("Search source for function definitions.")
    );
    assert!(
        input
            .corrections
            .iter()
            .any(|correction| { correction["kind"] == json!("top_level_arguments_to_arguments") })
    );
}

#[test]
fn orchestrated_execute_dedupes_identical_flattened_argument_duplicates() {
    let input = parse_orchestrated_execute_input(&json!({
        "arguments": {
            "path": "packages/agent/src/engine/host.rs",
            "startLine": 2060,
            "endLine": 2300
        },
        "target": "filesystem::read_file",
        "path": "packages/agent/src/engine/host.rs",
        "startLine": 2060,
        "endLine": 2300
    }))
    .expect("identical duplicate flattened arguments should be deduped");

    assert_eq!(
        input.arguments["path"],
        json!("packages/agent/src/engine/host.rs")
    );
    assert_eq!(input.arguments["startLine"], json!(2060));
    assert_eq!(input.arguments["endLine"], json!(2300));
    assert!(input.corrections.iter().any(|correction| {
        correction["kind"] == json!("duplicate_flattened_arguments_deduped")
    }));
}

#[test]
fn orchestrated_execute_rejects_conflicting_flattened_argument_duplicates() {
    let error = parse_orchestrated_execute_input(&json!({
        "arguments": {"path": "README.md"},
        "path": "packages/agent/src"
    }))
    .expect_err("conflicting flattened arguments should be explicit");

    assert!(
        error
            .to_string()
            .contains("conflicting values for target argument 'path'")
    );
}

#[test]
fn orchestrated_execute_forwards_wrapper_idempotency_when_target_schema_requires_it() {
    let mut function = test_function("ui::submit_action");
    function.request_schema = Some(json!({
        "type": "object",
        "required": [
            "surfaceResourceId",
            "surfaceVersionId",
            "actionId",
            "userInput",
            "idempotencyKey"
        ],
        "additionalProperties": false,
        "properties": {
            "surfaceResourceId": {"type": "string"},
            "surfaceVersionId": {"type": "string"},
            "actionId": {"type": "string"},
            "userInput": {"type": "object"},
            "idempotencyKey": {"type": "string"}
        }
    }));
    let mut input = parse_orchestrated_execute_input(&json!({
        "target": "ui::submit_action",
        "arguments": {
            "surfaceResourceId": "ui-surface-resource_collection-artifact-prompt-snippet",
            "surfaceVersionId": "ver_test",
            "actionId": "create-snippet",
            "userInput": {"name": "Gateway", "text": "Created through stored UI action"}
        },
        "idempotencyKey": "ui-action-submit-key"
    }))
    .expect("input");

    normalize_target_idempotency_argument(
        &function,
        &mut input.arguments,
        input.idempotency_key.as_deref(),
        &mut input.corrections,
    );

    assert_eq!(
        input.arguments["idempotencyKey"],
        json!("ui-action-submit-key")
    );
    assert!(input.corrections.iter().any(|correction| {
        correction["kind"] == json!("wrapper_idempotency_key_to_target_argument")
    }));
    let prepared = prepared_execute_payload(input.target_params.as_ref().unwrap(), &input);
    assert_eq!(prepared["idempotencyKey"], json!("ui-action-submit-key"));
    assert_eq!(
        prepared["payload"]["idempotencyKey"],
        json!("ui-action-submit-key")
    );
}

#[test]
fn orchestrated_execute_normalizes_schema_property_name_aliases_before_schema_validation() {
    let mut function = test_function("queue::enqueue");
    function.request_schema = Some(json!({
        "type": "object",
        "required": ["functionId", "payload", "queue"],
        "additionalProperties": false,
        "properties": {
            "functionId": {"type": "string"},
            "payload": {"type": "object"},
            "queue": {"type": "string"},
            "targetRevision": {"type": "integer"}
        }
    }));
    let entry = CapabilityRegistryEntry::from_function(function.clone(), 81);
    let mut arguments = json!({
        "functionid": "state::get",
        "payload": {"namespace": "rwo-006", "key": "probe", "scope": "session"},
        "queue": "rwo-006"
    });
    let mut corrections = Vec::new();

    normalize_target_arguments(&function, &mut arguments, &mut corrections);

    assert_eq!(arguments["functionId"], json!("state::get"));
    assert!(arguments.get("functionid").is_none());
    assert!(corrections.iter().any(|correction| {
        correction["kind"] == json!("schema_property_name_alias")
            && correction["message"]
                .as_str()
                .is_some_and(|message| message.contains("functionid->functionId"))
    }));
    validate_target_payload(&entry, &arguments)
        .expect("schema property alias should validate after normalization");
}

#[test]
fn orchestrated_execute_does_not_hide_conflicting_schema_property_aliases() {
    let mut function = test_function("queue::enqueue");
    function.request_schema = Some(json!({
        "type": "object",
        "required": ["functionId", "payload", "queue"],
        "additionalProperties": false,
        "properties": {
            "functionId": {"type": "string"},
            "payload": {"type": "object"},
            "queue": {"type": "string"}
        }
    }));
    let entry = CapabilityRegistryEntry::from_function(function.clone(), 82);
    let mut arguments = json!({
        "functionId": "state::get",
        "functionid": "state::set",
        "payload": {"namespace": "rwo-006", "key": "probe", "scope": "session"},
        "queue": "rwo-006"
    });
    let mut corrections = Vec::new();

    normalize_target_arguments(&function, &mut arguments, &mut corrections);

    assert_eq!(arguments["functionId"], json!("state::get"));
    assert_eq!(arguments["functionid"], json!("state::set"));
    assert!(
        corrections
            .iter()
            .all(|correction| { correction["kind"] != json!("schema_property_name_alias") })
    );
    validate_target_payload(&entry, &arguments)
        .expect_err("conflicting alias should remain visible to schema validation");
}

#[test]
fn orchestrated_execute_normalizes_process_output_aliases_before_schema_validation() {
    let process_spec = crate::domains::process::contract::capabilities()
        .expect("process specs")
        .into_iter()
        .find(|spec| spec.function_id.as_str() == "process::run")
        .expect("process::run spec");
    let function = crate::domains::contract::function_definition_for_capability(&process_spec);
    let entry = CapabilityRegistryEntry::from_function(function.clone(), 77);
    let mut arguments = json!({
        "command": "printf hi > out.txt",
        "executionMode": "sandbox_materialized",
        "expectedOutputPaths": ["out.txt"]
    });
    let mut corrections = Vec::new();

    normalize_target_specific_arguments(&function, &mut arguments, &mut corrections);

    assert_eq!(arguments["expectedOutputs"], json!([{ "path": "out.txt" }]));
    assert!(arguments.get("expectedOutputPaths").is_none());
    assert!(
        corrections
            .iter()
            .any(|correction| { correction["kind"] == json!("process_expected_outputs_alias") })
    );
    validate_target_payload(&entry, &arguments).expect("normalized payload schema-valid");
}

#[test]
fn orchestrated_execute_normalizes_list_dir_max_entries_alias_before_schema_validation() {
    let list_dir_spec = crate::domains::filesystem::contract::capabilities()
        .expect("filesystem specs")
        .into_iter()
        .find(|spec| spec.function_id.as_str() == "filesystem::list_dir")
        .expect("filesystem::list_dir spec");
    let function = crate::domains::contract::function_definition_for_capability(&list_dir_spec);
    let entry = CapabilityRegistryEntry::from_function(function.clone(), 79);
    let mut arguments = json!({
        "path": ".",
        "maxEntries": 20
    });
    let mut corrections = Vec::new();

    normalize_target_specific_arguments(&function, &mut arguments, &mut corrections);

    assert_eq!(arguments["maxResults"], json!(20));
    assert!(arguments.get("maxEntries").is_none());
    assert!(corrections.iter().any(|correction| {
        correction["kind"] == json!("filesystem_list_dir_max_entries_alias")
    }));
    validate_target_payload(&entry, &arguments).expect("normalized list_dir payload schema-valid");
}

#[test]
fn orchestrated_execute_normalizes_web_search_result_limit_aliases_before_schema_validation() {
    let web_search_spec = crate::domains::web::contract::capabilities()
        .expect("web specs")
        .into_iter()
        .find(|spec| spec.function_id.as_str() == "web::search")
        .expect("web::search spec");
    let function = crate::domains::contract::function_definition_for_capability(&web_search_spec);
    let entry = CapabilityRegistryEntry::from_function(function.clone(), 80);
    let mut arguments = json!({
        "query": "official OpenAI model docs",
        "maxResults": 5
    });
    let mut corrections = Vec::new();

    normalize_target_specific_arguments(&function, &mut arguments, &mut corrections);

    assert_eq!(arguments["count"], json!(5));
    assert!(arguments.get("maxResults").is_none());
    assert!(
        corrections
            .iter()
            .any(|correction| { correction["kind"] == json!("web_search_count_alias") })
    );
    validate_target_payload(&entry, &arguments)
        .expect("normalized web::search payload schema-valid");
}

#[test]
fn orchestrated_execute_normalizes_apply_patch_append_intent() {
    let apply_patch_spec = crate::domains::filesystem::contract::capabilities()
        .expect("filesystem specs")
        .into_iter()
        .find(|spec| spec.function_id.as_str() == "filesystem::apply_patch")
        .expect("filesystem::apply_patch spec");
    let function = crate::domains::contract::function_definition_for_capability(&apply_patch_spec);
    let entry = CapabilityRegistryEntry::from_function(function.clone(), 78);
    let mut arguments = json!({
        "path": "README.md",
        "newString": "Execute append smoke\n"
    });
    let mut corrections = Vec::new();

    normalize_target_specific_arguments(&function, &mut arguments, &mut corrections);

    assert_eq!(arguments["oldString"], json!(""));
    assert!(
        corrections.iter().any(|correction| {
            correction["kind"] == json!("filesystem_apply_patch_append_shape")
        })
    );
    validate_target_payload(&entry, &arguments).expect("normalized append payload schema-valid");
}

#[test]
fn orchestrated_execute_prepared_payload_preserves_target_arguments_only() {
    let input = parse_orchestrated_execute_input(&json!({
        "intent": "read the readme",
        "target": "filesystem::read_file",
        "arguments": {"path": "README.md"},
        "reason": "Read the project README"
    }))
    .expect("input");
    let prepared = prepared_execute_payload(input.target_params.as_ref().unwrap(), &input);

    assert_eq!(prepared["mode"], json!("invoke"));
    assert_eq!(prepared["capabilityId"], json!("filesystem::read_file"));
    assert_eq!(prepared["payload"], json!({"path": "README.md"}));
    assert_eq!(prepared["reason"], json!("Read the project README"));
    assert!(prepared.get("arguments").is_none());
    assert!(prepared.get("target").is_none());
}

#[test]
fn lifecycle_version_id_mistake_returns_cas_field_guidance_without_aliasing() {
    let host = crate::engine::EngineHost::new().expect("engine host");
    let function = host
        .catalog()
        .function(&FunctionId::new("materialized_file::discard").expect("function id"))
        .expect("materialized_file::discard")
        .clone();
    let entry = CapabilityRegistryEntry::from_function(function.clone(), 77);
    let target = ResolvedCapabilityTarget {
        binding_decision: decision_for_entry(&entry, "test", Vec::new()),
        entry: entry.clone(),
    };
    let error = validate_target_payload(
        &entry,
        &json!({
            "resourceId": "materialized_file:rwo-n11-agent-discarded",
            "versionId": "ver_demo"
        }),
    )
    .expect_err("payload error");
    assert_eq!(payload_preflight_status(&error), "target_payload_invalid");

    let value = preflight_rejection_result(&function, &target, error, "target_payload_invalid")
        .expect("structured result");
    let result: CapabilityResult = serde_json::from_value(value).expect("capability result");
    let CapabilityResultBody::Blocks(blocks) = result.content else {
        panic!("expected block content");
    };
    let CapabilityResultContent::Text { text } = &blocks[0] else {
        panic!("expected text content");
    };
    assert!(text.contains("materialized_file::discard rejected before child execution"));
    assert!(text.contains("expectedCurrentVersionId"));
    assert!(text.contains("not versionId"), "{text}");
    assert!(text.contains(r#""expectedCurrentVersionId":"<currentVersionId>""#));

    let details = result.details.expect("details");
    assert_eq!(details["status"], json!("target_payload_invalid"));
    assert_eq!(details["childInvocationCreated"], json!(false));
}
