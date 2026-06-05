//! Capability contracts owned by the agent domain worker.

use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, DurableOutputContract, EffectClass,
    IdempotencyContract, Result as EngineResult, RiskLevel, VisibilityScope,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["agent.runtime", "agent.queue"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    let mut specs = vec![
        CapabilityContract::new("agent::prompt", "agent", EffectClass::ExternalSideEffect, RiskLevel::High, Some("agent.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"attachments":{"items":{"additionalProperties":true,"type":"object"},"type":"array"},"images":{"items":{"additionalProperties":true,"type":"object"},"type":"array"},"prompt":{"type":"string"},"reasoningLevel":{"type":"string"},"sessionId":{"type":"string"},"source":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","prompt"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"acknowledged":{"type":"boolean"},"runId":{"type":"string"}},"required":["acknowledged","runId"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"not-required","kind":"documented-by-domain","reason":"existing domain guardrails own serialization; this metadata prevents high-risk generic triggers from omitting an explicit safety contract","required":false,"ttlMs":0},"rollbackOrCompensation":"domain-specific tests preserve current rollback, no-op, or replay behavior","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("agent::run_goal", "agent", EffectClass::ExternalSideEffect, RiskLevel::High, Some("agent.write"))
            .description("Run a goal from typed resource inputs and complete it with resource-backed outputs.")
            .approval_required(true)
            .request_schema(agent_run_goal_request_schema())
            .response_schema(json!({
                "type": "object",
                "required": ["goalResourceId", "agentResult", "decision", "resourceRefs"],
                "additionalProperties": false,
                "properties": {
                    "goalResourceId": {"type": "string"},
                    "agentResult": {"type": "object"},
                    "decision": {"type": "object"},
                    "workingSet": {"type": "object"},
                    "resourceRefs": {"type": "array"}
                }
            }))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .output_contract(DurableOutputContract::resource_backed(["agent_result", "decision", "goal"]))
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "goal runs are resource-backed; failed or interrupted runs leave linked resources inspectable and do not fabricate completion"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceBackedGoalRun":true,"streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .tags(vec!["goal", "coordinator", "agent result", "decision", "resources"])
            .build()?,
        CapabilityContract::new("agent::abort", "agent", EffectClass::ReversibleSideEffect, RiskLevel::High, Some("agent.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"not-required","kind":"documented-by-domain","reason":"existing domain guardrails own serialization; this metadata prevents high-risk generic triggers from omitting an explicit safety contract","required":false,"ttlMs":0},"rollbackOrCompensation":"domain-specific tests preserve current rollback, no-op, or replay behavior","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("agent::abort_invocation", "agent", EffectClass::ReversibleSideEffect, RiskLevel::Medium, Some("agent.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"invocationId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","invocationId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("agent::status", "agent", EffectClass::PureRead, RiskLevel::Low, Some("agent.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        CapabilityContract::new("agent::work_snapshot", "agent", EffectClass::PureRead, RiskLevel::Low, Some("agent.read"))
            .description("Read the server-owned Work dashboard projection: autonomy, active work, workers, trust, generated controls, milestones, guardrails, and audit refs.")
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"},"limit":{"type":"integer"}},"type":"object"}))
            .response_schema(json!({
                "type": "object",
                "required": ["autonomy", "activeWork", "workers", "recentMilestones", "guardrails", "auditRefs"],
                "additionalProperties": true,
                "properties": {
                    "autonomy": {"type": "object"},
                    "activeWork": {"type": "array"},
                    "workers": {"type": "array"},
                    "recentMilestones": {"type": "array"},
                    "guardrails": {"type": "array"},
                    "auditRefs": {"type": "array"}
                }
            }))
            .tags(vec!["work", "workers", "autonomy", "guardrails", "audit", "dashboard"])
            .build()?,
        CapabilityContract::new("agent::queue_prompt", "agent", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("agent.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"prompt":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","prompt"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("agent::dequeue_prompt", "agent", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("agent.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"queueId":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","queueId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("agent::clear_queue", "agent", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("agent.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("agent::ask_user", "agent", EffectClass::ExternalSideEffect, RiskLevel::Medium, Some("agent.write"))
            .description("Ask the user one or more questions and pause the turn until the client submits answers.")
            .request_schema(user_interaction_request_schema())
            .response_schema(capability_result_schema())
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "user-input pauses are resolved by explicit client answers or expiry; no synthetic answer is generated"))
            .lifecycle(json!({
                "kind": "user_input",
                "stopsTurn": true,
                "resumeContractId": "agent::submit_answers",
                "statusContractId": "agent::status",
                "cancelContractId": "agent::abort_invocation",
                "expiresAfterMs": 86_400_000u64,
                "answerAuthority": "user_client"
            }))
            .presentation_hints(json!({
                "icon": "question",
                "chipTitle": "Ask",
                "summaryFields": ["questions", "context"]
            }))
            .tags(vec!["ask user", "question", "clarify", "choice", "input", "interaction", "pause"])
            .examples(vec![json!({
                "summary": "Ask the user to choose between implementation approaches.",
                "payload": {
                    "questions": [{
                        "id": "approach",
                        "question": "Which implementation direction should I use?",
                        "mode": "single",
                        "options": [
                            {"label": "Minimal change", "description": "Keep the patch narrow."},
                            {"label": "Broader cleanup", "description": "Refactor the surrounding module too."}
                        ],
                        "allowOther": true
                    }],
                    "context": "I found two viable approaches."
                }
            })])
            .build()?,
        CapabilityContract::new("agent::submit_answers", "agent", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("agent.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"invocationId":{"type":"string"},"pauseId":{"type":"string"},"questions":{"items":{"additionalProperties":false,"properties":{"id":{"type":"string"},"otherValue":{"type":"string"},"question":{"type":"string"},"selectedValues":{"items":{"type":"string"},"type":"array"}},"required":["question"],"type":"object"},"type":"array"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","pauseId","questions"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .lifecycle(json!({
                "kind": "immediate",
                "resolvesPauseKind": "user_input",
                "answerAuthority": "user_client"
            }))
            .tags(vec!["answer", "submit answers", "resume", "user input"])
            .build()?,
        CapabilityContract::new("agent::spawn_subagent", "agent", EffectClass::ExternalSideEffect, RiskLevel::Medium, Some("agent.write"))
            .description("Spawn a scoped child agent and return a handle immediately by default; for fan-out, omit blockingTimeoutMs until all children are spawned, then use agent::subagent_status or agent::subagent_result to gather results.")
            .request_schema(subagent_spawn_request_schema())
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "agent::cancel_subagent can cancel a still-running child agent"))
            .lifecycle(json!({
                "kind": "async_run",
                "stopsTurn": false,
                "statusContractId": "agent::subagent_status",
                "resultContractId": "agent::subagent_result",
                "cancelContractId": "agent::cancel_subagent",
                "streamTopics": STREAM_TOPICS,
                "answerAuthority": "system"
            }))
            .presentation_hints(json!({"icon": "subagent", "chipTitle": "Subagent", "summaryFields": ["task", "taskProfile", "modelPreset", "model", "skills"]}))
            .tags(vec!["subagent", "delegate", "parallel", "background agent", "spawn worker"])
            .examples(vec![json!({
                "summary": "Spawn a reviewer subagent and wait separately.",
                "payload": {
                    "sessionId": "current-session",
                    "task": "Review the filesystem capability implementation for edge cases",
                    "maxTurns": 4,
                    "timeoutMs": 300000
                }
            })])
            .build()?,
        CapabilityContract::new("agent::subagent_status", "agent", EffectClass::PureRead, RiskLevel::Low, Some("agent.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"subagentSessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","subagentSessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .lifecycle(json!({"kind": "immediate"}))
            .tags(vec!["subagent status", "agent job", "progress"])
            .build()?,
        CapabilityContract::new("agent::subagent_result", "agent", EffectClass::PureRead, RiskLevel::Low, Some("agent.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"subagentSessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","subagentSessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .lifecycle(json!({"kind": "immediate"}))
            .tags(vec!["subagent result", "agent output", "child agent"])
            .build()?,
        CapabilityContract::new("agent::cancel_subagent", "agent", EffectClass::IdempotentWrite, RiskLevel::High, Some("agent.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"subagentSessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","subagentSessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "subagent cancellation is idempotent; completed child output remains in the ledger"))
            .lifecycle(json!({"kind": "immediate"}))
            .tags(vec!["cancel subagent", "stop child agent", "agent job cancel"])
            .build()?
    ];
    specs.extend(hidden_capabilities()?);
    Ok(specs)
}

fn hidden_capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("agent::prompt_apply", "agent", EffectClass::ExternalSideEffect, RiskLevel::High, Some("agent.write"))
            .visibility(VisibilityScope::Internal)
            .request_schema(agent_prompt_apply_request_schema())
            .response_schema(agent_prompt_response_schema())
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(
                CompensationKind::ExternalIrreversible,
                "hidden prompt apply starts queued runtime work; event-store history remains authoritative and replay is ledger/idempotency controlled",
            ))
            .high_risk_contract(json!({
                "internal": true,
                "hiddenPromptRuntimeFunction": true,
                "rollbackOrCompensation": "hidden prompt apply starts queued runtime work; event-store history remains authoritative and replay is ledger/idempotency controlled",
                "streamTopics": STREAM_TOPICS,
                "version": 1
            }))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("agent::run_turn", "agent", EffectClass::ExternalSideEffect, RiskLevel::High, Some("agent.write"))
            .visibility(VisibilityScope::Internal)
            .request_schema(agent_prompt_apply_request_schema())
            .response_schema(agent_prompt_response_schema())
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(
                CompensationKind::ExternalIrreversible,
                "hidden run-turn starts live provider capability work; event-store history remains authoritative and replay is ledger/idempotency controlled",
            ))
            .high_risk_contract(json!({
                "internal": true,
                "hiddenPromptRuntimeFunction": true,
                "rollbackOrCompensation": "hidden run-turn starts live provider capability work; event-store history remains authoritative and replay is ledger/idempotency controlled",
                "streamTopics": STREAM_TOPICS,
                "version": 1
            }))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("agent::prompt_queue_drain", "agent", EffectClass::ExternalSideEffect, RiskLevel::High, Some("agent.write"))
            .visibility(VisibilityScope::Internal)
            .request_schema(agent_prompt_queue_drain_request_schema())
            .response_schema(agent_prompt_queue_drain_response_schema())
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(
                CompensationKind::ExternalIrreversible,
                "hidden prompt queue drain starts queued runtime work after a prior run completes; replay is ledger/idempotency controlled",
            ))
            .high_risk_contract(json!({
                "internal": true,
                "hiddenPromptRuntimeFunction": true,
                "rollbackOrCompensation": "hidden prompt queue drain starts queued runtime work after a prior run completes; replay is ledger/idempotency controlled",
                "streamTopics": STREAM_TOPICS,
                "version": 1
            }))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
    ])
}

fn agent_prompt_apply_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["runId", "sessionId", "prompt"],
        "additionalProperties": false,
        "properties": {
            "runId": {"type": "string"},
            "sessionId": {"type": "string"},
            "prompt": {"type": "string"},
            "reasoningLevel": {"type": "string"},
            "images": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
            "attachments": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
            "source": {"type": "string"},
            "workspaceId": {"type": "string"}
        }
    })
}

fn agent_prompt_response_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["acknowledged", "runId"],
        "additionalProperties": false,
        "properties": {
            "acknowledged": {"type": "boolean"},
            "runId": {"type": "string"}
        }
    })
}

fn agent_prompt_queue_drain_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["sessionId", "completedRunId"],
        "additionalProperties": false,
        "properties": {
            "sessionId": {"type": "string"},
            "completedRunId": {"type": "string"},
            "workspaceId": {"type": "string"}
        }
    })
}

