use super::support::*;

#[test]
fn execute_preflight_policy_rejection_is_structured_capability_result() {
    let process_spec = crate::domains::process::contract::capabilities()
        .expect("process specs")
        .into_iter()
        .find(|spec| spec.function_id.as_str() == "process::run")
        .expect("process::run spec");
    let function = crate::domains::contract::function_definition_for_capability(&process_spec);
    let entry = CapabilityRegistryEntry::from_function(function.clone(), 77);
    let target = ResolvedCapabilityTarget {
        binding_decision: decision_for_entry(&entry, "test", Vec::new()),
        entry,
    };
    let payload = json!({
        "command": "echo hi > should_not_exist.txt",
        "executionMode": "read_only"
    });
    let error =
        validate_target_policy_before_approval(&function, &payload).expect_err("policy error");

    let value = preflight_rejection_result(&function, &target, error, "target_policy_rejected")
        .expect("structured result");
    let result: CapabilityResult = serde_json::from_value(value).expect("capability result");
    let CapabilityResultBody::Blocks(blocks) = result.content else {
        panic!("expected block content");
    };

    assert_eq!(result.is_error, Some(true));
    assert_eq!(result.stop_turn, None);
    let CapabilityResultContent::Text { text } = &blocks[0] else {
        panic!("expected text content");
    };
    assert!(text.contains("process::run rejected before child execution"));
    let details = result.details.expect("details");
    assert_eq!(details["status"], json!("target_policy_rejected"));
    assert_eq!(details["error"]["code"], json!("INVALID_PARAMS"));
    assert_eq!(details["functionId"], json!("process::run"));
    assert_eq!(details["childInvocationCreated"], json!(false));
    assert_eq!(details["approvalCreated"], json!(false));
    assert_eq!(details["resourceRefs"], json!([]));
}

#[test]
fn execute_missing_required_argument_is_needs_input_result() {
    let mut function = test_function("process::run");
    function.request_schema = Some(json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["command"],
        "properties": {
            "command": {"type": "string"}
        }
    }));
    let entry = CapabilityRegistryEntry::from_function(function.clone(), 77);
    let target = ResolvedCapabilityTarget {
        binding_decision: decision_for_entry(&entry, "test", Vec::new()),
        entry: entry.clone(),
    };
    let error = validate_target_payload(&entry, &json!({})).expect_err("payload error");
    assert_eq!(payload_preflight_status(&error), "needs_input");

    let value = preflight_rejection_result(&function, &target, error, "needs_input")
        .expect("structured result");
    let result: CapabilityResult = serde_json::from_value(value).expect("capability result");
    let CapabilityResultBody::Blocks(blocks) = result.content else {
        panic!("expected block content");
    };
    let CapabilityResultContent::Text { text } = &blocks[0] else {
        panic!("expected text content");
    };
    assert!(text.contains("process::run needs input before child execution"));
    assert!(!text.contains("process::run rejected before child execution"));

    assert_eq!(result.is_error, None);
    let details = result.details.expect("details");
    assert_eq!(details["status"], json!("needs_input"));
    assert_eq!(details["error"]["code"], json!("INVALID_PARAMS"));
    assert_eq!(
        details["error"]["details"]["validationKind"],
        json!("missing_required_argument")
    );
    assert_eq!(
        details["error"]["details"]["missingFields"],
        json!(["command"])
    );
    assert_eq!(details["missingFields"], json!(["command"]));
    assert_eq!(
        details["missingArgumentPaths"],
        json!(["arguments.command"])
    );
    assert_eq!(
        details["guidance"]["missingArgumentPaths"],
        json!(["arguments.command"])
    );
    assert_eq!(details["childInvocationIds"], json!([]));
    assert_eq!(details["childInvocationCreated"], json!(false));
    assert_eq!(details["approvalCreated"], json!(false));
    assert_eq!(details["resourceRefs"], json!([]));
    assert!(
        details["error"]["message"]
            .as_str()
            .expect("message")
            .contains("Required arguments: command")
    );
}

#[test]
fn execute_empty_required_string_is_needs_input_result() {
    let mut function = test_function("process::run");
    function.request_schema = Some(json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["command"],
        "properties": {
            "command": {"type": "string", "minLength": 1}
        }
    }));
    let entry = CapabilityRegistryEntry::from_function(function.clone(), 77);
    let target = ResolvedCapabilityTarget {
        binding_decision: decision_for_entry(&entry, "test", Vec::new()),
        entry: entry.clone(),
    };
    let error =
        validate_target_payload(&entry, &json!({"command": ""})).expect_err("payload error");
    assert_eq!(payload_preflight_status(&error), "needs_input");

    let value = preflight_rejection_result(&function, &target, error, "needs_input")
        .expect("structured result");
    let result: CapabilityResult = serde_json::from_value(value).expect("capability result");
    let details = result.details.expect("details");

    assert_eq!(details["status"], json!("needs_input"));
    assert_eq!(
        details["error"]["details"]["validationKind"],
        json!("missing_required_argument")
    );
    assert_eq!(
        details["missingArgumentPaths"],
        json!(["arguments.command"])
    );
    assert_eq!(details["childInvocationCreated"], json!(false));
    assert_eq!(details["resourceRefs"], json!([]));
}

