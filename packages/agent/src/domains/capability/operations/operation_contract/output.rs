//! Canonical provider-visible result contracts for `capability::execute`.
//!
//! Operation-specific schemas describe only bounded, redacted result fields
//! that the provider may consume. All other registered operations use the
//! same minimal provider-safe envelope. Unknown operation names fail closed.

use serde_json::{Value, json};

use super::OperationId;

pub(super) fn output_schema(operation: &str) -> Option<Value> {
    if OperationId::parse(operation).is_none() {
        return None;
    }

    Some(match operation {
        "git_status" => git_status_output_schema(),
        "web_robots_check" => web_robots_check_output_schema(),
        "web_fetch" => web_fetch_output_schema(),
        "job_status" | "job_list" => job_lifecycle_output_schema(operation),
        "job_log" => job_log_output_schema(),
        "trace_list" => trace_list_output_schema(),
        "trace_get" => trace_get_output_schema(),
        _ => generic_provider_safe_output_schema(operation),
    })
}

fn generic_provider_safe_output_schema(operation: &str) -> Value {
    json!({
        "type": "object",
        "required": ["content", "details"],
        "properties": {
            "content": {
                "description": "Provider-safe text summary of the operation result."
            },
            "details": {
                "type": "object",
                "description": "Bounded provider-safe evidence for the operation result.",
                "properties": {
                    "primitiveOperation": {"const": operation},
                    "status": {"type": "string"}
                }
            }
        },
        "schemaCompleteness": "operation_specific_contract"
    })
}

fn git_status_output_schema() -> Value {
    json!({
        "type": "object",
        "required": ["content", "details"],
        "properties": {
            "content": {
                "description": "Provider-safe text summary of repository status."
            },
            "details": {
                "type": "object",
                "description": "Bounded provider-safe git status evidence. Absolute paths, raw commands, raw logs, grants, and authority ids are excluded.",
                "required": ["primitiveOperation", "status", "git"],
                "properties": {
                    "primitiveOperation": {"const": "git_status"},
                    "status": {"type": "string"},
                    "git": {
                        "type": "object",
                        "required": ["schemaVersion", "status", "operation", "summary", "repository", "evidence"],
                        "properties": {
                            "schemaVersion": {"const": "tron.git_readonly.v1"},
                            "status": {"type": "string"},
                            "operation": {"const": "status"},
                            "summary": {
                                "type": "object",
                                "properties": {
                                    "stagedCount": {"type": "integer"},
                                    "unstagedCount": {"type": "integer"},
                                    "untrackedCount": {"type": "integer"},
                                    "conflictedCount": {"type": "integer"}
                                }
                            },
                            "repository": {
                                "type": "object",
                                "description": "Provider-safe repository facts using workspace-relative path refs.",
                                "properties": {
                                    "branch": {"type": ["string", "null"]},
                                    "detachedHead": {"type": "boolean"},
                                    "headOid": {"type": ["string", "null"]},
                                    "headTreeOid": {"type": ["string", "null"]},
                                    "treeObjectRef": {"type": ["string", "null"], "description": "Provider-safe bounded tree object token for repository_tree_snapshot."},
                                    "repositoryTreeSnapshotInput": {"type": "object", "description": "Copyable provider-safe refs for repository_tree_snapshot."},
                                    "hasUpstream": {"type": "boolean"},
                                    "ahead": {"type": ["integer", "null"]},
                                    "behind": {"type": ["integer", "null"]},
                                    "pathspec": {"type": "string"},
                                    "repositoryRoot": {"description": "Workspace-relative repository root ref."},
                                    "worktreeRoot": {"description": "Workspace-relative worktree root ref."},
                                    "requestedPath": {"description": "Workspace-relative requested path ref."}
                                }
                            },
                            "evidence": {
                                "type": "object",
                                "properties": {
                                    "resourceRefs": {"type": "array"},
                                    "statusLimitBytes": {"type": "integer"},
                                    "statusTruncated": {"type": "boolean"},
                                    "statusPorcelainV1Z": {"type": "string"}
                                }
                            },
                            "staged": {"type": "array"},
                            "unstaged": {"type": "array"},
                            "untracked": {"type": "array"},
                            "conflicted": {"type": "array"}
                        }
                    }
                }
            }
        },
        "schemaCompleteness": "operation_specific_contract"
    })
}

