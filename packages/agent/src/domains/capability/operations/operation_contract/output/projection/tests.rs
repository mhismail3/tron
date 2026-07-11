use super::*;
use crate::shared::protocol::content::CapabilityResultContent;
use crate::shared::protocol::messages::CapabilityResultMessageContent;
use crate::shared::protocol::model_capabilities::{CapabilityResult, CapabilityResultBody};
use serde_json::{Value, json};

fn make_exec_result(content: CapabilityResultBody) -> CapabilityResult {
    make_exec_result_with_details(content, None)
}

fn make_exec_result_with_details(
    content: CapabilityResultBody,
    details: Option<Value>,
) -> CapabilityResult {
    CapabilityResult {
        content,
        details,
        is_error: None,
        stop_turn: None,
    }
}

fn provider_envelope(result: &CapabilityResult) -> Value {
    let CapabilityResultMessageContent::Text(text) = extract_result_content(result) else {
        panic!("canonical provider output must be text-only");
    };
    let envelope: Value = serde_json::from_str(&text).expect("canonical provider envelope parses");
    assert_eq!(
        envelope["schemaVersion"],
        json!("tron.provider_operation_output.v1")
    );
    assert!(envelope["evidence"]["facts"].is_array());
    assert!(envelope["evidence"]["resources"].is_array());
    assert!(envelope["evidence"]["collections"].is_array());
    assert!(envelope["nextActions"].is_array());
    envelope
}

fn fact<'a>(envelope: &'a Value, field: &str) -> &'a Value {
    envelope["evidence"]["facts"]
        .as_array()
        .expect("facts array")
        .iter()
        .find(|fact| fact["field"] == field)
        .unwrap_or_else(|| panic!("missing provider fact `{field}` in {envelope:#}"))
        .get("value")
        .expect("fact value")
}

fn collection<'a>(envelope: &'a Value, field: &str) -> &'a Value {
    envelope["evidence"]["collections"]
        .as_array()
        .expect("collections array")
        .iter()
        .find(|collection| collection["field"] == field)
        .unwrap_or_else(|| panic!("missing provider collection `{field}` in {envelope:#}"))
}

fn item_fact<'a>(item: &'a Value, field: &str) -> &'a Value {
    item["facts"]
        .as_array()
        .expect("item facts array")
        .iter()
        .find(|fact| fact["field"] == field)
        .unwrap_or_else(|| panic!("missing collection item fact `{field}` in {item:#}"))
        .get("value")
        .expect("item fact value")
}

fn envelope_text(envelope: &Value) -> String {
    serde_json::to_string(envelope).expect("serialize canonical provider envelope")
}

#[test]
fn extract_result_content_text_body_passthrough() {
    let exec = make_exec_result(CapabilityResultBody::Text("hello".into()));
    let envelope = provider_envelope(&exec);
    assert_eq!(envelope["operation"], json!("unknown"));
    assert_eq!(envelope["summary"], json!("hello"));
}

#[test]
fn extract_result_content_text_blocks_flatten() {
    let exec = make_exec_result(CapabilityResultBody::Blocks(vec![
        CapabilityResultContent::text("line 1"),
        CapabilityResultContent::text("line 2"),
    ]));
    let envelope = provider_envelope(&exec);
    assert_eq!(envelope["summary"], json!("line 1\nline 2"));
}

#[test]
fn extract_result_content_mixed_blocks_fail_closed_without_inline_media() {
    let exec = make_exec_result(CapabilityResultBody::Blocks(vec![
        CapabilityResultContent::text("screenshot taken"),
        CapabilityResultContent::image("base64data", "image/png"),
    ]));
    let envelope = provider_envelope(&exec);
    assert_eq!(envelope["ok"], json!(false));
    assert_eq!(
        envelope["error"]["code"],
        json!("PROVIDER_OUTPUT_UNCUSTODIED_MEDIA")
    );
    assert!(
        envelope["error"]["message"]
            .as_str()
            .expect("error message")
            .contains("durable media resource refs")
    );
    let text = envelope_text(&envelope);
    assert!(!text.contains("base64data"));
    assert!(!text.contains("image/png"));
}

#[test]
fn extract_model_context_result_text_matches_direct_text() {
    let exec = make_exec_result(CapabilityResultBody::Text("direct output".into()));
    let envelope: Value = serde_json::from_str(&extract_model_context_result_text(&exec))
        .expect("canonical provider envelope parses");
    assert_eq!(envelope["summary"], json!("direct output"));
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

    let envelope = provider_envelope(&exec);
    assert_eq!(envelope["operation"], json!("catalog_search"));
    assert_eq!(fact(&envelope, "primitiveOperation"), "catalog_search");
    let functions = collection(&envelope, "functions");
    let function = &functions["items"][0];
    assert_eq!(item_fact(function, "id"), "logs::recent");
    assert_eq!(
        item_fact(function, "modelFacingInvocation.operation"),
        "log_recent"
    );
}

