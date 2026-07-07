use super::*;
use crate::domains::agent::r#loop::types::CapabilityInvocationExecutionResult;
use crate::shared::protocol::content::CapabilityResultContent;
use crate::shared::protocol::messages::CapabilityResultMessageContent;
use crate::shared::protocol::model_capabilities::{CapabilityResult, CapabilityResultBody};
use serde_json::{Value, json};

fn make_exec_result(content: CapabilityResultBody) -> CapabilityInvocationExecutionResult {
    make_exec_result_with_details(content, None)
}

fn make_exec_result_with_details(
    content: CapabilityResultBody,
    details: Option<Value>,
) -> CapabilityInvocationExecutionResult {
    CapabilityInvocationExecutionResult {
        result: CapabilityResult {
            content,
            details,
            is_error: None,
            stop_turn: None,
        },
        duration_ms: 100,
        stops_turn: false,
    }
}

#[test]
fn extract_result_content_text_body_passthrough() {
    let exec = make_exec_result(CapabilityResultBody::Text("hello".into()));
    let content = extract_result_content(&exec);
    assert!(matches!(content, CapabilityResultMessageContent::Text(ref t) if t == "hello"));
}

#[test]
fn extract_result_content_text_blocks_flatten() {
    let exec = make_exec_result(CapabilityResultBody::Blocks(vec![
        CapabilityResultContent::text("line 1"),
        CapabilityResultContent::text("line 2"),
    ]));
    let content = extract_result_content(&exec);
    assert!(
        matches!(content, CapabilityResultMessageContent::Text(ref t) if t == "line 1\nline 2")
    );
}

#[test]
fn extract_result_content_mixed_blocks_preserve() {
    let exec = make_exec_result(CapabilityResultBody::Blocks(vec![
        CapabilityResultContent::text("screenshot taken"),
        CapabilityResultContent::image("base64data", "image/png"),
    ]));
    let content = extract_result_content(&exec);
    match content {
        CapabilityResultMessageContent::Blocks(blocks) => {
            assert_eq!(blocks.len(), 2);
            assert!(
                matches!(&blocks[0], CapabilityResultContent::Text { text } if text == "screenshot taken")
            );
            assert!(
                matches!(&blocks[1], CapabilityResultContent::Image { data, mime_type } if data == "base64data" && mime_type == "image/png")
            );
        }
        CapabilityResultMessageContent::Text(_) => panic!("expected Blocks variant"),
    }
}

#[test]
fn extract_model_context_result_text_matches_direct_text() {
    let exec = make_exec_result(CapabilityResultBody::Text("direct output".into()));
    assert_eq!(extract_model_context_result_text(&exec), "direct output");
}

#[test]
fn extract_result_content_projects_catalog_ids_for_model_context() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "Catalog search returned 1 visible functions.",
        )]),
        Some(json!({
            "primitiveOperation": "catalog_search",
            "status": "ok",
            "catalogDiscovery": {
                "summary": {"functions": {"visible": 1}},
                "functions": [{
                    "id": "logs::recent",
                    "description": "Recent logs",
                    "modelFacingInvocation": {
                        "tool": "capability::execute",
                        "operation": "log_recent",
                        "arguments": {"operation": "log_recent"},
                        "catalogInspectId": "logs::recent"
                    }
                }]
            }
        })),
    );

    let content = extract_result_content(&exec);

    let CapabilityResultMessageContent::Text(text) = content else {
        panic!("expected text result");
    };
    assert!(text.contains("modelContextEvidence"));
    assert!(text.contains("logs::recent"));
    assert!(text.contains("log_recent"));
}