fn agent_prompt_queue_drain_response_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["drained", "count"],
        "additionalProperties": false,
        "properties": {
            "drained": {"type": "boolean"},
            "count": {"type": "integer"},
            "runId": {"type": ["string", "null"]},
            "reason": {"type": ["string", "null"]}
        }
    })
}

fn capability_result_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": true,
        "properties": {
            "content": {},
            "details": {"type": ["object", "null"]},
            "isError": {"type": ["boolean", "null"]},
            "stopTurn": {"type": ["boolean", "null"]}
        }
    })
}

fn agent_run_goal_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["goalResourceId", "promotedResourceIds", "decision"],
        "additionalProperties": false,
        "properties": {
            "goalResourceId": {"type": "string"},
            "promotedResourceIds": {"type": "array", "items": {"type": "string"}, "minItems": 1},
            "decision": {"type": "object"},
            "finalMessage": {"type": "string"},
            "coordinatorWorker": {"type": "string"},
            "runMode": {"type": "string"},
            "workingSetSelectors": {"type": "array", "items": {"type": "string"}},
            "constraints": {"type": "object"},
            "outputContract": {"type": "object"},
            "budget": {"type": "object"},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"}
        }
    })
}

fn user_interaction_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["questions"],
        "properties": {
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"},
            "context": {"type": "string"},
            "questions": {
                "type": "array",
                "minItems": 1,
                "maxItems": 5,
                "items": {
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["id", "question", "options", "mode"],
                    "properties": {
                        "id": {"type": "string"},
                        "question": {"type": "string"},
                        "mode": {"type": "string", "enum": ["single", "multi"]},
                        "allowOther": {"type": "boolean"},
                        "otherPlaceholder": {"type": "string"},
                        "options": {
                            "type": "array",
                            "minItems": 2,
                            "items": {
                                "type": "object",
                                "additionalProperties": false,
                                "required": ["label"],
                                "properties": {
                                    "label": {"type": "string"},
                                    "value": {"type": "string"},
                                    "description": {"type": "string"}
                                }
                            }
                        }
                    }
                }
            }
        }
    })
}