#[test]
fn extract_result_content_separates_callable_and_effect_excluded_matches() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "Catalog search returned execute operation matches.",
        )]),
        Some(json!({
            "primitiveOperation": "catalog_search",
            "status": "ok",
            "catalogDiscovery": {
                "executeOperationSearch": {
                    "query": "question",
                    "effectClassExcludedMatches": 1
                },
                "executeOperationMatches": [{
                    "operation": "question_inspect",
                    "catalogInspectId": "execute::question_inspect",
                    "arguments": {"operation": "question_inspect"}
                }],
                "allDiscoveredInspectTargets": [{
                    "operation": "question_inspect",
                    "catalogInspectId": "execute::question_inspect",
                    "inspectArguments": {
                        "operation": "catalog_inspect",
                        "kind": "function",
                        "id": "execute::question_inspect"
                    },
                    "invokeArguments": {"operation": "question_inspect"},
                    "excludedFromImmediateInvocation": false
                }, {
                    "operation": "question_answer",
                    "catalogInspectId": "execute::question_answer",
                    "inspectArguments": {
                        "operation": "catalog_inspect",
                        "kind": "function",
                        "id": "execute::question_answer"
                    },
                    "invokeArguments": {"operation": "question_answer"},
                    "excludedFromImmediateInvocation": true
                }],
                "effectClassExcludedOperationMatches": [{
                    "operation": "question_answer",
                    "catalogInspectId": "execute::question_answer",
                    "arguments": {"operation": "question_answer"},
                    "agentUsage": {
                        "operation": "question_answer",
                        "tool": "capability::execute",
                        "arguments": {"operation": "question_answer"},
                        "callable": true,
                        "effect": {
                            "mode": "state_change",
                            "readOnlyInspectionSafe": false
                        }
                    },
                    "exclusionReason": "Supported operation exists but was excluded from immediate invocation by the requested effect class."
                }]
            }
        })),
    );

    let envelope = provider_envelope(&exec);
    let callable = &collection(&envelope, "executeOperationMatches")["items"][0];
    assert_eq!(item_fact(callable, "operation"), "question_inspect");
    assert_eq!(
        item_fact(callable, "catalogInspectId"),
        "execute::question_inspect"
    );

    let excluded = &collection(&envelope, "effectClassExcludedOperationMatches")["items"][0];
    assert_eq!(item_fact(excluded, "operation"), "question_answer");
    assert_eq!(
        item_fact(excluded, "invokeArgumentsOmitted"),
        "excluded_by_active_effect_filter"
    );
    assert_eq!(
        item_fact(excluded, "agentUsage.currentSearchCallable"),
        &json!(false)
    );
    assert_eq!(
        item_fact(excluded, "agentUsage.invokeArgumentsOmitted"),
        "excluded_by_active_effect_filter"
    );
    let text = envelope_text(&envelope);
    assert!(!text.contains("allDiscoveredInspectTargets"));
    assert!(!text.contains("agentUsage.arguments"));
}

#[test]
fn extract_result_content_omits_redundant_supported_operation_directory() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "Catalog search found no operation matches.",
        )]),
        Some(json!({
            "primitiveOperation": "catalog_search",
            "status": "ok",
            "catalogDiscovery": {
                "executeOperationSearch": {
                    "query": "missing_operation",
                    "totalMatches": 0
                },
                "modelFacingGuidance": {
                    "catalogInspect": "inspect",
                    "capabilityExecute": "execute",
                    "operationSearch": "search",
                    "executeSchemaInspection": "schema",
                    "internalDiscovery": "internal",
                    "supportedExecuteOperations": [
                        "catalog_search",
                        "catalog_inspect",
                        "git_status",
                        "trace_list"
                    ],
                    "supportedExecuteOperationsFilter": {
                        "effectClass": "pure_read",
                        "mode": "read_only_inspection_safe",
                        "reason": "Filtered by the active read-only discovery request."
                    }
                }
            }
        })),
    );

    let content = extract_result_content(&exec);

    let CapabilityResultMessageContent::Text(text) = content else {
        panic!("expected text result");
    };
    assert!(!text.contains("modelFacingGuidance"));
    assert!(!text.contains("supportedExecuteOperations"));
    assert!(!text.contains("filesystem_write"));
    assert!(!text.contains("git_commit"));
}

#[test]
fn extract_result_content_projects_catalog_operation_truncation_metadata() {
    let operations = (0..25)
        .map(|index| {
            json!({
                "operation": format!("operation_{index}"),
                "catalogInspectId": format!("execute::operation_{index}"),
                "arguments": {"operation": format!("operation_{index}")}
            })
        })
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
                "executeOperationMatches": operations
            }
        })),
    );

    let envelope = provider_envelope(&exec);
    assert_eq!(fact(&envelope, "executeOperationMatchesOmitted"), 5);
    let matches = collection(&envelope, "executeOperationMatches");
    assert_eq!(matches["total"], json!(20));
    assert_eq!(matches["returned"], json!(12));
    assert_eq!(
        item_fact(&matches["items"][11], "operation"),
        "operation_11"
    );
    let text = envelope_text(&envelope);
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
                    "catalogInspectId": "execute::trace_list",
                    "schemaInspection": {
                        "operation": "catalog_inspect",
                        "tool": "capability::execute",
                        "arguments": {
                            "operation": "catalog_inspect",
                            "kind": "function",
                            "id": "execute::trace_list",
                            "maxSchemaBytes": 8000
                        },
                        "readOnlyInspectionSafe": true
                    },
                    "matchKind": "exact",
                    "score": 10,
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

    let envelope = provider_envelope(&exec);
    let item = &collection(&envelope, "executeOperationMatches")["items"][0];
    assert_eq!(item_fact(item, "operation"), "trace_list");
    assert_eq!(item_fact(item, "catalogInspectId"), "execute::trace_list");
    assert_eq!(item_fact(item, "score"), 10);
    assert_eq!(
        item_fact(item, "agentUsage.defaultUse"),
        "diagnose_or_verify"
    );
    assert_eq!(
        item_fact(item, "capabilityPool.replacementClass"),
        "kernel_evolution_only"
    );
    assert_eq!(
        item_fact(item, "agentUsage.effect.readOnlyInspectionSafe"),
        &json!(true)
    );
    assert_eq!(
        item_fact(item, "agentUsage.effect.readOnlyInstruction"),
        "safe to call during read-only inspection"
    );
    assert_eq!(
        envelope["nextActions"][0]["operation"],
        json!("catalog_inspect")
    );
}