#[test]
fn extract_result_content_projects_catalog_operation_truncation_metadata() {
    let operations = (0..25)
        .map(|index| json!(format!("operation_{index}")))
        .collect::<Vec<_>>();
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "Catalog search returned 1 visible functions.",
        )]),
        Some(json!({
            "primitiveOperation": "catalog_search",
            "status": "ok",
            "catalogDiscovery": {
                "summary": {"functions": {"visible": 1}},
                "functions": [],
                "modelFacingGuidance": {
                    "catalogInspect": "Use functions[].id exactly.",
                    "capabilityExecute": "Use capability::execute.",
                    "supportedExecuteOperations": operations
                }
            }
        })),
    );

    let CapabilityResultMessageContent::Text(text) = extract_result_content(&exec) else {
        panic!("expected text result");
    };
    assert!(text.contains("\"total\": 25"));
    assert!(text.contains("\"returned\""));
    assert!(text.contains("\"truncated\": true"));
    assert!(text.contains("\"omitted\": 5"));
    assert!(text.contains("operation_19"));
    assert!(!text.contains("operation_20"));
}

#[test]
fn extract_result_content_projects_catalog_execute_operation_matches() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "Catalog search returned 1 visible functions and 1 execute operation match(es).",
        )]),
        Some(json!({
            "primitiveOperation": "catalog_search",
            "status": "ok",
            "catalogDiscovery": {
                "summary": {"functions": {"visible": 1}},
                "functions": [],
                "executeOperationMatches": [{
                    "operation": "trace_list",
                    "tool": "capability::execute",
                    "arguments": {"operation": "trace_list"},
                    "matchKind": "exact",
                    "capabilityPool": {
                        "surface": "agent_operation",
                        "audience": "agent_diagnostics",
                        "replacementClass": "kernel_evolution_only"
                    },
                    "agentUsage": {
                        "callable": true,
                        "defaultUse": "diagnose_or_verify",
                        "effect": {
                            "mode": "read_only",
                            "readOnlyInspectionSafe": true,
                            "mutatesState": false,
                            "readOnlyInstruction": "safe to call during read-only inspection"
                        }
                    }
                }]
            }
        })),
    );

    let CapabilityResultMessageContent::Text(text) = extract_result_content(&exec) else {
        panic!("expected text result");
    };
    assert!(text.contains("executeOperationMatches"));
    assert!(text.contains("trace_list"));
    assert!(text.contains("diagnose_or_verify"));
    assert!(text.contains("kernel_evolution_only"));
    assert!(text.contains("readOnlyInspectionSafe"));
    assert!(text.contains("safe to call during read-only inspection"));
}