#[test]
fn execute_null_required_field_is_needs_input_result() {
    let mut function = test_function("process::run");
    function.request_schema = Some(json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["command"],
        "properties": {
            "command": {"type": "string", "minLength": 1}
        }
    }));
    let entry = CapabilityRegistryEntry::from_function(function.clone(), 77);
    let target = ResolvedCapabilityTarget {
        binding_decision: decision_for_entry(&entry, "test", Vec::new()),
        entry: entry.clone(),
    };
    let error =
        validate_target_payload(&entry, &json!({"command": null})).expect_err("payload error");
    assert_eq!(payload_preflight_status(&error), "needs_input");

    let value = preflight_rejection_result(&function, &target, error, "needs_input")
        .expect("structured result");
    let result: CapabilityResult = serde_json::from_value(value).expect("capability result");
    let details = result.details.expect("details");

    assert_eq!(details["status"], json!("needs_input"));
    assert_eq!(
        details["error"]["details"]["validationKind"],
        json!("missing_required_argument")
    );
    assert_eq!(details["missingFields"], json!(["command"]));
    assert_eq!(
        details["missingArgumentPaths"],
        json!(["arguments.command"])
    );
    assert_eq!(details["childInvocationCreated"], json!(false));
}

#[test]
fn execute_missing_required_arguments_reports_complete_same_scope_set() {
    let mut function = test_function("process::run");
    function.request_schema = Some(json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["command", "executionMode"],
        "properties": {
            "command": {"type": "string"},
            "executionMode": {"type": "string", "enum": ["read_only", "sandbox_materialized"]},
            "expectedOutputs": {
                "type": "array",
                "items": {
                    "type": "object",
                    "required": ["path", "targetPath"],
                    "properties": {
                        "path": {"type": "string"},
                        "targetPath": {"type": "string"}
                    }
                }
            }
        }
    }));
    let entry = CapabilityRegistryEntry::from_function(function.clone(), 77);
    let target = ResolvedCapabilityTarget {
        binding_decision: decision_for_entry(&entry, "test", Vec::new()),
        entry: entry.clone(),
    };
    let error = validate_target_payload(&entry, &json!({})).expect_err("payload error");

    let value = preflight_rejection_result(&function, &target, error, "needs_input")
        .expect("structured result");
    let details = value["details"].clone();
    assert_eq!(
        details["error"]["details"]["missingFields"],
        json!(["command", "executionMode"])
    );
    assert_eq!(
        details["missingFields"],
        json!(["command", "executionMode"])
    );
    assert_eq!(
        details["missingArgumentPaths"],
        json!(["arguments.command", "arguments.executionMode"])
    );
    assert_eq!(
        details["guidance"]["missingArgumentPaths"],
        json!(["arguments.command", "arguments.executionMode"])
    );

    let nested_error = validate_target_payload(
        &entry,
        &json!({
            "command": "echo hi",
            "executionMode": "sandbox_materialized",
            "expectedOutputs": [{}]
        }),
    )
    .expect_err("nested payload error");
    let nested_value = preflight_rejection_result(&function, &target, nested_error, "needs_input")
        .expect("structured result");
    let nested_details = nested_value["details"].clone();
    assert_eq!(
        nested_details["error"]["details"]["missingFields"],
        json!(["path", "targetPath"])
    );
    assert_eq!(
        nested_details["missingFields"],
        json!(["path", "targetPath"])
    );
    assert_eq!(
        nested_details["missingArgumentPaths"],
        json!([
            "arguments.expectedOutputs[0].path",
            "arguments.expectedOutputs[0].targetPath"
        ])
    );
    assert_eq!(
        nested_details["guidance"]["missingArgumentPaths"],
        json!([
            "arguments.expectedOutputs[0].path",
            "arguments.expectedOutputs[0].targetPath"
        ])
    );
}