#[test]
fn extract_result_content_projects_git_status_evidence_for_agent() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "git_status ok: . on main clean (staged 0, unstaged 0, untracked 0, conflicted 0; porcelain empty; refs 0; truncated false)",
        )]),
        Some(json!({
            "primitiveOperation": "git_status",
            "status": "ok",
            "git": {
                "schemaVersion": "tron.git.v1",
                "status": "ok",
                "operation": "status",
                "path": {"relativePath": "."},
                "repository": {
                    "repositoryRoot": {
                        "root": "working_directory",
                        "relativePath": "."
                    },
                    "branch": "main",
                    "detachedHead": false,
                    "hasUpstream": false,
                    "ahead": 0,
                    "behind": 0,
                    "headOid": "should_not_be_required_for_summary",
                    "indexTreeTruncated": false,
                    "indexTreeOidUnavailable": false
                },
                "dirty": false,
                "summary": {
                    "stagedCount": 0,
                    "unstagedCount": 0,
                    "untrackedCount": 0,
                    "conflictedCount": 0
                },
                "evidence": {
                    "statusPorcelainV1Z": "",
                    "statusTruncated": false,
                    "statusLimitBytes": 20000,
                    "resourceRefs": []
                }
            }
        })),
    );

    let envelope = provider_envelope(&exec);
    assert_eq!(envelope["operation"], json!("git_status"));
    assert_eq!(fact(&envelope, "primitiveOperation"), "git_status");
    assert_eq!(fact(&envelope, "git.branch"), "main");
    assert_eq!(fact(&envelope, "git.dirty"), &json!(false));
    assert_eq!(fact(&envelope, "git.summary.stagedCount"), 0);
    assert_eq!(
        fact(&envelope, "git.evidence.statusPorcelainEmpty"),
        &json!(true)
    );
    assert_eq!(
        fact(&envelope, "git.evidence.statusTruncated"),
        &json!(false)
    );
    assert_eq!(fact(&envelope, "git.relativePath"), ".");
    assert!(!envelope_text(&envelope).contains("statusPorcelainV1Z"));
}

#[test]
fn extract_result_content_projects_compact_catalog_next_step() {
    let oversized_durable_plan = "x".repeat(30_000);
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "Catalog search returned 5 execute operation match(es).",
        )]),
        Some(json!({
            "primitiveOperation": "catalog_search",
            "status": "ok",
            "catalogDiscovery": {
                "summary": {"functions": {"visible": 0}},
                "functions": [],
                "executeOperationSearch": "git_status replacement readiness shadow trial route binding evidence",
                "executeOperationMatches": [{
                    "operation": "git_status",
                    "tool": "capability::execute",
                    "arguments": {"operation": "git_status"},
                    "matchKind": "intent",
                    "score": 18,
                    "capabilityPool": {
                        "surface": "agent_operation",
                        "audience": "session_work",
                        "replacementClass": "runtime_routable"
                    }
                }],
                "agentNextStep": {
                    "priority": "follow_primary_inspection",
                    "reason": "Inspect the exact target row.",
                    "primaryInspection": {
                        "operation": "capability_binding_cockpit_overview",
                        "arguments": {
                            "operation": "capability_binding_cockpit_overview",
                            "targetOperation": "git_status"
                        },
                        "readOnlyInspectionSafe": true,
                        "reason": "Inspect replacement, binding, route, shadow, rollback, and evidence state for the exact target operation."
                    },
                    "thenFollow": "target.agentPath",
                    "completionRule": "If the targeted cockpit row reports zero candidates, zero active routes, and zero shadow-trial runs for the current scope, answer that no current-scope replacement evidence exists instead of searching unsupported list names."
                },
                "agentSearchPlan": {
                    "contextualWriteOperations": [{
                        "operation": "must_not_project",
                        "schema": {"large": oversized_durable_plan}
                    }]
                },
                "unsupportedOperationCandidate": true,
                "unsupportedOperationRecovery": {
                    "query": "capability_shadow_trial_request_list",
                    "canonicalQuery": "capability_shadow_trial_request_list",
                    "supportedOperation": false,
                    "guidance": "Do not call the queried name.",
                    "closestReadOnlyAlternatives": [{
                        "operation": "capability_binding_cockpit_overview",
                        "tool": "capability::execute",
                        "arguments": {
                            "operation": "capability_binding_cockpit_overview",
                            "targetOperation": "git_status"
                        },
                        "readOnlyInspectionSafe": true,
                        "reason": "Inspect readiness for the exact operation.",
                        "agentUsage": {
                            "preflight": {
                                "authorityScopes": ["must_not_project"],
                                "resourceSelectors": ["must_not_project"]
                            }
                        }
                    }]
                }
            }
        })),
    );

    let envelope = provider_envelope(&exec);
    let match_item = &collection(&envelope, "executeOperationMatches")["items"][0];
    assert_eq!(item_fact(match_item, "operation"), "git_status");
    assert_eq!(item_fact(match_item, "score"), 18);
    let actions = envelope["nextActions"].as_array().expect("next actions");
    assert!(actions.iter().any(|action| {
        action["source"] == "agentNextStep"
            && action["summary"].as_str().is_some_and(|summary| {
                summary.contains("capability_binding_cockpit_overview")
                    && summary.contains("targetOperation")
                    && summary.contains("git_status")
            })
    }));
    assert!(actions.iter().any(|action| {
        action["summary"]
            .as_str()
            .is_some_and(|summary| summary.contains("no current-scope replacement evidence exists"))
    }));
    let text = envelope_text(&envelope);
    assert!(text.contains("Do not call the queried name"));
    assert!(text.contains("Inspect readiness for the exact operation"));
    assert!(!text.contains("agentSearchPlan"));
    assert!(!text.contains("contextualWriteOperations"));
    assert!(!text.contains("must_not_project"));
    assert!(!text.contains("authorityScopes"));
    assert!(!text.contains("resourceSelectors"));
    assert!(
        text.len() < 16_000,
        "catalog search projection must fit the provider tool-result boundary: {} bytes",
        text.len()
    );
}

