use super::support::*;

#[test]
fn observe_phase_promotes_needs_input_recovery_fields() {
    let result = capability_result_value(CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "filesystem::read_file needs input before child execution".to_owned(),
        )]),
        details: Some(json!({
            "status": "needs_input",
            "error": {
                "code": "INVALID_PARAMS",
                "details": {
                    "validationKind": "missing_required_argument",
                    "missingFields": ["path"],
                    "missingArgumentPaths": ["arguments.path"]
                }
            },
            "guidance": {
                "kind": "provide_missing_arguments",
                "missingFields": ["path"],
                "missingArgumentPaths": ["arguments.path"]
            },
            "missingFields": ["path"],
            "missingArgumentPaths": ["arguments.path"],
            "childInvocationCreated": false,
            "childInvocationIds": [],
            "approvalCreated": false,
            "resourceRefs": []
        })),
        is_error: Some(true),
        stop_turn: None,
    })
    .expect("capability result");
    let mut orchestration = json!({
        "status": "needs_input",
        "childInvocationIds": []
    });

    enrich_orchestration_with_result(&mut orchestration, &result);
    assert_eq!(orchestration["missingFields"], json!(["path"]));
    assert_eq!(
        orchestration["missingArgumentPaths"],
        json!(["arguments.path"])
    );
    assert_eq!(
        orchestration["approvalDecision"]["status"],
        json!("not_required")
    );

    let attached = attach_orchestration_details(result, orchestration).expect("attached result");
    let attached: CapabilityResult = serde_json::from_value(attached).expect("capability result");
    let details = attached.details.expect("details");

    assert_eq!(details["missingFields"], json!(["path"]));
    assert_eq!(details["missingArgumentPaths"], json!(["arguments.path"]));
    assert_eq!(details["childInvocationIds"], json!([]));
    assert_eq!(details["approvalDecision"]["status"], json!("not_required"));
    assert_eq!(
        details["approvalDecision"]["approvalRequired"],
        json!(false)
    );
    assert_eq!(details["orchestration"]["missingFields"], json!(["path"]));
    assert_eq!(
        details["orchestration"]["missingArgumentPaths"],
        json!(["arguments.path"])
    );
}

#[test]
fn terminal_orchestration_result_promotes_recovery_fields() {
    let diagnostics = json!({
        "orchestrationId": "capability-orchestration:test",
        "status": "needs_selection",
        "intent": "do something with files",
        "correctedRequest": {
            "intent": "do something with files",
            "arguments": {}
        },
        "correctionsApplied": [],
        "correctionConfidence": 1.0,
        "phaseDetails": {
            "phase": "resolve",
            "candidates": [
                {
                    "functionId": "filesystem::read_file",
                    "contractId": "filesystem::read_file"
                },
                {
                    "functionId": "filesystem::list_dir",
                    "contractId": "filesystem::list_dir"
                }
            ],
            "searchStatus": {
                "vectorIndex": "ready"
            }
        },
        "childInvocationIds": []
    });

    let result = orchestration_result(
        "needs_selection",
        "Multiple visible capabilities match that intent.",
        diagnostics,
        true,
    )
    .expect("orchestration result");
    let result: CapabilityResult = serde_json::from_value(result).expect("capability result");
    let details = result.details.expect("details");

    assert_eq!(details["status"], json!("needs_selection"));
    assert_eq!(
        details["candidates"][0]["functionId"],
        json!("filesystem::read_file")
    );
    assert_eq!(details["searchStatus"]["vectorIndex"], json!("ready"));
    assert_eq!(
        details["correctedRequest"]["intent"],
        json!("do something with files")
    );
    assert_eq!(details["childInvocationCreated"], json!(false));
    assert_eq!(details["approvalDecision"]["status"], json!("not_required"));
    assert_eq!(details["resourceRefs"], json!([]));
}