fn web_robots_check_output_schema() -> Value {
    json!({
        "type": "object",
        "required": ["content", "details"],
        "properties": {
            "content": {
                "description": "Provider-safe robots-policy summary including copy-ready robots evidence refs for a later robots-gated web_fetch."
            },
            "details": {
                "type": "object",
                "required": ["primitiveOperation", "status", "web"],
                "properties": {
                    "primitiveOperation": {"const": "web_robots_check"},
                    "status": {"const": "ok"},
                    "web": {
                        "type": "object",
                        "required": [
                            "schemaVersion",
                            "status",
                            "operation",
                            "webRobotsPolicyResourceId",
                            "webRobotsPolicyVersionId",
                            "resourceRefs"
                        ],
                        "properties": {
                            "schemaVersion": {"const": "tron.web_robots_policy.v1"},
                            "status": {"const": "checked"},
                            "operation": {"const": "web_robots_check"},
                            "webRobotsPolicyResourceId": {"type": "string", "description": "Copy this into web_fetch.webRobotsPolicyResourceId when a subsequent fetch must be robots-gated."},
                            "webRobotsPolicyVersionId": {"type": "string", "description": "Copy this into web_fetch.expectedWebRobotsPolicyVersionId for freshness."},
                            "resourceRefs": {"type": "array", "description": "Bounded robots-policy resource refs; resourceRefs[0].versionId equals webRobotsPolicyVersionId."}
                        }
                    }
                }
            }
        },
        "schemaCompleteness": "operation_specific_contract"
    })
}

fn web_fetch_output_schema() -> Value {
    json!({
        "type": "object",
        "required": ["content", "details"],
        "properties": {
            "content": {
                "description": "Provider-safe fetch/source summary; raw HTML and raw bytes are not returned directly."
            },
            "details": {
                "type": "object",
                "required": ["primitiveOperation", "status", "web"],
                "properties": {
                    "primitiveOperation": {"const": "web_fetch"},
                    "status": {"const": "ok"},
                    "web": {
                        "type": "object",
                        "required": [
                            "schemaVersion",
                            "status",
                            "operation",
                            "webSourceResourceId",
                            "webSourceVersionId",
                            "resourceRefs"
                        ],
                        "properties": {
                            "schemaVersion": {"const": "tron.web_source.v1"},
                            "status": {"const": "fetched"},
                            "operation": {"const": "web_fetch"},
                            "webSourceResourceId": {"type": "string"},
                            "webSourceVersionId": {"type": "string"},
                            "robotsPolicyRefs": {"type": "array", "description": "Present when fetch was linked to current robots evidence; contains bounded resource/version refs only."},
                            "resourceRefs": {"type": "array", "description": "Bounded source resource refs for later web_source_list/inspect/archive operations."}
                        }
                    }
                }
            }
        },
        "schemaCompleteness": "operation_specific_contract"
    })
}

fn job_lifecycle_output_schema(operation: &str) -> Value {
    let jobs_schema = if operation == "job_status" {
        json!({
            "type": "object",
            "required": ["schemaVersion", "status", "job", "resourceRefs"],
            "properties": {
                "schemaVersion": {"type": "string"},
                "status": {"type": "string"},
                "job": redacted_job_output_schema(),
                "resourceRefs": {"type": "array", "description": "Provider-safe job/output refs only."}
            }
        })
    } else {
        json!({
            "type": "object",
            "required": ["schemaVersion", "status", "jobs"],
            "properties": {
                "schemaVersion": {"type": "string"},
                "status": {"const": "ok"},
                "jobs": {"type": "array", "items": redacted_job_output_schema()}
            }
        })
    };
    json!({
        "type": "object",
        "required": ["content", "details"],
        "properties": {
            "content": {
                "description": "Provider-safe lifecycle summary for durable jobs."
            },
            "details": {
                "type": "object",
                "description": "Provider-safe durable job lifecycle projection. Raw commands, working directories, authority/grant ids, raw idempotency keys, stdout, stderr, and raw job/output payloads are excluded.",
                "required": ["primitiveOperation", "status", "jobs"],
                "properties": {
                    "primitiveOperation": {"const": operation},
                    "status": {"type": "string"},
                    "jobs": jobs_schema
                }
            }
        },
        "schemaCompleteness": "operation_specific_contract"
    })
}