#[test]
fn extract_result_content_projects_catalog_execute_operation_inspect_schema() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "Catalog execute_operation inspected: execute::capability_shadow_trial_evidence_inspect.",
        )]),
        Some(json!({
            "primitiveOperation": "catalog_inspect",
            "status": "ok",
            "catalogDiscovery": {
                "kind": "execute_operation",
                "id": "execute::capability_shadow_trial_evidence_inspect",
                "aliasResolvedFrom": "execute::capability_shadow_trial_evidence_inspect",
                "operation": "capability_shadow_trial_evidence_inspect",
                "summary": "Provider-visible capability::execute operation capability_shadow_trial_evidence_inspect.",
                "providerCallable": true,
                "inputSchema": {
                    "type": "object",
                    "required": ["operation", "capabilityShadowTrialEvidenceResourceId"],
                    "properties": {
                        "operation": {
                            "type": "string",
                            "const": "capability_shadow_trial_evidence_inspect"
                        },
                        "capabilityShadowTrialEvidenceResourceId": {
                            "type": "string"
                        }
                    },
                    "schemaCompleteness": "operation_specific_contract"
                },
                "outputSchema": {
                    "type": "object",
                    "required": ["content", "details"],
                    "schemaCompleteness": "operation_specific_contract"
                },
                "modelFacingInvocation": {
                    "tool": "capability::execute",
                    "operation": "capability_shadow_trial_evidence_inspect",
                    "arguments": {"operation": "capability_shadow_trial_evidence_inspect"}
                },
                "capabilityPool": {
                    "surface": "agent_operation",
                    "audience": "governance",
                    "replacementClass": "kernel_evolution_only"
                },
                "agentUsage": {
                    "callable": true,
                    "tool": "capability::execute",
                    "operation": "capability_shadow_trial_evidence_inspect",
                    "effect": {
                        "mode": "read_only",
                        "readOnlyInspectionSafe": true
                    },
                    "preflight": {
                        "authorityScopes": ["capability_binding.read", "resource.read"],
                        "resourceSelectors": ["kind:capability_shadow_trial_evidence"],
                        "networkPolicy": "none"
                    }
                },
                "schema": {
                    "tool": "capability::execute",
                    "operation": "capability_shadow_trial_evidence_inspect",
                    "requiredPayloadFields": ["operation", "capabilityShadowTrialEvidenceResourceId"],
                    "payloadPlacement": "Put operation-specific fields at the top level of the capability::execute payload.",
                    "inputSchema": {
                        "type": "object",
                        "required": ["operation", "capabilityShadowTrialEvidenceResourceId"],
                        "schemaCompleteness": "operation_specific_contract"
                    },
                    "outputSchema": {
                        "type": "object",
                        "required": ["content", "details"],
                        "schemaCompleteness": "operation_specific_contract"
                    }
                }
            }
        })),
    );

    let envelope = provider_envelope(&exec);
    assert_eq!(fact(&envelope, "kind"), "execute_operation");
    assert_eq!(
        fact(&envelope, "operation"),
        "capability_shadow_trial_evidence_inspect"
    );
    assert_eq!(fact(&envelope, "providerCallable"), &json!(true));
    assert_eq!(
        fact(&envelope, "capabilityPool.replacementClass"),
        "kernel_evolution_only"
    );
    assert_eq!(
        fact(&envelope, "schema.payloadPlacement"),
        "Put operation-specific fields at the top level of the capability::execute payload."
    );
    let text = envelope_text(&envelope);
    assert!(text.contains("capabilityShadowTrialEvidenceResourceId"));
    assert!(text.contains("inputSchema"));
    assert!(text.contains("outputSchema"));
    assert!(text.contains("operation_specific_contract"));
    assert!(text.contains("capability_binding.read"));
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
                        },
                        "binding": {
                            "requested": 0,
                            "approved": 0,
                            "rejected": 0,
                            "activePolicies": 0,
                            "failedReplacementAttempts": 0,
                            "latestState": "none",
                            "detail": "No binding requests have been recorded for this operation."
                        },
                        "shadowTrial": {
                            "requested": 0,
                            "approved": 0,
                            "rejected": 0,
                            "runs": 0,
                            "passed": 0,
                            "failed": 0,
                            "availableForThisOperation": true,
                            "latestState": "none",
                            "detail": "No shadow trial runs have been recorded for this operation."
                        },
                        "route": {
                            "candidates": 0,
                            "bindings": 0,
                            "activeRoutes": 0,
                            "routeEvents": 0,
                            "failedClosed": 0,
                            "rolledBack": 0,
                            "rollbackAvailable": false,
                            "disableAvailable": false,
                            "state": "built_in",
                            "label": "Built-in route",
                            "detail": "No runtime route is active for this operation."
                        },
                        "rollback": {
                            "available": false,
                            "disableAvailable": false,
                            "abortAvailable": false,
                            "boundary": "No active replacement rollback is available yet.",
                            "detail": "Rollback appears after a governed route activates."
                        },
                        "agentPath": {
                            "purpose": "Inspect replacement readiness for git_status without invoking the adapter.",
                            "adapterExecutionGuidance": "Do not call git_status merely to inspect replacement readiness.",
                            "evidenceGuidance": "If counts are zero, say no current-scope replacement evidence exists instead of searching unsupported list names.",
                            "primaryInspection": {
                                "operation": "capability_binding_cockpit_overview",
                                "payload": {
                                    "operation": "capability_binding_cockpit_overview",
                                    "targetOperation": "git_status",
                                    "limit": 1
                                },
                                "readOnlyInspectionSafe": true,
                                "reason": "Return the exact operation row with replacement, binding, route, shadow, rollback, and evidence state."
                            },
                            "readOnlySequence": [{
                                "label": "List replacement candidates",
                                "operation": "capability_replacement_candidate_list",
                                "payload": {
                                    "operation": "capability_replacement_candidate_list",
                                    "targetOperation": "git_status",
                                    "networkPolicy": "none"
                                },
                                "readOnlyInspectionSafe": true,
                                "reason": "Inspect candidate records for this operation only."
                            }],
                            "unavailableSurfaces": [{
                                "operation": "capability_shadow_trial_request_list",
                                "reason": "This is not a supported operation.",
                                "alternative": "Use capability_binding_cockpit_overview targetOperation and supported evidence inspect operations."
                            }]
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

    let envelope = provider_envelope(&exec);
    assert_eq!(
        fact(&envelope, "summary.title"),
        "Capability ownership visible"
    );
    assert_eq!(fact(&envelope, "coverage.missingCapabilityPool"), 0);
    assert_eq!(fact(&envelope, "coverage.missingAgentUsage"), 0);
    assert_eq!(fact(&envelope, "operationDirectory.total"), 5);
    assert_eq!(
        fact(&envelope, "operationDirectory.detailPolicy"),
        "broad directory is compact; call capability_binding_cockpit_overview with targetOperation for one exact operation when detailed readiness, preflight, binding, shadow, route, rollback, or agentPath data is needed"
    );
    let operations = collection(&envelope, "operationDirectory.operations");
    assert_eq!(operations["returned"], json!(5));
    let names = operations["items"]
        .as_array()
        .expect("operation items")
        .iter()
        .map(|item| item_fact(item, "name").as_str().expect("operation name"))
        .collect::<Vec<_>>();
    assert_eq!(
        names,
        vec![
            "git_status",
            "trace_list",
            "capability_binding_cockpit_overview",
            "capability_binding_request_list",
            "capability_shadow_trial_request_record"
        ]
    );
    assert_eq!(
        item_fact(&operations["items"][0], "capabilityPool.replacementClass"),
        "runtime_routable"
    );
    assert_eq!(
        item_fact(&operations["items"][1], "capabilityPool.replacementClass"),
        "kernel_evolution_only"
    );
    assert_eq!(
        item_fact(&operations["items"][0], "detailNextStep.operation"),
        "capability_binding_cockpit_overview"
    );
    assert_eq!(
        item_fact(
            &operations["items"][0],
            "agentUsage.effect.readOnlyInspectionSafe"
        ),
        &json!(true)
    );
    assert_eq!(
        item_fact(
            &operations["items"][4],
            "agentUsage.effect.readOnlyInstruction"
        ),
        "do not call during read-only inspection; inspect schema/catalog/list operations instead"
    );
    for operation in operations["items"].as_array().expect("operation items") {
        assert!(
            operation["facts"]
                .as_array()
                .expect("operation facts")
                .iter()
                .all(|fact| !fact["field"]
                    .as_str()
                    .expect("fact field")
                    .starts_with("agentPath")),
            "broad cockpit must omit detailed agentPath fields: {operation:#}"
        );
    }
    let text = envelope_text(&envelope);
    for excluded in [
        "requiredPayloadFields",
        "capability_binding.read",
        "kind:capability_binding_request",
        "kind:capability_shadow_trial_request",
        "primaryInspection",
        "capability_replacement_candidate_list",
        "capability_shadow_trial_request_list",
        "authorityGrantId",
        "grant_must_not_project",
        "nested_grant_must_not_project",
    ] {
        assert!(
            !text.contains(excluded),
            "broad cockpit leaked `{excluded}`"
        );
    }
}

