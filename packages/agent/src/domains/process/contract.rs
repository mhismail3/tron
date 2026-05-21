//! Capability contracts owned by the process domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, DurableOutputContract, EffectClass,
    IdempotencyContract, ResourceLeaseRequirement, Result as EngineResult, RiskLevel,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["process.output", "process.status"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new(
            "process::run",
            "process",
            EffectClass::ExternalSideEffect,
            RiskLevel::High,
            Some("process.run"),
        )
        .description("Run a bounded shell command in the session worktree with policy classification, output caps, trace/audit records, and approval only for risky commands. Read-only commands run directly with executionMode=read_only, including composed inspection checks such as pwd && test -f README.md && sed -n '1,3p' README.md. Write-like commands must run with executionMode=sandbox_materialized and declared expected outputs. Sandbox output paths are collected from the isolated process sandbox; omitted or relative targetPath values materialize into the active session worktree by default and are summarized in materializedOutputs for exact verification. If cwd is omitted, Tron uses the active session worktree when available, then the session workspace.")
        .tags(vec!["shell", "bash", "zsh", "command", "terminal", "date", "git status", "test", "build", "process"])
        .request_schema(json!({
            "additionalProperties": false,
            "properties": {
                "command": {"type": "string", "description": "Shell command to run, for example date, git status --short --branch, cargo test, or rg term path."},
                "executionMode": {"type": "string", "enum": ["read_only", "sandbox_materialized"]},
                "expectedOutputs": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["path"],
                        "additionalProperties": false,
                        "properties": {
                            "path": {"type": "string"},
                            "targetPath": {"type": "string"}
                        }
                    }
                },
                "retainOutput": {"type": "boolean"},
                "cwd": {"type": "string", "description": "Working directory. Omit this to use the active session worktree/workspace. Prefer this field over prefixing commands with cd."},
                "env": {"additionalProperties": true, "type": "object"},
                "shell": {"type": "string", "enum": ["bash", "zsh", "sh"]},
                "stdin": {"type": "string"},
                "timeoutMs": {"type": "integer", "minimum": 1, "maximum": 600000, "description": "Command timeout in milliseconds."},
                "timeout": {"type": "integer", "minimum": 1, "maximum": 600000, "description": "Command timeout in milliseconds. Prefer timeoutMs when writing new requests."},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            },
            "required": ["command", "executionMode"],
            "type": "object"
        }))
        .response_schema(json!({
            "additionalProperties": false,
            "properties": {
                "stdout": {"type": "string"},
                "stderr": {"type": "string"},
                "exitCode": {"type": "integer"},
                "durationMs": {"type": "integer"},
                "timedOut": {"type": "boolean"},
                "outputTruncated": {"type": "boolean"},
                "materializedOutputs": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["path", "targetPath", "resourceId", "versionId", "contentHash", "sizeBytes", "contentPreview", "previewTruncated"],
                        "additionalProperties": false,
                        "properties": {
                            "path": {"type": "string"},
                            "targetPath": {"type": "string"},
                            "resourceId": {"type": "string"},
                            "versionId": {"type": "string"},
                            "contentHash": {"type": "string"},
                            "sizeBytes": {"type": "integer"},
                            "contentPreview": {"type": "string"},
                            "previewTruncated": {"type": "boolean"}
                        }
                    }
                },
                "resourceRefs": resource_refs_schema()
            },
            "required": ["stdout", "stderr", "exitCode", "durationMs", "timedOut", "outputTruncated"],
            "type": "object"
        }))
        .idempotency(IdempotencyContract::caller_session_engine_ledger())
        .output_contract(DurableOutputContract::Conditional {
            classifier: "process_resource_output_required".to_owned(),
            resource_backed_contract: Box::new(DurableOutputContract::resource_backed([
                "materialized_file",
                "execution_output",
            ])),
        })
        .resource_lease(ResourceLeaseRequirement::exclusive_template(
            "process",
            "process:{sessionId}",
            600000,
        ))
        .compensation(CompensationContract::new(
            CompensationKind::ManualOnly,
            "external processes may mutate host state; command output and trace records are the audit boundary",
        ))
        .high_risk_contract(json!({
            "approvalRequiredForAgentVisibility": false,
            "conditionalApproval": {
                "owner": "process",
                "policy": "process::run command classifier",
                "approvalRequiredFor": [
                    "privileged commands",
                    "destructive filesystem operations",
                    "git write operations",
                    "package installation or publication",
                    "shell redirection that writes files"
                ],
                "approvalNotRequiredFor": [
                    "read-only inspection commands, including test predicates and bounded sed -n printing",
                    "date/time checks",
                    "read-only git status/log/diff checks, including commands that use cd only to select a directory",
                    "build and test commands without privileged or mutating shell operators"
                ]
            },
            "resourceLock": {
                "idTemplate": "process:{sessionId}",
                "kind": "process",
                "reason": "serializes high-risk shell execution within one session",
                "required": true,
                "ttlMs": 600000
            },
            "rollbackOrCompensation": "write-like commands run in an engine sandbox and materialize declared outputs through resources; external side effects outside that contract require manual compensation",
            "streamTopics": STREAM_TOPICS,
            "version": 1
        }))
        .stream_topics(STREAM_TOPICS.to_vec())
        .examples(vec![json!({
            "mode": "invoke",
            "contractId": "process::run",
            "payload": {"command": "date", "executionMode": "read_only"},
            "idempotencyKey": "date-check-<turn>",
            "reason": "Check the current local date/time."
        }), json!({
            "mode": "invoke",
            "contractId": "process::run",
            "payload": {"command": "git status --short --branch && git log --oneline -3", "executionMode": "read_only"},
            "idempotencyKey": "git-status-<turn>",
            "reason": "Check git state in the active session worktree."
        }), json!({
            "mode": "invoke",
            "contractId": "process::run",
            "payload": {"command": "pwd && test -f README.md && sed -n '1,3p' README.md", "executionMode": "read_only"},
            "idempotencyKey": "readme-check-<turn>",
            "reason": "Check the active session worktree and print a bounded README preview."
        }), json!({
            "mode": "invoke",
            "contractId": "process::run",
            "payload": {
                "command": "printf 'ok\\n' > result.txt",
                "executionMode": "sandbox_materialized",
                "expectedOutputs": [{"path": "result.txt"}]
            },
            "idempotencyKey": "process-materialized-<turn>",
            "reason": "Create one declared sandbox output and materialize it through resource refs."
        })])
        .build()?,
    ])
}

fn resource_refs_schema() -> serde_json::Value {
    json!({
        "type": "array",
        "items": {
            "type": "object",
            "required": ["resourceId", "kind", "role"],
            "additionalProperties": false,
            "properties": {
                "resourceId": {"type": "string"},
                "kind": {"type": "string"},
                "versionId": {"type": "string"},
                "role": {"type": "string"},
                "contentHash": {"type": "string"},
                "fileContentHash": {"type": "string"},
                "materializedPath": {"type": "string"},
                "relation": {"type": "string"}
            }
        }
    })
}
