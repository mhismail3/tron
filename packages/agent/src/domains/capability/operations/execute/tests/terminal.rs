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
fn execute_guidance_covers_self_modifying_lifecycle_errors() {
    let cases = [
        (
            "missing_expected_function_ids",
            "needs_input",
            json!({
                "phase": "prepare",
                "selectedTarget": {"functionId": "worker::spawn"},
                "missingFields": ["expectedFunctionIds"],
                "missingArgumentPaths": ["arguments.expectedFunctionIds"],
                "guidance": {
                    "kind": "provide_missing_arguments",
                    "message": "Re-run execute with worker::spawn and include expectedFunctionIds for the functions the session worker must register.",
                    "missingFields": ["expectedFunctionIds"],
                    "missingArgumentPaths": ["arguments.expectedFunctionIds"]
                }
            }),
            "provide_missing_arguments",
            "expectedFunctionIds",
        ),
        (
            "missing_session_id",
            "needs_input",
            json!({
                "phase": "prepare",
                "selectedTarget": {"functionId": "worker::spawn"},
                "missingFields": ["sessionId"],
                "missingArgumentPaths": ["arguments.sessionId"],
                "guidance": {
                    "kind": "provide_missing_arguments",
                    "message": "Re-run execute with the current sessionId so the spawned worker stays session-scoped.",
                    "missingFields": ["sessionId"],
                    "missingArgumentPaths": ["arguments.sessionId"]
                }
            }),
            "provide_missing_arguments",
            "sessionId",
        ),
        (
            "stale_revision",
            "prepare_failed",
            json!({
                "phase": "prepare",
                "selectedTarget": {"functionId": "engine::promote"},
                "error": {
                    "code": "STALE_CAPABILITY_REVISION",
                    "message": "engine::promote is at revision 8, not requested revision 7",
                    "details": {
                        "functionId": "engine::promote",
                        "expectedRevision": 7,
                        "currentRevision": 8
                    }
                }
            }),
            "refresh_capability_revision",
            "currentRevision",
        ),
        (
            "target_trigger_id",
            "needs_selection",
            json!({
                "phase": "resolve",
                "selectedTarget": {"triggerId": "manual:session-worker.run"},
                "guidance": {
                    "kind": "target_related_function",
                    "message": "Trigger ids are metadata, not executable capability targets. Re-run execute with target worker::run_conformance.",
                    "relatedFunctionIds": ["worker::run_conformance"],
                    "suggestedCalls": [
                        {"target": "worker::run_conformance", "arguments": {"workerId": "worker:test"}}
                    ]
                },
                "suggestedCalls": [
                    {"target": "worker::run_conformance", "arguments": {"workerId": "worker:test"}}
                ]
            }),
            "target_related_function",
            "worker::run_conformance",
        ),
    ];

    for (label, status, phase_details, expected_kind, marker) in cases {
        let diagnostics = json!({
            "orchestrationId": format!("capability-orchestration:{label}"),
            "status": status,
            "intent": "customize my harness",
            "correctedRequest": {
                "intent": "customize my harness",
                "arguments": {}
            },
            "correctionsApplied": [],
            "correctionConfidence": 1.0,
            "phaseDetails": phase_details,
            "childInvocationIds": []
        });
        let result = orchestration_result(
            status,
            "execute needs repair guidance before child execution.",
            diagnostics,
            orchestration_status_is_error(status),
        )
        .unwrap_or_else(|error| panic!("{label} result: {error}"));
        let result: CapabilityResult =
            serde_json::from_value(result).unwrap_or_else(|error| panic!("{label}: {error}"));
        let details = result.details.unwrap_or_else(|| panic!("{label}: details"));

        assert_eq!(details["childInvocationCreated"], json!(false), "{label}");
        assert_eq!(
            details["approvalDecision"]["status"],
            json!("not_required"),
            "{label}"
        );
        assert_eq!(details["guidance"]["kind"], json!(expected_kind), "{label}");
        assert!(
            details["guidance"].to_string().contains(marker),
            "{label}: guidance {details}"
        );
    }

    let ambiguous_candidates = json!([
        {"functionId": "worker::spawn", "contractId": "worker::spawn"},
        {"functionId": "module::activate", "contractId": "module::activate"}
    ]);
    let ambiguous_diagnostics = json!({
        "orchestrationId": "capability-orchestration:ambiguous-target",
        "status": "needs_selection",
        "intent": "set up a worker",
        "correctedRequest": {
            "intent": "set up a worker",
            "arguments": {}
        },
        "correctionsApplied": [],
        "correctionConfidence": 1.0,
        "phaseDetails": {
            "phase": "resolve",
            "candidates": ambiguous_candidates,
            "searchStatus": {"vectorIndex": "ready"}
        },
        "childInvocationIds": []
    });
    let ambiguous = orchestration_result(
        "needs_selection",
        "Multiple visible capabilities match that intent.",
        ambiguous_diagnostics,
        orchestration_status_is_error("needs_selection"),
    )
    .expect("ambiguous result");
    let ambiguous: CapabilityResult = serde_json::from_value(ambiguous).expect("capability result");
    let ambiguous_details = ambiguous.details.expect("ambiguous details");
    assert_eq!(
        ambiguous_details["guidance"]["kind"],
        json!("select_target")
    );
    assert_eq!(
        ambiguous_details["guidance"]["candidateFunctionIds"],
        json!(["worker::spawn", "module::activate"])
    );
    assert!(
        ambiguous_details["guidance"]["message"]
            .as_str()
            .expect("guidance message")
            .contains("Re-run execute with target set to one of: worker::spawn, module::activate")
    );

    let mut mutating_function = function_from_capability("filesystem::write_file");
    mutating_function.effect_class = crate::engine::EffectClass::IdempotentWrite;
    let target = resolved_target_for(mutating_function.clone());
    let idempotency_error = CapabilityError::InvalidParams {
        message: "filesystem::write_file mutates state; pass idempotencyKey or invoke through a model capability invocation with engine idempotency".to_owned(),
    };
    let idempotency = preflight_rejection_result(
        &mutating_function,
        &target,
        idempotency_error,
        "idempotency_required",
    )
    .expect("idempotency result");
    let idempotency: CapabilityResult =
        serde_json::from_value(idempotency).expect("capability result");
    let idempotency_details = idempotency.details.expect("idempotency details");
    assert_eq!(
        idempotency_details["guidance"]["kind"],
        json!("provide_idempotency_key")
    );
    assert_eq!(
        idempotency_details["missingArgumentPaths"],
        json!(["idempotencyKey"])
    );
    assert_eq!(idempotency_details["childInvocationCreated"], json!(false));

    let approval_result = capability_result_value(CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "approval required".to_owned(),
        )]),
        details: Some(json!({
            "status": "approval_required",
            "approvalId": "approval-c3",
            "approvalRequired": true,
            "approvalCreated": true,
            "guidance": {
                "kind": "wait_for_approval",
                "message": "Wait for the approval decision; do not self-approve or retry with a different idempotency key."
            },
            "childInvocationIds": [],
            "resourceRefs": []
        })),
        is_error: Some(true),
        stop_turn: Some(true),
    })
    .expect("approval result");
    let mut approval_orchestration = json!({
        "status": "approval_required",
        "childInvocationIds": [],
        "phaseDetails": {
            "phase": "approval",
            "selectedTarget": {"functionId": "process::run"}
        }
    });
    enrich_orchestration_with_result(&mut approval_orchestration, &approval_result);
    assert_eq!(
        approval_orchestration["approvalDecision"]["status"],
        json!("approval_flow")
    );
    assert_eq!(
        approval_orchestration["approvalDecision"]["approvalId"],
        json!("approval-c3")
    );
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