#[test]
fn extract_result_content_keeps_targeted_capability_cockpit_agent_path() {
    let oversized_pre_cockpit_path = "x".repeat(30_000);
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "Targeted cockpit for git_status.",
        )]),
        Some(json!({
            "primitiveOperation": "capability_binding_cockpit_overview",
            "status": "ok",
            "capabilityBinding": {
                "summary": {
                    "title": "Capability ownership visible",
                    "totalOperations": 188,
                    "returnedOperations": 1
                },
                "operationList": {
                    "complete": true,
                    "returnedOperations": 1,
                    "totalOperations": 188,
                    "targetOperation": "git_status",
                    "filterApplied": true
                },
                "target": {
                    "name": "git_status",
                    "family": "git",
                    "familyLabel": "Git",
                    "capabilityPool": {
                        "surface": "agent_operation",
                        "audience": "session_work",
                        "replacementClass": "runtime_routable"
                    },
                    "agentUsage": {
                        "tool": "capability::execute",
                        "operation": "git_status",
                        "arguments": {"operation": "git_status"},
                        "callable": true,
                        "preflight": {
                            "requiredPayloadFields": ["operation"],
                            "authorityScopes": ["git.read"],
                            "authorityGrantId": "targeted_grant_must_not_project"
                        }
                    },
                    "shadowTrial": {
                        "runs": 1,
                        "evidenceInspectReady": true,
                        "evidenceRefs": [{
                            "resourceId": "capability_shadow_trial_evidence:test",
                            "inspectOperation": "capability_shadow_trial_evidence_inspect",
                            "inspectPayload": {
                                "operation": "capability_shadow_trial_evidence_inspect",
                                "capabilityShadowTrialEvidenceResourceId": "capability_shadow_trial_evidence:test"
                            }
                        }],
                        "detail": "must_not_project_shadow_detail"
                    },
                    "agentPath": {
                        "purpose": "Inspect replacement readiness for git_status without invoking the adapter.",
                        "primaryInspection": {
                            "operation": "capability_binding_cockpit_overview",
                            "payload": {
                                "operation": "capability_binding_cockpit_overview",
                                "targetOperation": "git_status"
                            },
                            "readOnlyInspectionSafe": true,
                            "reason": "Exact operation row."
                        },
                        "readOnlySequence": [{
                            "operation": "must_not_project",
                            "reason": oversized_pre_cockpit_path
                        }],
                        "completion": {
                            "state": "answer_now_no_current_scope_evidence",
                            "action": "stop_after_targeted_cockpit",
                            "readOnlyBoundary": {
                                "capabilityRequestedMutation": false,
                                "engineAuditPersistence": true,
                                "requiredFinalAnswerSuffix": "capabilityRequestedMutation=false; engineAuditPersistence=true"
                            },
                            "governedNextSteps": [{
                                "order": 1,
                                "operation": "capability_replacement_candidate_record"
                            }]
                        }
                    }
                }
            }
        })),
    );

    let envelope = provider_envelope(&exec);
    assert_eq!(fact(&envelope, "coverage.operationsReturned"), 1);
    assert_eq!(fact(&envelope, "operationDirectory.returned"), 1);
    let target = &collection(&envelope, "operationDirectory.operations")["items"][0];
    assert_eq!(item_fact(target, "name"), "git_status");
    assert_eq!(
        item_fact(target, "agentPath.completion.state"),
        "answer_now_no_current_scope_evidence"
    );
    assert_eq!(
        item_fact(
            target,
            "agentPath.completion.readOnlyBoundary.requiredFinalAnswerSuffix"
        ),
        "capabilityRequestedMutation=false; engineAuditPersistence=true"
    );
    assert_eq!(
        item_fact(target, "agentPath.completion.governedNextSteps"),
        "1 item(s)"
    );
    assert_eq!(
        item_fact(target, "agentUsage.preflight.requiredPayloadFields"),
        "1 item(s)"
    );
    assert_eq!(
        item_fact(target, "agentUsage.preflight.authorityScopes"),
        "1 item(s)"
    );
    assert_eq!(item_fact(target, "shadowTrial.evidenceRefs"), "1 item(s)");
    let text = envelope_text(&envelope);
    assert!(!text.contains("primaryInspection"));
    assert!(!text.contains("readOnlySequence"));
    assert!(!text.contains("must_not_project"));
    assert!(!text.contains("must_not_project_shadow_detail"));
    assert!(
        text.len() < 16_000,
        "targeted cockpit projection must fit provider output: {} bytes",
        text.len()
    );
    assert!(!text.contains("authorityGrantId"));
    assert!(!text.contains("targeted_grant_must_not_project"));
}

