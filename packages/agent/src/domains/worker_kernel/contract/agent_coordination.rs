//! First-class reusable-agent coordination contracts.
//!
//! This module owns the five ordinary model operations, the bounded internal
//! Team Context projection, the authenticated iOS management surface, and the
//! one-release mailbox/wait compatibility aliases. Keeping these contracts
//! together makes the complete coordination protocol auditable without
//! introducing a second manifest or projection source.

use serde_json::json;

use crate::domains::registration::contract::FunctionContract;
use crate::engine::{
    EffectClass, FunctionDefinition, FunctionVisibility, ModelToolAudience, RiskLevel,
};

use super::WORKER;
use super::response;
use super::support::{model_spec, native_client_spec};

fn client_agent_id_schema() -> serde_json::Value {
    json!({
        "type":"object","additionalProperties":false,
        "required":["ownerSessionId","agentId"],
        "properties":{
            "ownerSessionId":{"type":"string","minLength":1,"maxLength":256},
            "agentId":{"type":"string","minLength":1,"maxLength":256}
        }
    })
}

pub(super) fn push_contracts(specs: &mut Vec<FunctionDefinition>) -> crate::engine::Result<()> {
    specs.push(model_spec(
        "worker_kernel::agent_discover",
        // The first coordination operation for a visible session lazily
        // materializes its deterministic root agent identity. Subsequent
        // calls are reads, but the contract must describe that replay-safe
        // first-call write honestly.
        EffectClass::IdempotentWrite,
        RiskLevel::Low,
        json!({
            "type":"object","additionalProperties":false,
            "properties":{
                "scope":{"type":"string","enum":["agents","roles","all"],"default":"all"},
                "query":{"type":"string","maxLength":512},
                "status":{"type":"array","maxItems":5,"uniqueItems":true,"items":{"type":"string","enum":["provisioning","idle","active","waiting","closing"]}},
                "cursor":{"type":"string","maxLength":256},
                "limit":{"type":"integer","minimum":1,"maximum":50,"default":20}
            }
        }),
        "Discover bounded operational summaries for active or idle addressable profile agents and explicitly declared reusable worker roles. Closed agents remain available only through authenticated relationship and audit views. Results never expose raw transcript/session ids, result content, credentials, or working directories.",
        "agent_discover",
        ModelToolAudience::Ordinary,
        125,
        "agent_coordination",
    )?);
    specs.push(model_spec(
        "worker_kernel::agent_spawn",
        EffectClass::ExternalSideEffect,
        RiskLevel::High,
        json!({
            "type":"object","additionalProperties":false,"required":["task"],
            "properties":{
                "task":{"type":"string","minLength":1,"maxLength":40000},
                "role":{"type":"string","minLength":1,"maxLength":160,"default":"general"},
                "name":{"type":"string","minLength":1,"maxLength":80},
                "context":{"type":"string","maxLength":40000,"description":"Bounded untrusted reference evidence; never a grant."},
                "model":{"type":"string","minLength":1,"maxLength":160},
                "reasoningLevel":{"type":"string","enum":["none","low","medium","high","x_high","max"]},
                "tools":{"type":"array","maxItems":32,"uniqueItems":true,"items":{"type":"string","minLength":1,"maxLength":64}},
                "writeScopes":{"type":"array","maxItems":32,"uniqueItems":true,"items":{"type":"string","minLength":1,"maxLength":2048}},
                "limits":{
                    "type":"object","additionalProperties":false,
                    "properties":{
                        "maxAssignmentSeconds":{"type":"integer","minimum":1,"maximum":7200},
                        "maxAssignmentTurns":{"type":"integer","minimum":1,"maximum":250},
                        "maxChildExecutions":{"type":"integer","minimum":0,"maximum":256},
                        "maxQueuedAssignments":{"type":"integer","minimum":0,"maximum":8}
                    }
                }
            }
        }),
        "Create one durable nested reusable agent and its first accepted assignment. The returned agentId remains stable across later assignments; assignmentId names only this work round. Requested tools and limits can only tighten the caller and role grants.",
        "agent_spawn",
        ModelToolAudience::Ordinary,
        126,
        "agent_coordination",
    )?);
    specs.push(model_spec(
        "worker_kernel::agent_send",
        EffectClass::IdempotentWrite,
        RiskLevel::Medium,
        json!({
            "type":"object","additionalProperties":false,"required":["to","kind","content"],
            "properties":{
                "to":{"type":"string","minLength":1,"maxLength":160,"description":"Opaque agentId or parent."},
                "kind":{"type":"string","enum":["instruction","request","question","answer","information","update"]},
                "content":{"type":"string","minLength":1,"maxLength":40000},
                "assignmentId":{"type":"string","minLength":1,"maxLength":160},
                "replyTo":{"type":"string","minLength":1,"maxLength":160}
            },
            "allOf":[
                {"if":{"properties":{"kind":{"const":"answer"}}},"then":{"required":["replyTo"]}},
                {"if":{"properties":{"kind":{"const":"update"}}},"then":{"required":["assignmentId"]}}
            ]
        }),
        "Send one durable typed coordination message to an opaque profile agent address. Instructions require management authority; peer requests are actionable offers, not commands. Answers correlate an exact question. Updates target an existing assignment. Actionable messages wake only at safe provider boundaries.",
        "agent_send",
        ModelToolAudience::Ordinary,
        127,
        "agent_coordination",
    )?.with_revision(2));
    specs.push(model_spec(
        "worker_kernel::agent_wait",
        EffectClass::IdempotentWrite,
        RiskLevel::Low,
        json!({
            "type":"object","additionalProperties":false,"required":["targets"],
            "properties":{
                "targets":{"type":"array","minItems":1,"maxItems":32,"uniqueItems":true,"items":{
                    "type":"object","additionalProperties":false,"required":["kind","id"],
                    "properties":{
                        "kind":{"type":"string","enum":["assignment","worker_invocation","reply"]},
                        "id":{"type":"string","minLength":1,"maxLength":160}
                    }
                }},
                "mode":{"type":"string","enum":["all","any"],"default":"all"}
            }
        }),
        "Durably park this assignment until all or any exact assignment, worker invocation, or reply handles terminalize. This is runtime control, not polling; terminal targets reconcile atomically with registration and completion wakes are coalesced.",
        "agent_wait",
        ModelToolAudience::Ordinary,
        128,
        "agent_coordination",
    )?);
    specs.push(model_spec(
        "worker_kernel::agent_manage",
        EffectClass::ReversibleSideEffect,
        RiskLevel::High,
        json!({
            "oneOf":[
                {"type":"object","additionalProperties":false,"required":["action","assignmentId","response"],"properties":{"action":{"const":"respond_to_offer"},"assignmentId":{"type":"string"},"response":{"type":"string","enum":["accept","decline"]},"reason":{"type":"string","maxLength":2000}}},
                {"type":"object","additionalProperties":false,"required":["action","target"],"properties":{"action":{"const":"cancel"},"target":{"type":"object","additionalProperties":false,"required":["kind","id"],"properties":{"kind":{"type":"string","enum":["assignment","agent","worker_execution"]},"id":{"type":"string"}}}}},
                {"type":"object","additionalProperties":false,"required":["action","agentId"],"properties":{"action":{"const":"close"},"agentId":{"type":"string"}}},
                {"type":"object","additionalProperties":false,"required":["action","agentId","configuration"],"properties":{"action":{"const":"configure"},"agentId":{"type":"string"},"configuration":{"type":"object","additionalProperties":false,"minProperties":1,"properties":{"tools":{"type":"array","maxItems":32,"uniqueItems":true,"items":{"type":"string"}},"writeScopes":{"type":"array","maxItems":32,"uniqueItems":true,"items":{"type":"string"}},"limits":{"type":"object","additionalProperties":false,"properties":{"maxAssignmentSeconds":{"type":"integer","minimum":1,"maximum":7200},"maxAssignmentTurns":{"type":"integer","minimum":1,"maximum":250},"maxChildExecutions":{"type":"integer","minimum":0,"maximum":256},"maxQueuedAssignments":{"type":"integer","minimum":0,"maximum":8}}}}}}},
                {"type":"object","additionalProperties":false,"required":["action","agentId","toAgentId","capabilities"],"properties":{"action":{"const":"grant_management"},"agentId":{"type":"string"},"toAgentId":{"type":"string"},"capabilities":{"type":"array","minItems":1,"maxItems":4,"uniqueItems":true,"items":{"type":"string","enum":["assign","cancel","configure","close"]}}}},
                {"type":"object","additionalProperties":false,"required":["action","grantId"],"properties":{"action":{"const":"revoke_management"},"grantId":{"type":"string"}}},
                {"type":"object","additionalProperties":false,"required":["action","agentId","role"],"properties":{"action":{"const":"upgrade_role"},"agentId":{"type":"string"},"role":{"type":"string"},"version":{"type":"string"}}}
            ]
        }),
        "Manage work only within the caller's owned subtree or an explicit bounded management grant. Accept or decline offers, cancel causal work, close quiescent agents, tighten configuration, delegate non-transitive management capabilities, or upgrade an idle named role.",
        "agent_manage",
        ModelToolAudience::Ordinary,
        129,
        "agent_coordination",
    )?);
    specs.push(
        FunctionContract::new(
            "worker_kernel::agent_team_context",
            WORKER,
            EffectClass::PureRead,
            RiskLevel::Low,
        )
        .visibility(FunctionVisibility::Internal)
        .request_schema(json!({
            "type":"object","additionalProperties":false,"required":["sessionId"],
            "properties":{"sessionId":{"type":"string","minLength":1},"limit":{"type":"integer","minimum":1,"maximum":32,"default":32}}
        }))
        .response_schema(response::response_schema(
            "worker_kernel::agent_team_context",
        ))
        .description("Project one bounded trusted Team Context roster for the engine-derived current session. This internal read never exposes transcripts, results, credentials, or working directories.")
        .build()?,
    );

    push_client_contracts(specs)?;
    push_compatibility_contracts(specs)?;
    Ok(())
}