#[test]
fn execute_invalid_target_payload_remains_target_payload_invalid() {
    let mut function = test_function("process::run");
    function.request_schema = Some(json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["command"],
        "properties": {
            "command": {"type": "string"}
        }
    }));
    let entry = CapabilityRegistryEntry::from_function(function.clone(), 77);
    let target = ResolvedCapabilityTarget {
        binding_decision: decision_for_entry(&entry, "test", Vec::new()),
        entry: entry.clone(),
    };
    let error = validate_target_payload(
        &entry,
        &json!({
            "command": "echo ok",
            "unexpected": true
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
    assert!(text.contains("process::run rejected before child execution"));
    let details = result.details.expect("details");
    assert_eq!(details["status"], json!("target_payload_invalid"));
    assert_eq!(details["error"]["code"], json!("INVALID_PARAMS"));
    assert_eq!(details["childInvocationCreated"], json!(false));
    assert_eq!(details["approvalCreated"], json!(false));
    assert_eq!(details["resourceRefs"], json!([]));
}

#[test]
fn approved_execute_result_reports_approval_and_child_invocation() {
    let function = test_function("process::run");
    let entry = CapabilityRegistryEntry::from_function(function.clone(), 77);
    let target = ResolvedCapabilityTarget {
        binding_decision: decision_for_entry(&entry, "test", Vec::new()),
        entry,
    };
    let trace_id = TraceId::generate();
    let causal = CausalContext::new(
        ActorId::new("agent:test").expect("actor id"),
        ActorKind::Agent,
        AuthorityGrantId::new("grant:test").expect("grant id"),
        trace_id.clone(),
    )
    .with_idempotency_key("wrapper-key");
    let invocation = Invocation::new_sync(
        FunctionId::new("capability::execute").expect("function id"),
        json!({ "contractId": "process::run" }),
        causal,
    );
    let approval = test_approval_record(
        function.id.clone(),
        invocation.id.clone(),
        trace_id.clone(),
        "approved-child-key",
    );
    let child_invocation_id = InvocationId::generate();
    let records = vec![test_invocation_record(
        child_invocation_id.clone(),
        &function,
        invocation.id.clone(),
        trace_id,
        "approved-child-key",
    )];
    let child_invocations =
        approval_child_invocation_ids_from_records(&records, &approval, &function);

    assert_eq!(
        child_invocations,
        vec![child_invocation_id.as_str().to_owned()]
    );

    let value = approved_execution_result(
        &invocation,
        &function,
        &target,
        &approval,
        json!({ "exitCode": 0, "stdout": "ok\n", "resourceRefs": [] }),
        child_invocations,
    )
    .expect("approved execution result");
    let result: CapabilityResult = serde_json::from_value(value).expect("capability result");
    let details = result.details.expect("details");

    assert_eq!(details["approvalRequired"], json!(true));
    assert_eq!(details["approvalCreated"], json!(true));
    assert_eq!(details["approvalExecuted"], json!(true));
    assert_eq!(details["childInvocationCreated"], json!(true));
    assert_eq!(details["idempotencyKey"], json!("approved-child-key"));
    assert_eq!(
        details["childInvocations"],
        json!([child_invocation_id.as_str()])
    );
    assert_eq!(
        details["approvalState"]["idempotencyKey"],
        json!("approved-child-key")
    );
    assert_eq!(
        details["approvalState"]["childInvocationId"],
        json!(child_invocation_id.as_str())
    );
    assert_eq!(
        details["approvalState"]["childInvocationIds"],
        json!([child_invocation_id.as_str()])
    );
}

#[test]
fn replayed_approval_execute_result_does_not_report_fresh_approval_or_child() {
    let function = test_function("process::run");
    let entry = CapabilityRegistryEntry::from_function(function.clone(), 77);
    let target = ResolvedCapabilityTarget {
        binding_decision: decision_for_entry(&entry, "test", Vec::new()),
        entry,
    };
    let original_trace_id = TraceId::generate();
    let original_parent_invocation_id = InvocationId::generate();
    let approval = test_approval_record(
        function.id.clone(),
        original_parent_invocation_id.clone(),
        original_trace_id.clone(),
        "approved-child-key",
    );
    let replay_trace_id = TraceId::generate();
    let replay_causal = CausalContext::new(
        ActorId::new("agent:test").expect("actor id"),
        ActorKind::Agent,
        AuthorityGrantId::new("grant:test").expect("grant id"),
        replay_trace_id,
    )
    .with_idempotency_key("wrapper-key-replay");
    let replay_invocation = Invocation::new_sync(
        FunctionId::new("capability::execute").expect("function id"),
        json!({ "contractId": "process::run" }),
        replay_causal,
    );
    let child_invocation_id = InvocationId::generate();

    assert!(approval_was_replayed_for_invocation(
        &replay_invocation,
        &approval
    ));

    let value = approved_execution_result(
        &replay_invocation,
        &function,
        &target,
        &approval,
        json!({ "exitCode": 0, "stdout": "ok\n", "resourceRefs": [] }),
        vec![child_invocation_id.as_str().to_owned()],
    )
    .expect("replayed approval execution result");
    let result: CapabilityResult = serde_json::from_value(value).expect("capability result");
    let details = result.details.expect("details");

    assert_eq!(details["approvalRequired"], json!(false));
    assert_eq!(details["approvalCreated"], json!(false));
    assert_eq!(details["approvalExecuted"], json!(false));
    assert_eq!(details["approvalReplayed"], json!(true));
    assert_eq!(details["childInvocationCreated"], json!(false));
    assert_eq!(details["idempotencyKey"], json!("approved-child-key"));
    assert!(details["approvalState"].is_null());
    assert_eq!(
        details["approvalReplay"]["approvalId"],
        json!(approval.approval_id)
    );
    assert_eq!(
        details["approvalReplay"]["idempotencyKey"],
        json!("approved-child-key")
    );
    assert_eq!(
        details["approvalReplay"]["childInvocationIds"],
        json!([child_invocation_id.as_str()])
    );
    assert_eq!(
        details["replayedFromTraceId"],
        json!(original_trace_id.as_str())
    );
}