#[test]
fn extract_result_content_projects_context_action_list_inspect_arguments() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "Listed 1 context-control action(s).",
        )]),
        Some(json!({
            "primitiveOperation": "context_control_action_list",
            "status": "ok",
            "contextControl": {
                "operation": "context_control_action_list",
                "schemaVersion": "tron.context_control_action.v1",
                "sessionId": "sess_context_projection",
                "projection": {
                    "limit": 10,
                    "providerSafe": true,
                    "actions": [{
                        "actionId": "compact-model-capability-invocation:v1:abc",
                        "actorKind": "agent",
                        "createdAt": "2026-07-09T00:00:00Z",
                        "kind": "compact",
                        "reason": "verify inspectable action refs",
                        "resource": {
                            "kind": "context_control_action",
                            "lifecycle": "succeeded",
                            "resourceId": "context_control_action:abc",
                            "resourceKind": "context_control_action",
                            "versionId": "ver_context_action_abc",
                            "authorityGrantId": "grant_must_not_project"
                        },
                        "resultStatus": "succeeded",
                        "state": "succeeded",
                        "updatedAt": "2026-07-09T00:00:01Z"
                    }]
                },
                "authorityGrantId": "grant_top_level_must_not_project"
            }
        })),
    );

    let envelope = provider_envelope(&exec);
    assert_eq!(
        fact(&envelope, "agentNextStep.inspectOperation"),
        "context_control_action_inspect"
    );
    assert_eq!(
        fact(&envelope, "agentNextStep.argumentField"),
        "contextControlActionResourceId"
    );
    let action = &collection(&envelope, "actions.items")["items"][0];
    assert_eq!(
        item_fact(action, "contextControlActionResourceId"),
        "context_control_action:abc"
    );
    assert_eq!(
        item_fact(action, "inspectArguments.operation"),
        "context_control_action_inspect"
    );
    assert_eq!(
        item_fact(action, "inspectArguments.contextControlActionResourceId"),
        "context_control_action:abc"
    );
    assert_eq!(
        item_fact(action, "resource.resourceId"),
        "context_control_action:abc"
    );
    assert_eq!(
        item_fact(action, "resource.versionId"),
        "ver_context_action_abc"
    );
    let text = envelope_text(&envelope);
    assert!(!text.contains("compact-model-capability-invocation:v1:abc"));
    assert!(!text.contains("actionId"));
    assert!(!text.contains("grant_must_not_project"));
    assert!(!text.contains("grant_top_level_must_not_project"));
    assert!(!text.contains("authorityGrantId"));
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

    let envelope = provider_envelope(&exec);
    assert_eq!(
        fact(&envelope, "procedural.proceduralRecordResourceId"),
        "procedural_record:abc123"
    );
    assert_eq!(
        fact(&envelope, "procedural.proceduralRecordVersionId"),
        "ver_abc123"
    );
    assert_eq!(
        fact(&envelope, "procedural.summary"),
        "Bounded metadata summary"
    );
    let text = envelope_text(&envelope);
    assert!(!text.contains("must not be projected"));
    assert!(!text.contains("nested raw object"));
    assert!(!text.contains("grant_secret"));
    assert!(!text.contains("authorityGrantId"));
}

