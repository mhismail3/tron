use super::support::*;

#[test]
fn stale_revision_needed_for_mutating_or_risky_functions() {
    let mut read = test_function("alpha::read");
    assert!(!requires_fresh_revision(&read));
    read.effect_class = EffectClass::IdempotentWrite;
    assert!(requires_fresh_revision(&read));
    read.effect_class = EffectClass::PureRead;
    read.risk_level = RiskLevel::Medium;
    assert!(requires_fresh_revision(&read));
}

#[test]
fn child_idempotency_derives_from_parent_capability_invocation_key() {
    let function = test_function("filesystem::read_file");
    let causal = CausalContext::new(
        crate::engine::ActorId::new("agent:s1").expect("actor id"),
        ActorKind::Agent,
        AuthorityGrantId::new("agent-capability-runtime").expect("grant id"),
        crate::engine::TraceId::new("trace").expect("trace id"),
    )
    .with_idempotency_key("parent-key");
    let invocation = Invocation::new_sync(
        FunctionId::new("capability::execute").expect("function id"),
        json!({"payload": {"path": "a"}}),
        causal,
    );
    let key = child_idempotency_key(&invocation, &function, &json!({"path": "a"}), true)
        .expect("key")
        .expect("derived key");
    assert!(key.starts_with("capability-execute:v2:"));
    assert_eq!("capability-execute:v2:".len() + 32, key.len());
}

#[test]
fn process_run_date_does_not_require_approval_but_destructive_command_does() {
    let process_spec = crate::domains::process::contract::capabilities()
        .expect("process specs")
        .into_iter()
        .find(|spec| spec.function_id.as_str() == "process::run")
        .expect("process::run spec");
    let function = crate::domains::contract::function_definition_for_capability(&process_spec);
    assert!(!execution_requires_approval(
        &function,
        &json!({ "command": "date +%Y-%m-%d", "executionMode": "read_only" })
    ));
    assert!(!child_idempotency_required(
        &function,
        &json!({ "command": "date +%Y-%m-%d", "executionMode": "read_only" })
    ));
    assert!(
        validate_target_policy_before_approval(
            &function,
            &json!({
                "command": "echo hi > should_not_exist.txt",
                "executionMode": "read_only"
            })
        )
        .is_err()
    );
    assert!(execution_requires_approval(
        &function,
        &json!({
            "command": "echo hi > result.txt",
            "executionMode": "sandbox_materialized",
            "expectedOutputs": [{"path": "result.txt"}]
        })
    ));
    assert!(child_idempotency_required(
        &function,
        &json!({
            "command": "echo hi > result.txt",
            "executionMode": "sandbox_materialized",
            "expectedOutputs": [{"path": "result.txt"}]
        })
    ));
}

#[test]
fn process_run_sandbox_requires_declared_outputs_before_approval() {
    let process_spec = crate::domains::process::contract::capabilities()
        .expect("process specs")
        .into_iter()
        .find(|spec| spec.function_id.as_str() == "process::run")
        .expect("process::run spec");
    let function = crate::domains::contract::function_definition_for_capability(&process_spec);
    let error = validate_target_policy_before_approval(
        &function,
        &json!({
            "command": "printf hi > out.txt",
            "executionMode": "sandbox_materialized"
        }),
    )
    .expect_err("missing expected outputs rejected before approval");

    assert!(error.to_string().contains("expectedOutputs"));
    assert!(error.to_string().contains("\"path\""));
}

#[test]
fn process_run_sandbox_rejects_absolute_output_paths_before_approval() {
    let process_spec = crate::domains::process::contract::capabilities()
        .expect("process specs")
        .into_iter()
        .find(|spec| spec.function_id.as_str() == "process::run")
        .expect("process::run spec");
    let function = crate::domains::contract::function_definition_for_capability(&process_spec);
    let error = validate_target_policy_before_approval(
        &function,
        &json!({
            "command": "printf hi > /tmp/out.txt",
            "executionMode": "sandbox_materialized",
            "expectedOutputs": [{"path": "/tmp/out.txt"}]
        }),
    )
    .expect_err("absolute expected output path rejected before approval");

    assert!(
        error
            .to_string()
            .contains("relative path inside the process sandbox")
    );
    assert_eq!(policy_preflight_status(&error), "needs_input");
    let details = error.details().expect("repairable details");
    assert_eq!(details["validationKind"], json!("repairable_argument"));
    assert_eq!(
        details["invalidArgumentPaths"],
        json!(["arguments.expectedOutputs[].path"])
    );
}

#[test]
fn process_run_sandbox_output_path_shape_is_repairable_preflight() {
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
        "command": "printf hi > /tmp/out.txt",
        "executionMode": "sandbox_materialized",
        "expectedOutputs": [{"path": "/tmp/out.txt"}]
    });
    let error =
        validate_target_policy_before_approval(&function, &payload).expect_err("policy error");
    let status = policy_preflight_status(&error);
    assert_eq!(status, "needs_input");

    let value =
        preflight_rejection_result(&function, &target, error, status).expect("structured result");
    let result: CapabilityResult = serde_json::from_value(value).expect("capability result");
    assert_eq!(result.is_error, None);
    let details = result.details.expect("details");
    assert_eq!(details["status"], json!("needs_input"));
    assert_eq!(
        details["error"]["details"]["validationKind"],
        json!("repairable_argument")
    );
    assert_eq!(details["guidance"]["kind"], json!("correct_arguments"));
    assert_eq!(
        details["invalidArgumentPaths"],
        json!(["arguments.expectedOutputs[].path"])
    );
    assert_eq!(details["childInvocationCreated"], json!(false));
    assert_eq!(details["approvalCreated"], json!(false));
}