fn job_log_output_schema() -> Value {
    json!({
        "type": "object",
        "required": ["content", "details"],
        "properties": {
            "content": {
                "description": "Provider-safe bounded stdout/stderr preview summary for one durable job."
            },
            "details": {
                "type": "object",
                "description": "Bounded job log projection for explicit output inspection. Raw working directories, authority/grant ids, raw idempotency keys, and raw job payloads are excluded.",
                "required": ["primitiveOperation", "status", "jobs"],
                "properties": {
                    "primitiveOperation": {"const": "job_log"},
                    "status": {"type": "string"},
                    "jobs": {
                        "type": "object",
                        "required": ["schemaVersion", "status", "jobResourceId", "jobVersionId", "stdoutPreview", "stderrPreview", "outputTruncated", "resourceRefs"],
                        "properties": {
                            "schemaVersion": {"type": "string"},
                            "status": {"type": "string"},
                            "jobResourceId": {"type": "string"},
                            "jobVersionId": {"type": "string"},
                            "stdoutPreview": {"type": "string"},
                            "stderrPreview": {"type": "string"},
                            "outputResourceId": {"type": ["string", "null"]},
                            "outputVersionId": {"type": ["string", "null"]},
                            "outputTruncated": {"type": "boolean"},
                            "resourceRefs": {"type": "array"}
                        }
                    }
                }
            }
        },
        "schemaCompleteness": "operation_specific_contract"
    })
}

fn redacted_job_output_schema() -> Value {
    json!({
        "type": "object",
        "description": "Redacted durable job lifecycle projection.",
        "required": ["jobResourceId", "jobVersionId", "state", "limits", "retention", "cancellation", "projection"],
        "properties": {
            "jobResourceId": {"type": "string"},
            "jobVersionId": {"type": "string"},
            "state": {"type": "string"},
            "limits": {
                "type": "object",
                "properties": {
                    "timeoutMs": {"type": "integer"},
                    "maxOutputBytes": {"type": "integer"}
                }
            },
            "retention": {"type": "object"},
            "createdAt": {"type": "string"},
            "startedAt": {"type": ["string", "null"]},
            "completedAt": {"type": ["string", "null"]},
            "cancellation": {
                "type": "object",
                "properties": {
                    "requested": {"type": "boolean"},
                    "reasonRedacted": {"type": "boolean"},
                    "rawReasonReturned": {"const": false}
                }
            },
            "terminal": {
                "type": ["object", "null"],
                "properties": {
                    "status": {"type": "string"},
                    "exitCode": {"type": ["integer", "null"]},
                    "timedOut": {"type": "boolean"},
                    "cancelled": {"type": "boolean"},
                    "errorRedacted": {"type": "boolean"},
                    "rawErrorReturned": {"const": false}
                }
            },
            "output": {
                "type": ["object", "null"],
                "properties": {
                    "kind": {"type": "string"},
                    "resourceId": {"type": "string"},
                    "versionId": {"type": "string"},
                    "contentHash": {"type": "string"},
                    "durationMs": {"type": "integer"},
                    "exitCode": {"type": ["integer", "null"]},
                    "outputTruncated": {"type": "boolean"},
                    "stdoutPreviewReturned": {"const": false},
                    "stderrPreviewReturned": {"const": false},
                    "rawOutputReturned": {"const": false}
                }
            },
            "projection": {
                "type": "object",
                "properties": {
                    "rawCommandReturned": {"const": false},
                    "workingDirectoryReturned": {"const": false},
                    "authorityReturned": {"const": false},
                    "stdoutPreviewReturned": {"const": false},
                    "stderrPreviewReturned": {"const": false},
                    "rawOutputReturned": {"const": false}
                }
            }
        }
    })
}

fn trace_list_output_schema() -> Value {
    json!({
        "type": "object",
        "required": ["content", "details"],
        "properties": {
            "content": {
                "description": "Provider-safe trace summary with completed/in-progress counts and projection-boundary guidance."
            },
            "details": {
                "type": "object",
                "description": "Provider-safe current-session trace list. Raw provider invocation ids, grant ids, idempotency keys, raw requests/results, paths, commands, logs, and file contents are excluded from records[].",
                "required": ["primitiveOperation", "status", "projectionBoundary", "statusSummary", "records"],
                "properties": {
                    "primitiveOperation": {"const": "trace_list"},
                    "status": {"const": "ok"},
                    "projectionBoundary": trace_projection_boundary_output_schema(),
                    "statusSummary": {
                        "type": "object",
                        "required": ["totalRecords", "completedStatusCounts", "inProgressCount", "currentTraceListMayAppearRunning", "currentInvocationStatus"],
                        "properties": {
                            "totalRecords": {"type": "integer"},
                            "completedStatusCounts": {
                                "type": "object",
                                "description": "Counts by completed trace status, normally ok/failed."
                            },
                            "completedStatusValuesOnlyOkFailed": {"type": "boolean"},
                            "inProgressCount": {"type": "integer"},
                            "currentTraceListMayAppearRunning": {"const": true},
                            "currentInvocationStatus": {
                                "const": "pending_at_projection_time",
                                "description": "The current trace_list invocation is projected before its own completion is recorded."
                            },
                            "inProgressInterpretation": {"type": "string"},
                            "completedStatusGuidance": {"type": "string"},
                            "answerGuidance": {"type": "string"}
                        }
                    },
                    "records": {
                        "type": "array",
                        "description": "Bounded provider-safe trace records for the current session.",
                        "items": provider_safe_trace_record_output_schema()
                    }
                }
            }
        },
        "schemaCompleteness": "operation_specific_contract"
    })
}