fn push_client_contracts(specs: &mut Vec<FunctionDefinition>) -> crate::engine::Result<()> {
    specs.push(native_client_spec(
        "agent::relations",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({
            "type":"object","additionalProperties":false,"required":["ownerSessionId"],
            "properties":{
                "ownerSessionId":{"type":"string","minLength":1,"maxLength":256},
                "cursor":{"type":"string","maxLength":512},
                "limit":{"type":"integer","minimum":1,"maximum":100,"default":50}
            }
        }),
        "Return one canonical paged hierarchy/contact projection for the selected visible session.",
    )?);
    specs.push(native_client_spec(
        "agent::inspect",
        EffectClass::PureRead,
        RiskLevel::Low,
        client_agent_id_schema(),
        "Inspect one related agent with server-authored capabilities, lineage, usage, result, and allowed actions.",
    )?);
    for (function, description) in [
        (
            "agent::assignments",
            "Read one cursor-stable page of assignment history for a related agent.",
        ),
        (
            "agent::messages",
            "Read one cursor-stable page of canonical bidirectional coordination messages.",
        ),
    ] {
        specs.push(native_client_spec(
            function,
            EffectClass::PureRead,
            RiskLevel::Low,
            json!({
                "type":"object","additionalProperties":false,
                "required":["ownerSessionId","agentId"],
                "properties":{
                    "ownerSessionId":{"type":"string","minLength":1,"maxLength":256},
                    "agentId":{"type":"string","minLength":1,"maxLength":256},
                    "cursor":{"type":"string","maxLength":512},
                    "limit":{"type":"integer","minimum":1,"maximum":100,"default":50}
                }
            }),
            description,
        )?);
    }
    specs.push(native_client_spec(
        "agent::message_detail",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({
            "type":"object","additionalProperties":false,
            "required":["ownerSessionId","agentId","messageId"],
            "properties":{
                "ownerSessionId":{"type":"string","minLength":1,"maxLength":256},
                "agentId":{"type":"string","minLength":1,"maxLength":256},
                "messageId":{"type":"string","minLength":1,"maxLength":256}
            }
        }),
        "Read exact content and provenance for one authorized coordination message.",
    )?);
    specs.push(native_client_spec(
        "agent::result_read",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({
            "type":"object","additionalProperties":false,
            "required":["ownerSessionId","agentId","resultId","pointer","offset","limit"],
            "properties":{
                "ownerSessionId":{"type":"string","minLength":1,"maxLength":256},
                "agentId":{"type":"string","minLength":1,"maxLength":256},
                "resultId":{"type":"string","minLength":1,"maxLength":256},
                "pointer":{"type":"string","maxLength":2048},
                "offset":{"type":"integer","minimum":0},
                "limit":{"type":"integer","minimum":1,"maximum":20}
            }
        }),
        "Read one bounded page from an authorized durable assignment result.",
    )?);
    specs.push(native_client_spec(
        "agent::operator_message",
        EffectClass::IdempotentWrite,
        RiskLevel::High,
        json!({
            "type":"object","additionalProperties":false,
            "required":["ownerSessionId","agentId","clientMutationId","content"],
            "properties":{
                "ownerSessionId":{"type":"string","minLength":1,"maxLength":256},
                "agentId":{"type":"string","minLength":1,"maxLength":256},
                "clientMutationId":{"type":"string","minLength":1,"maxLength":256},
                "content":{"type":"string","minLength":1,"maxLength":40000}
            }
        }),
        "Send one authenticated operator instruction at the target agent's next safe boundary.",
    )?);
    specs.push(native_client_spec(
        "agent::manage",
        EffectClass::ReversibleSideEffect,
        RiskLevel::High,
        json!({
            "type":"object","additionalProperties":false,
            "required":["ownerSessionId","agentId","clientMutationId","action"],
            "properties":{
                "ownerSessionId":{"type":"string","minLength":1,"maxLength":256},
                "agentId":{"type":"string","minLength":1,"maxLength":256},
                "clientMutationId":{"type":"string","minLength":1,"maxLength":256},
                "action":{"type":"string","minLength":1,"maxLength":64},
                "assignmentId":{"type":"string","minLength":1,"maxLength":256},
                "cascade":{"type":"boolean"},
                "configuration":{}
            }
        }),
        "Apply one server-authorized agent management action and return a refreshed canonical detail projection.",
    )?);
    specs.push(native_client_spec(
        "agent::retry",
        EffectClass::IdempotentWrite,
        RiskLevel::High,
        json!({
            "type":"object","additionalProperties":false,
            "required":["ownerSessionId","agentId","clientMutationId","assignmentId"],
            "properties":{
                "ownerSessionId":{"type":"string","minLength":1,"maxLength":256},
                "agentId":{"type":"string","minLength":1,"maxLength":256},
                "clientMutationId":{"type":"string","minLength":1,"maxLength":256},
                "assignmentId":{"type":"string","minLength":1,"maxLength":256}
            }
        }),
        "Create a new assignment linked to one authorized terminal failure; never rewrite the original.",
    )?);
    specs.push(native_client_spec(
        "agent::promote",
        EffectClass::ReversibleSideEffect,
        RiskLevel::High,
        json!({
            "type":"object","additionalProperties":false,
            "required":["ownerSessionId","agentId","clientMutationId"],
            "properties":{
                "ownerSessionId":{"type":"string","minLength":1,"maxLength":256},
                "agentId":{"type":"string","minLength":1,"maxLength":256},
                "clientMutationId":{"type":"string","minLength":1,"maxLength":256}
            }
        }),
        "Promote one quiescent nested agent without changing its identity, transcript, results, or lineage.",
    )?);
    Ok(())
}