#[test]
fn extract_result_content_projects_capability_cockpit_overview_digest() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "Capability cockpit overview returned 5 operation(s).",
        )]),
        Some(json!({
            "primitiveOperation": "capability_binding_cockpit_overview",
            "status": "ok",
            "capabilityBinding": {
                "summary": {
                    "title": "Capability ownership visible",
                    "detail": "5 capability::execute operations have server-owned modularity metadata; 5 are returned.",
                    "totalOperations": 5,
                    "returnedOperations": 5,
                    "operationListComplete": true,
                    "operationListTruncated": false,
                    "kernelLocked": 1,
                    "governanceLocked": 3,
                    "recordPlane": 0,
                    "adapterReplaceable": 1,
                    "moduleOwned": 0
                },
                "operationList": {
                    "complete": true,
                    "returnedOperations": 5,
                    "totalOperations": 5,
                    "truncated": false
                },
                "families": [{
                    "family": "git",
                    "label": "Git",
                    "operations": 1,
                    "adapterReplaceable": 1
                }],
                "operations": [
                    {
                        "name": "git_status",
                        "family": "git",
                        "familyLabel": "Git",
                        "capabilityPool": {
                            "surface": "agent_operation",
                            "audience": "session_work",
                            "replacementClass": "runtime_routable",
                            "agentDefaultVisibility": "default_visible",
                            "minimalityDecision": "module_candidate",
                            "evolutionPath": "candidate_validation_shadow_approval_activation_route_event_rollback"
                        },
                        "agentUsage": {
                            "tool": "capability::execute",
                            "operation": "git_status",
                            "arguments": {"operation": "git_status"},
                            "callable": true,
                            "defaultUse": "perform_session_work",
                            "effect": {
                                "mode": "read_only",
                                "readOnlyInspectionSafe": true,
                                "mutatesState": false,
                                "readOnlyInstruction": "safe to call during read-only inspection"
                            },
                            "authorityGrantId": "grant_must_not_project",
                            "preflight": {
                                "agentStateInherited": false,
                                "authorityScopes": ["git.read"],
                                "networkPolicy": "none",
                                "resourceSelectors": ["workspace:trusted"],
                                "authorityGrantId": "nested_grant_must_not_project"
                            }
                        },
                        "readiness": {"state": "proposal_possible", "label": "Proposal possible"},
                        "replacement": {
                            "label": "Shadow or replace after review",
                            "canExtend": true,
                            "canReplace": true,
                            "canShadow": true
                        },
                        "status": {
                            "kind": "built_in_adapter",
                            "label": "Built-in adapter",
                            "locked": false,
                            "builtIn": true,
                            "moduleOwned": false
                        }
                    },
                    {
                        "name": "trace_list",
                        "family": "trace",
                        "familyLabel": "Trace",
                        "capabilityPool": {
                            "surface": "agent_operation",
                            "audience": "agent_diagnostics",
                            "replacementClass": "kernel_evolution_only",
                            "agentDefaultVisibility": "search_visible",
                            "minimalityDecision": "keep_core",
                            "evolutionPath": "source_candidate_validation_adversarial_review_user_approved_integration"
                        },
                        "agentUsage": {
                            "tool": "capability::execute",
                            "operation": "trace_list",
                            "arguments": {"operation": "trace_list"},
                            "callable": true,
                            "defaultUse": "diagnose_or_verify",
                            "effect": {
                                "mode": "read_only",
                                "readOnlyInspectionSafe": true,
                                "mutatesState": false,
                                "readOnlyInstruction": "safe to call during read-only inspection"
                            }
                        }
                    },
                    {
                        "name": "capability_binding_cockpit_overview",
                        "family": "capability_binding",
                        "familyLabel": "Capability Binding",
                        "capabilityPool": {
                            "surface": "agent_operation",
                            "audience": "governance",
                            "replacementClass": "kernel_evolution_only",
                            "agentDefaultVisibility": "search_visible",
                            "minimalityDecision": "keep_governance",
                            "evolutionPath": "source_candidate_validation_adversarial_review_user_approved_integration"
                        },
                        "agentUsage": {
                            "tool": "capability::execute",
                            "operation": "capability_binding_cockpit_overview",
                            "arguments": {"operation": "capability_binding_cockpit_overview"},
                            "callable": true,
                            "defaultUse": "governed_record_or_inspection",
                            "effect": {
                                "mode": "read_only",
                                "readOnlyInspectionSafe": true,
                                "mutatesState": false,
                                "readOnlyInstruction": "safe to call during read-only inspection"
                            }
                        }
                    },
                    {
                        "name": "capability_binding_request_list",
                        "family": "capability_binding",
                        "familyLabel": "Capability Binding",
                        "capabilityPool": {
                            "surface": "agent_operation",
                            "audience": "governance",
                            "replacementClass": "kernel_evolution_only",
                            "agentDefaultVisibility": "search_visible",
                            "minimalityDecision": "keep_governance",
                            "evolutionPath": "source_candidate_validation_adversarial_review_user_approved_integration"
                        },
                        "agentUsage": {
                            "tool": "capability::execute",
                            "operation": "capability_binding_request_list",
                            "arguments": {"operation": "capability_binding_request_list"},
                            "callable": true,
                            "defaultUse": "governed_record_or_inspection",
                            "effect": {
                                "mode": "read_only",
                                "readOnlyInspectionSafe": true,
                                "mutatesState": false,
                                "readOnlyInstruction": "safe to call during read-only inspection"
                            },
                            "preflight": {
                                "agentStateInherited": false,
                                "authorityScopes": ["capability_binding.read", "resource.read"],
                                "networkPolicy": "none",
                                "readOnlyInstruction": "safe to call during read-only inspection",
                                "resourceSelectors": [
                                    "kind:capability_binding_request"
                                ],
                                "authorityGrantId": "nested_grant_must_not_project"
                            }
                        }
                    },
                    {
                        "name": "capability_shadow_trial_request_record",
                        "family": "capability_binding",
                        "familyLabel": "Capability Binding",
                        "capabilityPool": {
                            "surface": "agent_operation",
                            "audience": "governance",
                            "replacementClass": "kernel_evolution_only",
                            "agentDefaultVisibility": "search_visible",
                            "minimalityDecision": "keep_governance",
                            "evolutionPath": "source_candidate_validation_adversarial_review_user_approved_integration"
                        },
                        "agentUsage": {
                            "tool": "capability::execute",
                            "operation": "capability_shadow_trial_request_record",
                            "arguments": {"operation": "capability_shadow_trial_request_record"},
                            "callable": true,
                            "defaultUse": "governed_write_after_evidence_and_approval",
                            "effect": {
                                "mode": "metadata_write",
                                "readOnlyInspectionSafe": false,
                                "mutatesState": true,
                                "readOnlyInstruction": "do not call during read-only inspection; inspect schema/catalog/list operations instead"
                            },
                            "preflight": {
                                "agentStateInherited": false,
                                "authorityScopes": ["capability_binding.read", "capability_binding.write", "resource.read", "resource.write"],
                                "networkPolicy": "none",
                                "readOnlyInstruction": "Do not call during read-only inspection; this records durable shadow-trial request metadata.",
                                "resourceSelectors": [
                                    "kind:capability_shadow_trial_request",
                                    "kind:capability_shadow_trial_decision",
                                    "kind:capability_shadow_trial_run",
                                    "kind:capability_shadow_trial_evidence"
                                ],
                                "requiredPayloadFields": [
                                    "operation",
                                    "targetOperation",
                                    "ownershipClass",
                                    "bindingMode",
                                    "candidateAdapter",
                                    "authorityConstraints",
                                    "contractEvidenceRefs",
                                    "evidenceRefs",
                                    "staleVersionGuard",
                                    "rollbackRef",
                                    "disableRef",
                                    "abortRef",
                                    "rationale",
                                    "idempotencyKey"
                                ],
                                "example": {
                                    "operation": "capability_shadow_trial_request_record",
                                    "targetOperation": "git_status",
                                    "bindingMode": "shadow",
                                    "candidateAdapter": {
                                        "adapterId": "candidate_git_status_adapter",
                                        "executionMode": "metadata_only",
                                        "networkPolicy": "none"
                                    }
                                }
                            }
                        }
                    }
                ]
            }
        })),
    );

    let CapabilityResultMessageContent::Text(text) = extract_result_content(&exec) else {
        panic!("expected text result");
    };
    assert!(text.contains("Capability ownership visible"));
    assert!(text.contains("\"missingCapabilityPool\": 0"));
    assert!(text.contains("\"missingAgentUsage\": 0"));
    assert!(text.contains("git_status"));
    assert!(text.contains("trace_list"));
    assert!(text.contains("capability_binding_cockpit_overview"));
    assert!(text.contains("capability_binding_request_list"));
    assert!(text.contains("capability_shadow_trial_request_record"));
    assert!(text.contains("runtime_routable"));
    assert!(text.contains("kernel_evolution_only"));
    assert!(text.contains("operationDirectory"));
    assert!(text.contains("requiredPayloadFields"));
    assert!(text.contains("targetOperation"));
    assert!(text.contains("capability_binding.read"));
    assert!(text.contains("kind:capability_binding_request"));
    assert!(text.contains("kind:capability_shadow_trial_request"));
    assert!(text.contains("readOnlyInspectionSafe"));
    assert!(text.contains("safe to call during read-only inspection"));
    assert!(text.contains("do not call during read-only inspection"));
    assert!(!text.contains("authorityGrantId"));
    assert!(!text.contains("grant_must_not_project"));
    assert!(!text.contains("nested_grant_must_not_project"));
}

