use super::support::*;

#[test]
fn observe_phase_promotes_child_resource_refs_and_approval_state() {
    let resource_refs = json!([
        {
            "kind": "materialized_file",
            "resourceId": "materialized_file:test",
            "versionId": "ver_test",
            "role": "updated"
        },
        {
            "kind": "execution_output",
            "resourceId": "res_test",
            "versionId": "ver_output",
            "role": "created"
        }
    ]);
    let result = capability_result_value(CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text("ok".to_owned())]),
        details: Some(json!({
            "status": "ok",
            "output": {
                "stdout": "ok\n",
                "resourceRefs": resource_refs.clone()
            },
            "approvalState": {
                "approvalId": "approval-test",
                "approvalCreated": true,
                "approvalExecuted": true,
                "status": "Executed"
            },
            "childInvocations": ["child-test"]
        })),
        is_error: None,
        stop_turn: None,
    })
    .expect("capability result");

    let mut orchestration = json!({
        "status": "ok",
        "childInvocationIds": ["child-test"]
    });
    enrich_orchestration_with_result(&mut orchestration, &result);
    assert_eq!(orchestration["resourceRefs"], resource_refs);
    assert_eq!(
        orchestration["approvalDecision"]["approvalId"],
        json!("approval-test")
    );

    let attached = attach_orchestration_details(result, orchestration).expect("attached result");
    let attached: CapabilityResult = serde_json::from_value(attached).expect("capability result");
    let details = attached.details.expect("details");
    assert_eq!(details["resourceRefs"], resource_refs);
    assert_eq!(details["orchestration"]["resourceRefs"], resource_refs);
    assert_eq!(
        details["orchestration"]["approvalDecision"]["approvalId"],
        json!("approval-test")
    );
}

#[test]
fn observe_phase_promotes_normalized_approval_decision_to_audit() {
    let result = capability_result_value(CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text("ok".to_owned())]),
        details: Some(json!({
            "status": "ok",
            "approvalDecision": {
                "approvalRequired": false,
                "approvalCreated": false,
                "approvalExecuted": false,
                "approvalReplayed": false,
                "status": "not_required"
            },
            "childInvocations": ["child-read"]
        })),
        is_error: None,
        stop_turn: None,
    })
    .expect("capability result");
    let mut orchestration = json!({
        "status": "ok",
        "childInvocationIds": ["child-read"]
    });

    enrich_orchestration_with_result(&mut orchestration, &result);

    assert_eq!(
        orchestration["approvalDecision"]["status"],
        json!("not_required")
    );
    assert_eq!(
        orchestration["approvalDecision"]["approvalRequired"],
        json!(false)
    );
}

#[test]
fn observe_phase_defaults_empty_refs_and_no_approval() {
    let result = capability_result_value(CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text("ok".to_owned())]),
        details: Some(json!({
            "status": "ok",
            "output": {
                "entries": []
            },
            "childInvocations": ["child-read"]
        })),
        is_error: None,
        stop_turn: None,
    })
    .expect("capability result");
    let orchestration = json!({
        "status": "ok",
        "childInvocationIds": ["child-read"]
    });
    let mut audit_orchestration = orchestration.clone();

    enrich_orchestration_with_result(&mut audit_orchestration, &result);
    assert_eq!(
        audit_orchestration["approvalDecision"]["status"],
        json!("not_required")
    );

    let attached = attach_orchestration_details(result, orchestration).expect("attached result");
    let attached: CapabilityResult = serde_json::from_value(attached).expect("capability result");
    let details = attached.details.expect("details");

    assert_eq!(details["resourceRefs"], json!([]));
    assert_eq!(details["childInvocationIds"], json!(["child-read"]));
    assert_eq!(details["approvalDecision"]["status"], json!("not_required"));
    assert_eq!(details["approvalDecision"]["approvalCreated"], json!(false));
}

#[test]
fn orchestrated_execute_result_exposes_its_own_invocation_id() {
    let invocation = Invocation::new_sync(
        crate::engine::FunctionId::new("capability::execute").expect("function id"),
        json!({"target": "filesystem::read_file", "arguments": {"path": "README.md"}}),
        crate::engine::CausalContext::new(
            crate::engine::ActorId::new("agent:test").expect("actor id"),
            crate::engine::ActorKind::Agent,
            crate::engine::AuthorityGrantId::new("agent-capability-runtime").expect("grant id"),
            crate::engine::TraceId::new("trace").expect("trace id"),
        ),
    );
    let result = capability_result_value(CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text("ok".to_owned())]),
        details: Some(json!({
            "status": "ok",
            "orchestration": {
                "orchestrationId": "capability-orchestration:test",
                "status": "ok",
                "childInvocationIds": ["child-read"]
            }
        })),
        is_error: None,
        stop_turn: None,
    })
    .expect("capability result");

    let attached =
        attach_execute_invocation_metadata(result, &invocation).expect("attached result");
    let attached: CapabilityResult = serde_json::from_value(attached).expect("capability result");
    let details = attached.details.expect("details");

    assert_eq!(
        details["executeInvocationId"],
        json!(invocation.id.as_str())
    );
    assert_eq!(
        details["primitiveInvocationId"],
        json!(invocation.id.as_str())
    );
    assert_eq!(
        details["orchestration"]["executeInvocationId"],
        json!(invocation.id.as_str())
    );
}