#[test]
fn terminal_orchestration_result_promotes_guidance_for_invalid_capability_primitive_target() {
    let diagnostics = json!({
        "orchestrationId": "capability-orchestration:test",
        "status": "request_invalid",
        "intent": "wrap capability search",
        "correctedRequest": {
            "intent": "wrap capability search",
            "target": "capability::search",
            "arguments": {}
        },
        "correctionsApplied": [],
        "correctionConfidence": 1.0,
        "phaseDetails": {
            "phase": "prepare",
            "selectedTarget": {
                "functionId": "capability::search"
            },
            "error": {
                "code": "INVALID_PARAMS",
                "message": "execute cannot target capability::search because it is a capability primitive"
            },
            "guidance": {
                "kind": "target_real_capability",
                "message": "Call execute once.",
                "examples": [
                    {"target": "filesystem::read_file", "arguments": {"path": "README.md"}}
                ]
            }
        },
        "childInvocationIds": []
    });

    let result = orchestration_result(
        "request_invalid",
        "execute target is invalid.",
        diagnostics,
        true,
    )
    .expect("orchestration result");
    let result: CapabilityResult = serde_json::from_value(result).expect("capability result");
    let details = result.details.expect("details");

    assert_eq!(details["status"], json!("request_invalid"));
    assert_eq!(
        details["selectedTarget"]["functionId"],
        json!("capability::search")
    );
    assert_eq!(details["guidance"]["kind"], json!("target_real_capability"));
    assert_eq!(details["childInvocationIds"], json!([]));
    assert_eq!(details["approvalDecision"]["status"], json!("not_required"));
    assert_eq!(details["resourceRefs"], json!([]));
}

#[test]
fn terminal_orchestration_result_promotes_decomposition_guidance() {
    let diagnostics = json!({
        "orchestrationId": "capability-orchestration:test",
        "status": "needs_decomposition",
        "intent": "read two files",
        "correctedRequest": {
            "intent": "read two files",
            "target": {"functionId": "filesystem::read_file"},
            "arguments": {}
        },
        "correctionsApplied": [],
        "correctionConfidence": 1.0,
        "phaseDetails": {
            "phase": "prepare",
            "decomposition": {
                "reason": "multiple_files_for_single_target",
                "targetCount": 2
            },
            "guidance": {
                "kind": "one_target_per_execute",
                "suggestedCalls": [
                    {"target": "filesystem::read_file", "arguments": {"path": "README.md"}},
                    {"target": "filesystem::read_file", "arguments": {"path": "packages/agent/README.md"}}
                ]
            },
            "suggestedCalls": [
                {"target": "filesystem::read_file", "arguments": {"path": "README.md"}},
                {"target": "filesystem::read_file", "arguments": {"path": "packages/agent/README.md"}}
            ]
        },
        "childInvocationIds": []
    });

    let result = orchestration_result(
        "needs_decomposition",
        "execute needs decomposition before child execution.",
        diagnostics,
        orchestration_status_is_error("needs_decomposition"),
    )
    .expect("orchestration result");
    let result: CapabilityResult = serde_json::from_value(result).expect("capability result");
    let details = result.details.expect("details");

    assert_eq!(details["status"], json!("needs_decomposition"));
    assert_eq!(details["childInvocationCreated"], json!(false));
    assert_eq!(details["childInvocationIds"], json!([]));
    assert_eq!(details["decomposition"]["targetCount"], json!(2));
    assert_eq!(
        details["suggestedCalls"][0]["arguments"]["path"],
        json!("README.md")
    );
    assert_eq!(details["isError"], Value::Null);
}

#[test]
fn orchestration_failure_status_keeps_policy_denials_in_prepare_phase() {
    let denied = CapabilityError::Custom {
        code: "CAPABILITY_DENIED".to_owned(),
        message: "process::run is not allowed by the active capability policy".to_owned(),
        details: None,
    };
    let runtime = CapabilityError::Internal {
        message: "worker disappeared".to_owned(),
    };

    assert_eq!(orchestration_failure_status(&denied), "prepare_failed");
    assert_eq!(orchestration_failure_status(&runtime), "run_failed");
}