#[test]
fn extract_result_content_projects_metadata_ids_without_raw_payload() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "Procedural definition metadata recorded.",
        )]),
        Some(json!({
            "primitiveOperation": "procedural_definition_record",
            "status": "recorded",
            "procedural": {
                "proceduralRecordResourceId": "procedural_record:abc123",
                "proceduralRecordVersionId": "ver_abc123",
                "status": "draft",
                "summary": "Bounded metadata summary",
                "description": {
                    "title": "nested raw object must not be projected",
                    "rawPromptBody": "nested raw prompt must not be projected"
                },
                "rawPromptBody": "must not be projected",
                "authorityGrantId": "grant_secret",
                "activation": {
                    "performed": false,
                    "processStarted": false
                }
            }
        })),
    );

    let CapabilityResultMessageContent::Text(text) = extract_result_content(&exec) else {
        panic!("expected text result");
    };
    assert!(text.contains("modelContextEvidence"));
    assert!(text.contains("procedural_record:abc123"));
    assert!(text.contains("ver_abc123"));
    assert!(text.contains("Bounded metadata summary"));
    assert!(!text.contains("must not be projected"));
    assert!(!text.contains("nested raw object"));
    assert!(!text.contains("grant_secret"));
    assert!(!text.contains("authorityGrantId"));
}