fn push_compatibility_contracts(specs: &mut Vec<FunctionDefinition>) -> crate::engine::Result<()> {
    specs.push(native_client_spec(
        "worker_kernel::agent_wait_for_workers",
        EffectClass::IdempotentWrite,
        RiskLevel::Low,
        json!({"type":"object","additionalProperties":false,"required":["invocationIds"],"properties":{"invocationIds":{"type":"array","minItems":1,"maxItems":32,"items":{"type":"string"}},"mode":{"type":"string","enum":["all","any"],"default":"all"}}}),
        "Compatibility alias for authenticated clients. Agents use agent_wait.",
    )?);
    specs.push(native_client_spec(
        "worker_kernel::agent_mailbox_list",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({"type":"object","additionalProperties":false,"required":["scope","name"],"properties":{"scope":{"type":"string","enum":["workspace","profile"]},"name":{"type":"string","maxLength":64},"limit":{"type":"integer","minimum":1,"maximum":100,"default":20}}}),
        "Legacy authenticated-client mailbox audit read; reusable agents use direct typed messages.",
    )?);
    specs.push(native_client_spec(
        "worker_kernel::agent_mailbox_claim",
        EffectClass::IdempotentWrite,
        RiskLevel::Low,
        json!({"type":"object","additionalProperties":false,"required":["deliveryIds"],"properties":{"deliveryIds":{"type":"array","minItems":1,"maxItems":8,"items":{"type":"string"}}}}),
        "Legacy authenticated-client mailbox claim; reusable agents use direct typed messages.",
    )?);
    Ok(())
}