#[test]
fn extract_result_content_projects_goal_question_next_call_arguments() {
    let goal_exec = make_exec_result_with_details(
        CapabilityResultBody::Text("Goal list returned.".into()),
        Some(json!({
            "primitiveOperation": "goal_list",
            "status": "ok",
            "goals": [{
                "goalResourceId": "goal:abc123",
                "goalVersionId": "ver_goal_abc123",
                "state": "open",
                "summary": "Bounded test goal",
                "summaryTruncated": false,
                "revision": 1,
                "resourceRefs": [{"kind": "goal", "resourceId": "goal:abc123"}],
                "authorityGrantId": "grant_must_not_project"
            }],
            "authorityGrantId": "grant_top_level_must_not_project"
        })),
    );

    let goal_envelope = provider_envelope(&goal_exec);
    let goal = &collection(&goal_envelope, "agentInspectableGoals.items")["items"][0];
    assert_eq!(
        item_fact(goal, "inspectArguments.operation"),
        "goal_inspect"
    );
    assert_eq!(
        item_fact(goal, "inspectArguments.goalResourceId"),
        "goal:abc123"
    );
    assert_eq!(
        item_fact(goal, "cancelArgumentsBase.operation"),
        "goal_cancel"
    );
    assert_eq!(
        item_fact(goal, "cancelArgumentsBase.goalResourceId"),
        "goal:abc123"
    );
    assert_eq!(
        item_fact(goal, "cancelRequiredAdditionalFields"),
        "2 item(s)"
    );
    let goal_text = envelope_text(&goal_envelope);
    assert!(!goal_text.contains("grant_must_not_project"));
    assert!(!goal_text.contains("grant_top_level_must_not_project"));
    assert!(!goal_text.contains("authorityGrantId"));

    let question_exec = make_exec_result_with_details(
        CapabilityResultBody::Text("Question list returned.".into()),
        Some(json!({
            "primitiveOperation": "question_list",
            "status": "ok",
            "questions": [{
                "questionResourceId": "user_question:def456",
                "questionVersionId": "ver_question_def456",
                "state": "pending",
                "summary": "Bounded question summary",
                "summaryTruncated": false,
                "prompt": "raw prompt body must not be projected",
                "revision": 1,
                "resourceRefs": [{"kind": "user_question", "resourceId": "user_question:def456"}]
            }]
        })),
    );

    let question_envelope = provider_envelope(&question_exec);
    let question = &collection(&question_envelope, "agentInspectableQuestions.items")["items"][0];
    assert_eq!(
        item_fact(question, "inspectArguments.operation"),
        "question_inspect"
    );
    assert_eq!(
        item_fact(question, "inspectArguments.questionResourceId"),
        "user_question:def456"
    );
    assert_eq!(
        item_fact(question, "answerArgumentsBase.operation"),
        "question_answer"
    );
    assert_eq!(
        item_fact(question, "answerArgumentsBase.expectedQuestionVersionId"),
        "ver_question_def456"
    );
    assert_eq!(
        item_fact(question, "answerRequiredAdditionalFields"),
        "3 item(s)"
    );
    let question_text = envelope_text(&question_envelope);
    assert!(!question_text.contains("raw prompt body"));
    assert!(!question_text.contains("\"prompt\""));
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

    let envelope = provider_envelope(&exec);
    assert_eq!(
        fact(&envelope, "operation"),
        "capability_binding_request_list"
    );
    let request = &collection(&envelope, "capabilityBinding.bindingRequests.items")["items"][0];
    assert_eq!(
        item_fact(request, "resourceId"),
        "capability_binding_request:first"
    );
    assert_eq!(item_fact(request, "versionId"), "ver_binding_request_first");
    assert_eq!(item_fact(request, "targetOperation"), "git_status");
    assert_eq!(item_fact(request, "ownershipClass"), "adapter_replaceable");
    assert_eq!(item_fact(request, "replacementClass"), "runtime_routable");
    assert_eq!(item_fact(request, "bindingMode"), "shadow");
    let text = envelope_text(&envelope);
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
            "projectionBoundary": {
                "providerVisibleProjection": true
            },
            "statusSummary": {
                "totalRecords": 1
            },
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

    let envelope = provider_envelope(&exec);
    let record = &collection(&envelope, "records")["items"][0];
    assert_eq!(item_fact(record, "id"), "019f-trace-record");
    assert_eq!(item_fact(record, "traceId"), "trace_nested");
    assert_eq!(item_fact(record, "invocationId"), "inv_nested");
    assert_eq!(
        item_fact(record, "operation"),
        "procedural_definition_record"
    );
    assert_eq!(item_fact(record, "error.code"), "ENGINE_SCHEMA_VIOLATION");
    assert_eq!(item_fact(record, "error.details.path"), "$.field");
    assert!(
        item_fact(record, "error.message")
            .as_str()
            .expect("redacted error message")
            .contains("[redacted-path]")
    );
    let text = envelope_text(&envelope);
    assert!(!text.contains("grant_must_not_project"));
    assert!(!text.contains("authorityGrantId"));
    assert!(!text.contains("provider_nested"));
    assert!(!text.contains("providerInvocationId"));
    assert!(!text.contains("/Users/example"));
    assert!(!text.contains("cat hidden"));
}