#[test]
fn extract_result_content_projects_schema_error_code_and_path() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "domain server_capability failed",
        )]),
        Some(json!({
            "failure": {
                "code": "ENGINE_SCHEMA_VIOLATION",
                "category": "invalid_request",
                "message": "expected type string at /Users/example/Workspace/tron/secret.txt",
                "origin": "engine",
                "retryable": false,
                "recoverable": true,
                "details": {
                    "functionId": "resource::payload",
                    "path": "$.baseContentHash",
                    "direction": "resource_payload",
                    "rawCommand": "cat secret.txt"
                }
            },
            "modelPrimitiveName": "execute",
            "providerInvocationId": "call_123"
        })),
    );

    let CapabilityResultMessageContent::Text(text) = extract_result_content(&exec) else {
        panic!("expected text result");
    };
    assert!(text.contains("ENGINE_SCHEMA_VIOLATION"));
    assert!(text.contains("$.baseContentHash"));
    assert!(text.contains("resource::payload"));
    assert!(text.contains("[redacted-path]"));
    assert!(!text.contains("/Users/example"));
    assert!(!text.contains("cat secret.txt"));
}

#[test]
fn extract_result_content_redacts_authority_tokens_but_keeps_selector_guidance() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "capability_binding_request_list failed",
        )]),
        Some(json!({
            "failure": {
                "code": "ENGINE_POLICY_VIOLATION",
                "category": "invalid_request",
                "message": "authority grant 019f3b30-0be0-7802-a298-d8cda2c1c590 requires explicit kind:capability_binding_request selector for capability binding policy operations",
                "origin": "engine",
                "retryable": true,
                "recoverable": true,
                "suggestion": "Retry with kind:capability_binding_request",
                "details": {
                    "operation": "capability_binding_request_list",
                    "required": "kind:capability_binding_request"
                }
            },
            "modelPrimitiveName": "execute",
            "providerInvocationId": "call_123"
        })),
    );

    let CapabilityResultMessageContent::Text(text) = extract_result_content(&exec) else {
        panic!("expected text result");
    };
    assert!(text.contains("ENGINE_POLICY_VIOLATION"));
    assert!(text.contains("capability_binding_request_list"));
    assert!(text.contains("requires explicit kind:capability_binding_request selector"));
    assert!(text.contains("Retry with kind:capability_binding_request"));
    assert!(text.contains("authority grant [redacted-authority] requires"));
    assert!(!text.contains("019f3b30-0be0-7802-a298-d8cda2c1c590"));
}