fn trace_get_output_schema() -> Value {
    json!({
        "type": "object",
        "required": ["content", "details"],
        "properties": {
            "content": {
                "description": "Provider-safe trace-record summary for one current-session trace record."
            },
            "details": {
                "type": "object",
                "description": "Provider-safe focused trace record. Raw provider invocation ids, grant ids, idempotency keys, raw requests/results, paths, commands, logs, and file contents are excluded.",
                "required": ["primitiveOperation", "status", "projectionBoundary", "record"],
                "properties": {
                    "primitiveOperation": {"const": "trace_get"},
                    "status": {"const": "ok"},
                    "projectionBoundary": trace_projection_boundary_output_schema(),
                    "record": provider_safe_trace_record_output_schema()
                }
            }
        },
        "schemaCompleteness": "operation_specific_contract"
    })
}

fn trace_projection_boundary_output_schema() -> Value {
    json!({
        "type": "object",
        "description": "Explains that traceId, invocationId, parentInvocationId, runId, sessionRef, and workspaceRef are provider-safe engine refs, not raw provider invocation ids.",
        "properties": {
            "providerVisibleProjection": {"type": "string"},
            "providerVisibleMeaning": {"type": "string"},
            "internalAuditStorage": {"type": "string"},
            "safeRefSemantics": {"type": "string"},
            "recordProof": {"type": "string"},
            "transcriptToolCallBoundary": {"type": "string"},
            "operationBoundary": {"type": "string"},
            "rawCommandEvidenceGuidance": {"type": "string"},
            "answerGuidance": {"type": "string"},
            "traceGetUse": {"type": "string"}
        }
    })
}