#[test]
fn extract_result_content_projects_trace_projection_proof_for_agent() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "Trace records: 1. Each details.records[] item includes projectionBoundary and redaction booleans proving this per record.",
        )]),
        Some(json!({
            "primitiveOperation": "trace_list",
            "status": "ok",
            "projectionBoundary": {
                "providerVisibleProjection": true,
                "safeEngineRefsOnly": true,
                "rawAuditFieldsProjected": false,
                "traceGetUse": "Use trace_get only for one focused trace record."
            },
            "statusSummary": {
                "totalRecords": 1,
                "okCount": 1,
                "failedCount": 0,
                "inProgressCount": 0
            },
            "records": [{
                "id": "019f-safe-record",
                "traceId": "trace_safe",
                "invocationId": "inv_safe",
                "modelPrimitiveName": "execute",
                "operation": "trace_list",
                "status": "ok",
                "sessionRef": "sess_safe",
                "workspaceRef": "workspace_safe",
                "request": {
                    "hash": "request_hash_safe",
                    "rawStoredInProjection": false
                },
                "result": {
                    "hash": "result_hash_safe",
                    "rawStoredInProjection": false
                },
                "projectionBoundary": {
                    "providerVisibleProjection": true,
                    "safeEngineRefsOnly": true,
                    "rawAuditFieldsProjected": false,
                    "internalAuditStorageMayRetainRawAuditFields": true
                },
                "authority": {
                    "actorKind": "model",
                    "scopeCount": 2,
                    "rawActorIdStored": false,
                    "rawAuthorityGrantIdStored": false,
                    "rawIdempotencyKeyStored": false
                },
                "redaction": {
                    "rawAuthorityIdsExcluded": true,
                    "rawGrantIdsExcluded": true,
                    "rawIdempotencyKeysExcluded": true,
                    "rawProviderInvocationIdsExcluded": true,
                    "rawWorkingDirectoryExcluded": true,
                    "rawRequestExcluded": true,
                    "rawResultExcluded": true,
                    "rawFilesExcluded": true,
                    "rawVcsExcluded": true
                },
                "metadata": {
                    "dev.tron": {
                        "providerInvocationId": "provider_must_not_project",
                        "authority": {
                            "authorityGrantId": "grant_must_not_project"
                        },
                        "workingDirectory": "/Users/example/private"
                    }
                }
            }]
        })),
    );

    let envelope = provider_envelope(&exec);
    assert_eq!(
        fact(&envelope, "projectionBoundary.rawAuditFieldsProjected"),
        &json!(false)
    );
    assert_eq!(fact(&envelope, "statusSummary.failedCount"), 0);
    assert_eq!(
        fact(&envelope, "projectionBoundary.traceGetUse"),
        "Use trace_get only for one focused trace record."
    );
    let record = &collection(&envelope, "records")["items"][0];
    assert_eq!(
        item_fact(record, "redaction.rawProviderInvocationIdsExcluded"),
        &json!(true)
    );
    assert_eq!(
        item_fact(record, "request.rawStoredInProjection"),
        &json!(false)
    );
    assert_eq!(item_fact(record, "request.hash"), "request_hash_safe");
    assert_eq!(item_fact(record, "result.hash"), "result_hash_safe");
    assert_eq!(
        item_fact(record, "authority.rawAuthorityGrantIdStored"),
        &json!(false)
    );
    assert_eq!(item_fact(record, "authority.scopeCount"), 2);
    let text = envelope_text(&envelope);
    assert!(!text.contains("provider_must_not_project"));
    assert!(!text.contains("providerInvocationId"));
    assert!(!text.contains("grant_must_not_project"));
    assert!(!text.contains("authorityGrantId"));
    assert!(!text.contains("/Users/example"));
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

    let envelope = provider_envelope(&exec);
    let entry = &collection(&envelope, "entries")["items"][0];
    assert_eq!(
        item_fact(entry, "message"),
        "Unknown event type: capability.invocation.arguments_delta"
    );
    assert_eq!(item_fact(entry, "sessionId"), "sess_1");
    assert_eq!(item_fact(entry, "traceId"), "trace_1");
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

    let envelope = provider_envelope(&exec);
    assert_eq!(envelope["ok"], json!(true));
    assert!(!envelope_text(&envelope).contains("raw diagnostic payload"));
}

#[test]
fn extract_result_content_does_not_project_runtime_process_identifiers() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "job_start running: job_process:test",
        )]),
        Some(json!({
            "primitiveOperation": "job_start",
            "status": "running",
            "jobs": {
                "jobResourceId": "job_process:test",
                "jobVersionId": "ver_test",
                "processId": 70033,
                "processGroupId": 70033,
                "pid": 70033,
                "resourceRefs": [{
                    "kind": "job_process",
                    "resourceId": "job_process:test",
                    "versionId": "ver_test"
                }]
            }
        })),
    );

    let envelope = provider_envelope(&exec);
    let text = envelope_text(&envelope);

    assert!(text.contains("job_process:test"));
    assert!(!text.contains("70033"));
    assert!(!text.contains("processId"));
    assert!(!text.contains("processGroupId"));
    assert!(!text.contains("\"pid\""));
}

#[test]
fn extract_result_content_projects_canonical_metadata_without_an_operation_allowlist() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "Listed 1 web source record.",
        )]),
        Some(json!({
            "primitiveOperation": "web_source_list",
            "status": "ok",
            "sources": [{
                "kind": "web_source_record",
                "status": "active",
                "summary": "Provider-safe source evidence",
                "absolutePath": "/Users/example/private/source.html",
                "authorityGrantId": "grant_secret"
            }]
        })),
    );

    let CapabilityResultMessageContent::Text(text) = extract_result_content(&exec) else {
        panic!("expected text result");
    };
    assert!(text.contains("web_source_list"));
    assert!(text.contains("Provider-safe source evidence"));
    assert!(text.contains("web_source_record"));
    assert!(!text.contains("/Users/example/private/source.html"));
    assert!(!text.contains("grant_secret"));
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
