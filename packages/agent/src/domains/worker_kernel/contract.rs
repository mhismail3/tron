use serde_json::{Value, json};

use crate::domains::registration::catalog::{CapabilitySpec, TransportIdempotencyMode};
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{EffectClass, IdempotencyContract, RiskLevel, VisibilityScope};

const WORKER: &str = "worker_kernel";

pub(super) fn capabilities() -> crate::engine::Result<Vec<CapabilitySpec>> {
    let mut specs = Vec::new();
    specs.push(spec(
        "worker_kernel::filesystem_read",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({"type":"object","additionalProperties":false,"required":["path"],"properties":{"path":{"type":"string"},"maxBytes":{"type":"integer","minimum":1,"maximum":4194304}}}),
        "Read a local UTF-8 file directly with the trusted local user's access.",
    )?);
    specs.push(spec(
        "worker_kernel::filesystem_list",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({"type":"object","additionalProperties":false,"properties":{"path":{"type":"string"},"maxResults":{"type":"integer","minimum":1,"maximum":5000}}}),
        "List a local directory directly with the trusted local user's access.",
    )?);
    specs.push(spec(
        "worker_kernel::filesystem_search_text",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({"type":"object","additionalProperties":false,"required":["query"],"properties":{"path":{"type":"string"},"query":{"type":"string"},"maxResults":{"type":"integer","minimum":1,"maximum":1000}}}),
        "Search local UTF-8 files recursively for literal text.",
    )?);
    specs.push(spec(
        "worker_kernel::filesystem_write",
        EffectClass::IdempotentWrite,
        RiskLevel::High,
        json!({"type":"object","additionalProperties":false,"required":["path","content"],"properties":{"path":{"type":"string"},"content":{"type":"string"},"createParents":{"type":"boolean"}}}),
        "Write a complete local text file directly with the trusted local user's access.",
    )?);
    specs.push(spec(
        "worker_kernel::process_run",
        EffectClass::ExternalSideEffect,
        RiskLevel::High,
        json!({"type":"object","additionalProperties":false,"required":["command"],"properties":{"command":{"type":"array","minItems":1,"items":{"type":"string"}},"cwd":{"type":"string"},"stdin":{},"timeoutSeconds":{"type":"integer","minimum":1,"maximum":7200}}}),
        "Run a local command directly with normal user permissions and bounded output.",
    )?);
    specs.push(spec(
        "worker_kernel::web_fetch",
        EffectClass::ExternalSideEffect,
        RiskLevel::Medium,
        json!({"type":"object","additionalProperties":false,"required":["url"],"properties":{"url":{"type":"string"},"maxBytes":{"type":"integer","minimum":1,"maximum":4194304}}}),
        "Fetch one explicit HTTP or HTTPS URL directly and return bounded source content with provenance.",
    )?);
    specs.push(spec(
        "worker_kernel::core_proposal_create",
        EffectClass::ExternalSideEffect,
        RiskLevel::High,
        json!({"type":"object","additionalProperties":false,"required":["title","intent","repositoryPath","patch","testCommand"],"properties":{"title":{"type":"string"},"intent":{"type":"string"},"repositoryPath":{"type":"string"},"patch":{"type":"string"},"testCommand":{"type":"array","minItems":1,"items":{"type":"string"}}}}),
        "Author, test, and commit a core patch in an isolated Git worktree without changing the running source tree.",
    )?);
    specs.push(spec(
        "worker_kernel::core_proposal_list",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({"type":"object","additionalProperties":false,"properties":{}}),
        "List tested and applied autonomous core-change proposals.",
    )?);
    specs.push(spec(
        "worker_kernel::core_proposal_inspect",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({"type":"object","additionalProperties":false,"required":["proposalId"],"properties":{"proposalId":{"type":"string"}}}),
        "Inspect a tested core-change proposal and its evidence.",
    )?);
    specs.push(spec(
        "worker_kernel::core_proposal_apply",
        EffectClass::ExternalSideEffect,
        RiskLevel::Critical,
        json!({"type":"object","additionalProperties":false,"required":["proposalId","approvalSessionId","approvalMessageId"],"properties":{"proposalId":{"type":"string"},"approvalSessionId":{"type":"string"},"approvalMessageId":{"type":"string"}}}),
        "Apply a tested core proposal only after verifying an explicit user-authored conversational approval.",
    )?);
    specs.push(spec(
        "worker_kernel::upsert",
        EffectClass::ExternalSideEffect,
        RiskLevel::High,
        json!({
            "type":"object","additionalProperties":false,"required":["bundle"],
            "properties":{
                "bundle":{"type":"object","additionalProperties":true},
                "predecessorWorkerId":{"type":"string"}
            }
        }),
        "Create or improve a persistent worker in one atomic validate, test, activate operation.",
    )?);
    specs.push(spec(
        "worker_kernel::discover",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({"type":"object","additionalProperties":false,"required":["query"],"properties":{"query":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":50}}}),
        "Find persistent workers relevant to a task and make their typed tools discoverable.",
    )?);
    specs.push(spec(
        "worker_kernel::list",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({"type":"object","additionalProperties":false,"properties":{"includeRetired":{"type":"boolean"}}}),
        "List persistent workers and their health, version, runner, and trigger status.",
    )?);
    specs.push(spec(
        "worker_kernel::inspect",
        EffectClass::PureRead,
        RiskLevel::Low,
        worker_id_schema(false),
        "Inspect one worker's active bundle, provenance, triggers, and version history.",
    )?);
    specs.push(spec(
        "worker_kernel::invoke",
        EffectClass::ExternalSideEffect,
        RiskLevel::High,
        json!({"type":"object","additionalProperties":false,"required":["workerId","input"],"properties":{"workerId":{"type":"string"},"input":{},"idempotencyKey":{"type":"string"}}}),
        "Invoke an enabled persistent worker by id with typed JSON input.",
    )?);
    for (method, description) in [
        (
            "worker_kernel::disable",
            "Disable and stop one persistent worker immediately.",
        ),
        (
            "worker_kernel::enable",
            "Enable a persistent worker and restore its typed tool.",
        ),
        (
            "worker_kernel::retire",
            "Recoverably retire a worker while preserving versions and run history.",
        ),
        (
            "worker_kernel::purge",
            "Permanently purge a previously retired worker and its bundle.",
        ),
    ] {
        specs.push(spec(
            method,
            EffectClass::ReversibleSideEffect,
            RiskLevel::High,
            worker_id_schema(false),
            description,
        )?);
    }
    specs.push(spec(
        "worker_kernel::rollback",
        EffectClass::ReversibleSideEffect,
        RiskLevel::High,
        json!({"type":"object","additionalProperties":false,"required":["workerId","version"],"properties":{"workerId":{"type":"string"},"version":{"type":"string"}}}),
        "Activate a retained last-known version of a persistent worker.",
    )?);
    specs.push(spec(
        "worker_kernel::inbox",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({"type":"object","additionalProperties":false,"properties":{"workerId":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":500}}}),
        "Read durable results and failures from the persistent worker inbox.",
    )?);
    specs.push(spec(
        "worker_kernel::runs",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({"type":"object","additionalProperties":false,"properties":{"workerId":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":500}}}),
        "List durable queued, running, completed, and failed worker invocations.",
    )?);
    specs.push(spec(
        "worker_kernel::webhook_rotate",
        EffectClass::ReversibleSideEffect,
        RiskLevel::High,
        json!({"type":"object","additionalProperties":false,"required":["workerId","triggerId"],"properties":{"workerId":{"type":"string"},"triggerId":{"type":"string"}}}),
        "Rotate one worker webhook token and return its new one-time credential.",
    )?);
    specs.push(spec(
        "worker_kernel::stop_all",
        EffectClass::ReversibleSideEffect,
        RiskLevel::Critical,
        json!({"type":"object","additionalProperties":false,"required":["stopped"],"properties":{"stopped":{"type":"boolean"}}}),
        "Stop or resume all persistent worker dispatch for the active profile.",
    )?);
    specs.push(
        CapabilityContract::new(
            "worker_kernel::inbox_attach",
            WORKER,
            EffectClass::IdempotentWrite,
            RiskLevel::Low,
            None,
        )
        .visibility(VisibilityScope::Internal)
        .request_schema(json!({"type":"object","additionalProperties":false,"properties":{"limit":{"type":"integer","minimum":1,"maximum":32},"relevanceQuery":{"type":"string"}}}))
        .response_schema(open_response())
        .idempotency(IdempotencyContract::caller_system_engine_ledger())
        .idempotency_mode(TransportIdempotencyMode::ExplicitRequired)
        .description("Claim notable unseen worker inbox observations for transient session context.")
        .build()?,
    );
    specs.push(
        CapabilityContract::new(
            "worker_kernel::webhook_invoke",
            WORKER,
            EffectClass::ExternalSideEffect,
            RiskLevel::High,
            None,
        )
        .visibility(VisibilityScope::Internal)
        .request_schema(json!({"type":"object","additionalProperties":false,"required":["workerId","triggerId","token","input","idempotencyKey"],"properties":{"workerId":{"type":"string"},"triggerId":{"type":"string"},"token":{"type":"string"},"input":{},"idempotencyKey":{"type":"string"}}}))
        .response_schema(open_response())
        .idempotency(IdempotencyContract::caller_system_engine_ledger())
        .idempotency_mode(TransportIdempotencyMode::ExplicitRequired)
        .description("Authenticated local webhook dispatch into the persistent worker runtime.")
        .build()?,
    );
    Ok(specs)
}

fn spec(
    function: &'static str,
    effect: EffectClass,
    risk: RiskLevel,
    request: Value,
    description: &'static str,
) -> crate::engine::Result<CapabilitySpec> {
    let mut contract = CapabilityContract::new(function, WORKER, effect, risk, None)
        .request_schema(request)
        .response_schema(open_response())
        .description(description)
        .tags(vec!["kernel", "worker", "self-extension", "persistent"]);
    if effect.requires_idempotency() {
        contract = contract
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .idempotency_mode(TransportIdempotencyMode::ExplicitRequired);
    }
    contract.build()
}

fn worker_id_schema(include_version: bool) -> Value {
    let mut properties = serde_json::Map::new();
    let _ = properties.insert("workerId".to_owned(), json!({"type":"string"}));
    if include_version {
        let _ = properties.insert("version".to_owned(), json!({"type":"string"}));
    }
    json!({
        "type":"object",
        "additionalProperties":false,
        "required": if include_version { vec!["workerId", "version"] } else { vec!["workerId"] },
        "properties": properties,
    })
}

fn open_response() -> Value {
    json!({"type":"object","additionalProperties":true})
}