#[test]
fn extract_result_content_projects_capability_binding_records_for_agent_context() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "Listed 1 capability binding request.",
        )]),
        Some(json!({
            "primitiveOperation": "capability_binding_request_list",
            "status": "ok",
            "capabilityBinding": {
                "status": "ok",
                "bindingRequests": [{
                    "resourceId": "capability_binding_request:first",
                    "versionId": "ver_binding_request_first",
                    "targetOperation": "git_status",
                    "ownershipClass": "adapter_replaceable",
                    "replacementClass": "runtime_routable",
                    "bindingMode": "shadow",
                    "routeState": "candidate",
                    "authorityGrantId": "grant_must_not_project"
                }]
            }
        })),
    );

    let CapabilityResultMessageContent::Text(text) = extract_result_content(&exec) else {
        panic!("expected text result");
    };
    assert!(text.contains("modelContextEvidence"));
    assert!(text.contains("capability_binding_request_list"));
    assert!(text.contains("bindingRequests"));
    assert!(text.contains("capability_binding_request:first"));
    assert!(text.contains("ver_binding_request_first"));
    assert!(text.contains("git_status"));
    assert!(text.contains("adapter_replaceable"));
    assert!(text.contains("runtime_routable"));
    assert!(text.contains("shadow"));
    assert!(!text.contains("authorityGrantId"));
    assert!(!text.contains("grant_must_not_project"));
}

#[test]
fn extract_result_content_projects_filesystem_resource_refs_without_diff_or_content() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "filesystem_write preview: new-note.txt",
        )]),
        Some(json!({
            "primitiveOperation": "filesystem_write",
            "status": "preview",
            "filesystem": {
                "path": {"root": "working_directory", "relativePath": "new-note.txt"},
                "diff": "--- raw diff must stay out",
                "after": {"preview": "raw file content must stay out"},
                "resourceRefs": [{
                    "kind": "patch_proposal",
                    "resourceId": "patch_proposal:provider-call",
                    "versionId": "ver_patch",
                    "lifecycle": "proposed"
                }]
            }
        })),
    );

    let CapabilityResultMessageContent::Text(text) = extract_result_content(&exec) else {
        panic!("expected text result");
    };
    assert!(text.contains("patch_proposal:provider-call"));
    assert!(text.contains("ver_patch"));
    assert!(!text.contains("--- raw diff"));
    assert!(!text.contains("raw file content"));
}

#[test]
fn extract_result_content_projects_trace_metadata_ids() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text("Trace records: 1.")]),
        Some(json!({
            "primitiveOperation": "trace_list",
            "status": "ok",
            "records": [{
                "id": "019f-trace-record",
                "timestamp": "2026-06-30T07:30:00Z",
                "metadata": {
                    "dev.tron": {
                        "traceId": "trace_nested",
                        "invocationId": "inv_nested",
                        "providerInvocationId": "provider_nested",
                        "operation": "procedural_definition_record",
                        "error": {
                            "code": "ENGINE_SCHEMA_VIOLATION",
                            "message": "failed at /Users/example/secret",
                            "details": {
                                "path": "$.field",
                                "rawCommand": "cat hidden"
                            }
                        },
                        "authority": {
                            "authorityGrantId": "grant_must_not_project",
                            "scopes": ["capability.execute"]
                        }
                    }
                }
            }]
        })),
    );

    let CapabilityResultMessageContent::Text(text) = extract_result_content(&exec) else {
        panic!("expected text result");
    };
    assert!(text.contains("019f-trace-record"));
    assert!(text.contains("trace_nested"));
    assert!(text.contains("inv_nested"));
    assert!(text.contains("provider_nested"));
    assert!(text.contains("procedural_definition_record"));
    assert!(text.contains("ENGINE_SCHEMA_VIOLATION"));
    assert!(text.contains("$.field"));
    assert!(text.contains("[redacted-path]"));
    assert!(!text.contains("grant_must_not_project"));
    assert!(!text.contains("authorityGrantId"));
    assert!(!text.contains("/Users/example"));
    assert!(!text.contains("cat hidden"));
}