fn provider_safe_trace_record_output_schema() -> Value {
    json!({
        "type": "object",
        "required": [
            "schemaVersion",
            "id",
            "traceId",
            "invocationId",
            "modelPrimitiveName",
            "operation",
            "status",
            "request",
            "result",
            "projectionBoundary",
            "authority",
            "redaction"
        ],
        "properties": {
            "schemaVersion": {"const": "tron.trace.provider_safe.v1"},
            "id": {"type": ["string", "null"], "description": "Provider-safe trace record ref."},
            "version": {"type": ["string", "null"]},
            "timestamp": {"type": ["string", "null"]},
            "traceId": {"type": ["string", "null"], "description": "Provider-safe engine trace ref, not a raw provider invocation id."},
            "invocationId": {"type": ["string", "null"], "description": "Provider-safe engine invocation ref, not a raw provider tool-call id."},
            "parentInvocationId": {"type": ["string", "null"]},
            "runId": {"type": ["string", "null"]},
            "sessionRef": {"type": ["string", "null"]},
            "workspaceRef": {"type": ["string", "null"]},
            "turn": {"type": ["integer", "null"]},
            "modelPrimitiveName": {"type": ["string", "null"]},
            "operation": {"type": ["string", "null"]},
            "status": {"type": ["string", "null"]},
            "startedAt": {"type": ["string", "null"]},
            "completedAt": {"type": ["string", "null"]},
            "durationMs": {"type": ["integer", "null"]},
            "request": {
                "type": "object",
                "required": ["hash", "rawStoredInProjection"],
                "properties": {
                    "hash": {"type": ["string", "null"]},
                    "rawStoredInProjection": {"const": false}
                }
            },
            "result": {
                "type": "object",
                "required": ["hash", "rawStoredInProjection"],
                "properties": {
                    "hash": {"type": ["string", "null"]},
                    "rawStoredInProjection": {"const": false}
                }
            },
            "projectionBoundary": {
                "type": "object",
                "required": [
                    "providerVisibleProjection",
                    "safeEngineRefsOnly",
                    "rawAuditFieldsProjected",
                    "internalAuditStorageMayRetainRawAuditFields"
                ],
                "properties": {
                    "providerVisibleProjection": {"const": true},
                    "safeEngineRefsOnly": {"const": true},
                    "rawAuditFieldsProjected": {"const": false},
                    "internalAuditStorageMayRetainRawAuditFields": {"const": true}
                }
            },
            "authority": {
                "type": "object",
                "required": [
                    "actorKind",
                    "scopeCount",
                    "rawActorIdStored",
                    "rawAuthorityGrantIdStored",
                    "rawIdempotencyKeyStored"
                ],
                "properties": {
                    "actorKind": {"type": ["string", "null"]},
                    "scopeCount": {"type": "integer"},
                    "rawActorIdStored": {"const": false},
                    "rawAuthorityGrantIdStored": {"const": false},
                    "rawIdempotencyKeyStored": {"const": false}
                }
            },
            "error": {
                "type": ["object", "null"],
                "description": "Provider-safe error summary. Raw error details are not stored in the projection."
            },
            "redaction": {
                "type": "object",
                "required": [
                    "rawProviderInvocationIdsExcluded",
                    "rawGrantIdsExcluded",
                    "rawAuthorityIdsExcluded",
                    "rawIdempotencyKeysExcluded",
                    "rawWorkingDirectoryExcluded",
                    "rawRequestExcluded",
                    "rawResultExcluded",
                    "rawFilesExcluded",
                    "rawVcsExcluded"
                ],
                "properties": {
                    "rawProviderInvocationIdsExcluded": {"const": true},
                    "rawGrantIdsExcluded": {"const": true},
                    "rawAuthorityIdsExcluded": {"const": true},
                    "rawIdempotencyKeysExcluded": {"const": true},
                    "rawWorkingDirectoryExcluded": {"const": true},
                    "rawRequestExcluded": {"const": true},
                    "rawResultExcluded": {"const": true},
                    "rawFilesExcluded": {"const": true},
                    "rawVcsExcluded": {"const": true}
                }
            }
        },
        "notProjectedFields": [
            "providerInvocationId",
            "authorityGrantId",
            "actorId",
            "idempotencyKey",
            "workingDirectory",
            "rawRequest",
            "rawResult",
            "rawCommand",
            "rawLog",
            "rawPath",
            "fileContents"
        ]
    })
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::engine::FunctionId;
    use crate::engine::kernel::schema;

    fn function_id() -> FunctionId {
        FunctionId::new("capability::execute").expect("canonical function id")
    }

    #[test]
    fn every_supported_operation_has_one_output_contract() {
        assert_eq!(OperationId::ALL_NAMES.len(), 188);
        for operation in OperationId::ALL_NAMES {
            assert!(
                output_schema(operation).is_some(),
                "missing output schema for {operation}"
            );
        }
    }

    #[test]
    fn special_operations_preserve_their_provider_safe_shapes() {
        let expected = [
            ("git_status", "git"),
            ("web_robots_check", "web"),
            ("web_fetch", "web"),
            ("job_status", "jobs"),
            ("job_list", "jobs"),
            ("job_log", "jobs"),
            ("trace_list", "records"),
            ("trace_get", "record"),
        ];
        for (operation, field) in expected {
            let contract = output_schema(operation).expect("special output schema");
            assert_eq!(
                contract["properties"]["details"]["properties"]["primitiveOperation"]["const"],
                operation,
                "wrong operation selector for {operation}"
            );
            assert!(
                contract["properties"]["details"]["properties"][field].is_object(),
                "missing {field} projection for {operation}"
            );
        }
    }

    #[test]
    fn generic_contract_has_only_the_minimal_provider_safe_envelope() {
        let contract = output_schema("goal_list").expect("generic output schema");
        assert_eq!(
            contract["properties"]["details"]["properties"]["primitiveOperation"]["const"],
            "goal_list"
        );
        assert_eq!(
            contract["properties"]["details"]["properties"]
                .as_object()
                .expect("generic details properties")
                .keys()
                .cloned()
                .collect::<Vec<_>>(),
            vec!["primitiveOperation", "status"]
        );
        assert_eq!(contract["required"], json!(["content", "details"]));
    }

    #[test]
    fn unknown_operations_fail_closed() {
        assert!(output_schema("unknown_operation").is_none());
        assert!(output_schema("").is_none());
    }

    #[test]
    fn every_output_contract_is_a_valid_schema_definition() {
        for operation in OperationId::ALL_NAMES {
            let contract = output_schema(operation).expect("registered output schema");
            schema::validate_schema_definition(&function_id(), "operation response", &contract)
                .unwrap_or_else(|error| panic!("invalid {operation} output schema: {error}"));
        }
    }
}