#[test]
fn execute_validates_target_payload_before_requesting_approval() {
    let mut function = test_function("process::run");
    function.request_schema = Some(json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["command"],
        "properties": {
            "command": {"type": "string"}
        }
    }));

    let entry = CapabilityRegistryEntry::from_function(function, 1);
    let error = validate_target_payload(&entry, &json!({})).expect_err("schema error");

    match error {
        CapabilityError::InvalidParams { message } => {
            assert!(message.contains("required field is missing"));
            assert!(message.contains("Required arguments"));
            assert!(message.contains("command"));
        }
        CapabilityError::Custom { message, .. } => {
            assert!(message.contains("required field is missing"));
            assert!(message.contains("Required arguments"));
            assert!(message.contains("command"));
        }
        other => panic!("unexpected error: {other:?}"),
    }
}

#[test]
fn process_run_date_does_not_require_fresh_inspection_handle() {
    let mut function = test_function("process::run");
    function.effect_class = EffectClass::ExternalSideEffect;
    function.risk_level = RiskLevel::High;

    assert!(!requires_fresh_revision_for_payload(
        &function,
        &json!({"payload": {"command": "date", "executionMode": "read_only"}})
    ));
    assert!(!requires_fresh_revision_for_payload(
        &function,
        &json!({"payload": {"command": "git status --short", "executionMode": "read_only"}})
    ));
    assert!(!requires_fresh_revision_for_payload(
        &function,
        &json!({"payload": {"command": "cd /tmp && git status --short && git log --oneline -3", "executionMode": "read_only"}})
    ));
    assert!(!requires_fresh_revision_for_payload(
        &function,
        &json!({"payload": {"command": "echo hello > should_not_exist.txt", "executionMode": "read_only"}})
    ));
}

#[test]
fn process_run_risky_commands_still_require_fresh_inspection_handle() {
    let mut function = test_function("process::run");
    function.effect_class = EffectClass::ExternalSideEffect;
    function.risk_level = RiskLevel::High;

    assert!(requires_fresh_revision_for_payload(
        &function,
        &json!({"payload": {"command": "rm -rf target", "executionMode": "sandbox_materialized", "expectedOutputs": [{"path": "result.txt"}]}})
    ));
    assert!(requires_fresh_revision_for_payload(
        &function,
        &json!({"payload": {"command": "echo hello > file.txt", "executionMode": "sandbox_materialized", "expectedOutputs": [{"path": "file.txt"}]}})
    ));
}

#[test]
fn notifications_send_runs_direct_with_idempotency_without_fresh_inspection() {
    let mut function = test_function("notifications::send");
    function.effect_class = EffectClass::ExternalSideEffect;
    function.risk_level = RiskLevel::Low;

    assert!(!requires_fresh_revision_for_payload(
        &function,
        &json!({
            "contractId": "notifications::send",
            "idempotencyKey": "notify-test",
            "payload": {"title": "Tron test", "body": "hello"}
        })
    ));
}

#[test]
fn capability_execute_child_invocations_preserve_runtime_metadata() {
    let function = test_function("filesystem::read_file")
        .with_required_authority(AuthorityRequirement::scope("filesystem.read"));
    let parent = Invocation::new_sync(
        FunctionId::new("capability::execute").expect("function id"),
        json!({
            "contractId": "filesystem::read_file",
            "mode": "invoke",
            "payload": {"path": "README.md"}
        }),
        CausalContext::new(
            crate::engine::ActorId::new("agent:s1").expect("actor id"),
            ActorKind::Agent,
            AuthorityGrantId::new("agent-capability-runtime").expect("grant id"),
            crate::engine::TraceId::new("trace").expect("trace id"),
        )
        .with_session_id("sess-1")
        .with_workspace_id("workspace-1")
        .with_scope("capability.execute")
        .with_runtime_metadata(
            crate::engine::invocation::RUNTIME_METADATA_WORKING_DIRECTORY,
            "/tmp/session-worktree",
        ),
    );

    let child = child_execute_causal_context(&parent, &function, Some("child-key".to_owned()));

    assert_eq!(
        child.runtime_metadata(crate::engine::invocation::RUNTIME_METADATA_WORKING_DIRECTORY),
        Some("/tmp/session-worktree")
    );
    assert_eq!(child.session_id.as_deref(), Some("sess-1"));
    assert_eq!(child.workspace_id.as_deref(), Some("workspace-1"));
    assert!(child.has_scope("capability.execute"));
    assert!(child.has_scope("filesystem.read"));
    assert_eq!(child.idempotency_key.as_deref(), Some("child-key"));
}