#[test]
fn extract_result_content_projects_recent_logs_for_model_context() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text("Log entries: 1.")]),
        Some(json!({
            "primitiveOperation": "log_recent",
            "status": "ok",
            "entries": [{
                "id": 42,
                "timestamp": "2026-06-29T10:00:00Z",
                "level": "warn",
                "component": "ios.events",
                "message": "Unknown event type: capability.invocation.arguments_delta",
                "sessionId": "sess_1",
                "traceId": "trace_1"
            }]
        })),
    );

    let content = extract_result_content(&exec);

    let CapabilityResultMessageContent::Text(text) = content else {
        panic!("expected text result");
    };
    assert!(text.contains("modelContextEvidence"));
    assert!(text.contains("capability.invocation.arguments_delta"));
    assert!(text.contains("sess_1"));
}

#[test]
fn extract_result_content_redacts_log_evidence_for_model_context() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text("Log entries: 1.")]),
        Some(json!({
            "primitiveOperation": "log_recent",
            "status": "ok",
            "entries": [{
                "id": 42,
                "timestamp": "2026-06-29T10:00:00Z",
                "level": "warn",
                "component": "diagnostics",
                "message": "failed at /Users/example/Workspace/tron with ghp_xxxxxxxxxxxxxxxxxxxx123456",
                "sessionId": "sess_1",
                "traceId": "trace_1"
            }]
        })),
    );

    let content = extract_result_content(&exec);

    let CapabilityResultMessageContent::Text(text) = content else {
        panic!("expected text result");
    };
    assert!(text.contains("[redacted-path]"));
    assert!(text.contains("gh*_****"));
    assert!(!text.contains("/Users/example"));
    assert!(!text.contains("ghp_xxxxxxxxxxxxxxxxxxxx123456"));
}

#[test]
fn extract_result_content_does_not_project_unlisted_raw_details() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text("Command completed.")]),
        Some(json!({
            "primitiveOperation": "process_run",
            "status": "ok",
            "stdout": "raw diagnostic payload that must stay out of model-context projection"
        })),
    );

    let content = extract_result_content(&exec);

    let CapabilityResultMessageContent::Text(text) = content else {
        panic!("expected text result");
    };
    assert_eq!(text, "Command completed.");
    assert!(!text.contains("raw diagnostic payload"));
}

#[test]
fn extract_result_content_drops_failure_actual_object_values() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "domain server_capability failed",
        )]),
        Some(json!({
            "failure": {
                "code": "ENGINE_SCHEMA_VIOLATION",
                "category": "invalid_request",
                "message": "schema mismatch",
                "origin": "engine",
                "retryable": false,
                "recoverable": true,
                "details": {
                    "path": "$.baseContentHash",
                    "expected": "string",
                    "actual": {
                        "content": "raw provider-visible content must not project",
                        "rawCommand": "cat /Users/example/secret.txt",
                        "authorityGrantId": "grant_actual_secret",
                        "authorityVersionId": "authority_version_actual_secret",
                        "path": "$.actual.path.must_not_project"
                    }
                }
            },
            "modelPrimitiveName": "execute",
            "providerInvocationId": "call_123"
        })),
    );

    let CapabilityResultMessageContent::Text(text) = extract_result_content(&exec) else {
        panic!("expected text result");
    };
    assert!(text.contains("ENGINE_SCHEMA_VIOLATION"));
    assert!(text.contains("$.baseContentHash"));
    assert!(text.contains("string"));
    assert!(!text.contains("\"actual\""));
    assert!(!text.contains("raw provider-visible content"));
    assert!(!text.contains("cat /Users/example/secret.txt"));
    assert!(!text.contains("grant_actual_secret"));
    assert!(!text.contains("authority_version_actual_secret"));
    assert!(!text.contains("$.actual.path.must_not_project"));
}