fn subagent_spawn_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["sessionId", "task"],
        "properties": {
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"},
            "task": {"type": "string"},
            "model": {"type": "string"},
            "modelPreset": {"type": "string", "enum": ["localWhenPossible", "balanced", "deep"]},
            "taskProfile": {"type": "string", "enum": ["general", "implementation", "review", "research", "qa", "planning"]},
            "systemPrompt": {"type": "string"},
            "workingDirectory": {"type": "string"},
            "maxTurns": {"type": "integer", "minimum": 1, "maximum": 20},
            "timeoutMs": {"type": "integer", "minimum": 1000, "maximum": 3600000},
            "blockingTimeoutMs": {"type": ["integer", "null"], "minimum": 0, "maximum": 300000, "description": "Omit or set null for non-blocking fan-out. Set only when this spawn call should wait before returning."},
            "deniedContracts": {"type": "array", "items": {"type": "string"}},
            "skills": {"type": "array", "items": {"type": "string"}},
            "maxDepth": {"type": "integer", "minimum": 0, "maximum": 3}
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn submit_answers_contract_accepts_pause_identity_and_client_question_id() {
        let specs = capabilities().expect("agent contracts");
        let submit = specs
            .iter()
            .find(|spec| spec.function_id.as_str() == "agent::submit_answers")
            .expect("submit answers contract");
        assert_eq!(
            submit
                .request_schema
                .as_ref()
                .and_then(|schema| schema.pointer("/required"))
                .and_then(serde_json::Value::as_array)
                .map(|required| required.contains(&json!("pauseId"))),
            Some(true)
        );
        assert_eq!(
            submit
                .request_schema
                .as_ref()
                .and_then(|schema| schema.pointer("/properties/invocationId/type")),
            Some(&json!("string"))
        );
        let id_property = submit
            .request_schema
            .as_ref()
            .and_then(|schema| schema.pointer("/properties/questions/items/properties/id"));

        assert_eq!(
            id_property.and_then(|value| value.get("type")),
            Some(&json!("string"))
        );
    }

    #[test]
    fn interactive_and_subagent_contracts_project_lifecycle_metadata() {
        let specs = capabilities().expect("agent contracts");
        let ask = specs
            .iter()
            .find(|spec| spec.function_id.as_str() == "agent::ask_user")
            .expect("ask user contract");
        assert_eq!(
            ask.lifecycle
                .as_ref()
                .and_then(|value| value.get("kind"))
                .and_then(serde_json::Value::as_str),
            Some("user_input")
        );
        assert_eq!(
            ask.lifecycle
                .as_ref()
                .and_then(|value| value.get("stopsTurn"))
                .and_then(serde_json::Value::as_bool),
            Some(true)
        );
        assert_eq!(
            ask.lifecycle
                .as_ref()
                .and_then(|value| value.get("resumeContractId"))
                .and_then(serde_json::Value::as_str),
            Some("agent::submit_answers")
        );

        let spawn = specs
            .iter()
            .find(|spec| spec.function_id.as_str() == "agent::spawn_subagent")
            .expect("spawn subagent contract");
        assert_eq!(
            spawn
                .lifecycle
                .as_ref()
                .and_then(|value| value.get("kind"))
                .and_then(serde_json::Value::as_str),
            Some("async_run")
        );
        assert_eq!(
            spawn
                .lifecycle
                .as_ref()
                .and_then(|value| value.get("statusContractId"))
                .and_then(serde_json::Value::as_str),
            Some("agent::subagent_status")
        );
        assert_eq!(
            spawn
                .lifecycle
                .as_ref()
                .and_then(|value| value.get("resultContractId"))
                .and_then(serde_json::Value::as_str),
            Some("agent::subagent_result")
        );
        assert!(
            spawn
                .description
                .as_ref()
                .is_some_and(|description| description.contains("omit blockingTimeoutMs")),
            "spawn_subagent contract must guide fan-out callers to non-blocking spawn"
        );
    }

    #[test]
    fn run_goal_contract_is_resource_backed_goal_orchestration() {
        let specs = capabilities().expect("agent contracts");
        let run_goal = specs
            .iter()
            .find(|spec| spec.function_id.as_str() == "agent::run_goal")
            .expect("run goal contract");
        assert_eq!(
            run_goal
                .request_schema
                .as_ref()
                .and_then(|schema| schema.pointer("/required"))
                .and_then(serde_json::Value::as_array)
                .map(|required| {
                    required.contains(&json!("goalResourceId"))
                        && required.contains(&json!("promotedResourceIds"))
                        && required.contains(&json!("decision"))
                }),
            Some(true)
        );
        let allowed = match &run_goal.output_contract {
            DurableOutputContract::ResourceBacked {
                produced_resource_kinds,
                required_resource_refs,
            } => Some((produced_resource_kinds, required_resource_refs)),
            _ => None,
        }
        .expect("resource-backed output contract");
        assert_eq!(*allowed.1, true);
        assert!(allowed.0.contains(&"agent_result".to_owned()));
        assert!(allowed.0.contains(&"decision".to_owned()));
        assert!(allowed.0.contains(&"goal".to_owned()));
    }
}