#[test]
fn extract_result_content_denies_authority_version_and_resource_ids() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "Module runtime metadata recorded.",
        )]),
        Some(json!({
            "primitiveOperation": "module_runtime_request",
            "status": "recorded",
            "moduleRuntime": {
                "moduleRuntimeResourceId": "module_runtime:ok",
                "moduleRuntimeVersionId": "ver_module_runtime_ok",
                "authorityVersionId": "authority_version_secret",
                "authorityResourceId": "authority_resource_secret",
                "nested": {
                    "authorityVersionId": "nested_authority_version_secret",
                    "authorityResourceId": "nested_authority_resource_secret"
                },
                "resourceRefs": [{
                    "resourceId": "module_runtime_ref:ok",
                    "versionId": "ver_module_runtime_ref_ok",
                    "authorityVersionId": "ref_authority_version_secret",
                    "authorityResourceId": "ref_authority_resource_secret"
                }]
            }
        })),
    );

    let CapabilityResultMessageContent::Text(text) = extract_result_content(&exec) else {
        panic!("expected text result");
    };
    assert!(text.contains("module_runtime:ok"));
    assert!(text.contains("ver_module_runtime_ok"));
    assert!(text.contains("module_runtime_ref:ok"));
    assert!(text.contains("ver_module_runtime_ref_ok"));
    assert!(!text.contains("authorityVersionId"));
    assert!(!text.contains("authorityResourceId"));
    assert!(!text.contains("authority_version_secret"));
    assert!(!text.contains("authority_resource_secret"));
    assert!(!text.contains("nested_authority_version_secret"));
    assert!(!text.contains("nested_authority_resource_secret"));
    assert!(!text.contains("ref_authority_version_secret"));
    assert!(!text.contains("ref_authority_resource_secret"));
}

#[test]
fn extract_result_content_drops_authority_containers_before_recursing() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "Module runtime metadata recorded.",
        )]),
        Some(json!({
            "primitiveOperation": "module_runtime_request",
            "status": "recorded",
            "authority": {
                "id": "authority_top_level_secret",
                "resourceId": "authority_top_level_resource_secret",
                "versionId": "authority_top_level_version_secret"
            },
            "moduleRuntime": {
                "moduleRuntimeResourceId": "module_runtime:safe",
                "moduleRuntimeVersionId": "ver_module_runtime_safe",
                "authority": {
                    "id": "authority_nested_secret",
                    "resourceId": "authority_nested_resource_secret",
                    "versionId": "authority_nested_version_secret"
                },
                "resourceRefs": [{
                    "kind": "module_runtime_snapshot",
                    "resourceId": "module_runtime_ref:safe",
                    "versionId": "ver_module_runtime_ref_safe",
                    "authority": {
                        "id": "authority_ref_secret",
                        "resourceId": "authority_ref_resource_secret",
                        "versionId": "authority_ref_version_secret"
                    }
                }]
            }
        })),
    );

    let CapabilityResultMessageContent::Text(text) = extract_result_content(&exec) else {
        panic!("expected text result");
    };
    assert!(text.contains("module_runtime:safe"));
    assert!(text.contains("ver_module_runtime_safe"));
    assert!(text.contains("module_runtime_ref:safe"));
    assert!(text.contains("ver_module_runtime_ref_safe"));
    assert!(!text.contains("\"authority\""));
    assert!(!text.contains("authority_top_level_secret"));
    assert!(!text.contains("authority_top_level_resource_secret"));
    assert!(!text.contains("authority_top_level_version_secret"));
    assert!(!text.contains("authority_nested_secret"));
    assert!(!text.contains("authority_nested_resource_secret"));
    assert!(!text.contains("authority_nested_version_secret"));
    assert!(!text.contains("authority_ref_secret"));
    assert!(!text.contains("authority_ref_resource_secret"));
    assert!(!text.contains("authority_ref_version_secret"));
}
