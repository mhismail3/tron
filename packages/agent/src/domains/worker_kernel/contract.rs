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
                "bundle":worker_bundle_schema(),
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

/// Keep the complete worker authoring contract on the model-facing operation.
/// `WorkerBundle` remains the decoding authority; this schema makes that same
/// contract discoverable to an agent without a separate proposal or manual.
fn worker_bundle_schema() -> Value {
    let command = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["command"],
        "properties":{
            "command":{"type":"array","minItems":1,"items":{"type":"string"}},
            "timeoutSeconds":{"type":"integer","minimum":1,"maximum":7200}
        }
    });
    json!({
        "type":"object",
        "additionalProperties":false,
        "required":[
            "schemaVersion","name","description","inputSchema","outputSchema",
            "runner","provenance"
        ],
        "properties":{
            "schemaVersion":{
                "type":"string",
                "enum":["tron.worker_bundle.v1"],
                "description":"Version of the complete persistent-worker bundle contract."
            },
            "workerId":{
                "type":"string",
                "description":"Optional stable kebab-case identity. An existing id is updated directly; a new suggested id still yields to a near-identical semantic match."
            },
            "name":{"type":"string","minLength":1},
            "description":{
                "type":"string",
                "minLength":1,
                "description":"Explain when the agent should route work to this worker."
            },
            "toolName":{
                "type":"string",
                "description":"Optional stable direct tool name. Omit to retain the predecessor name or derive worker_<name>."
            },
            "inputSchema":{
                "type":"object",
                "description":"JSON object schema for typed worker input."
            },
            "outputSchema":{
                "type":"object",
                "description":"JSON object schema for typed worker output."
            },
            "runner":{
                "description":"Exactly one durable runner contract.",
                "oneOf":[
                    {
                        "type":"object","additionalProperties":false,
                        "required":["kind","instructions"],
                        "properties":{
                            "kind":{"type":"string","enum":["agent"]},
                            "instructions":{"type":"string","minLength":1},
                            "model":{"type":"string"}
                        }
                    },
                    {
                        "type":"object","additionalProperties":false,
                        "required":["kind","command"],
                        "properties":{
                            "kind":{"type":"string","enum":["command"]},
                            "command":{"type":"array","minItems":1,"items":{"type":"string"}}
                        }
                    },
                    {
                        "type":"object","additionalProperties":false,
                        "required":["kind","command","invokeUrl"],
                        "properties":{
                            "kind":{"type":"string","enum":["service"]},
                            "command":{"type":"array","minItems":1,"items":{"type":"string"}},
                            "invokeUrl":{"type":"string"},
                            "healthUrl":{"type":"string"}
                        }
                    }
                ]
            },
            "files":{
                "type":"object",
                "description":"Relative source-file paths mapped to complete UTF-8 string contents.",
                "additionalProperties":{"type":"string"}
            },
            "dependencies":{
                "type":"array",
                "items":{
                    "type":"object","additionalProperties":false,
                    "required":["name","source","version","checksum"],
                    "properties":{
                        "name":{"type":"string"},
                        "source":{"type":"string"},
                        "version":{"type":"string","description":"Exact version or source revision; never latest or a range."},
                        "checksum":{"type":"string","description":"Expected sha256:<64 lowercase or uppercase hex> source-tree digest."},
                        "install":command
                    }
                }
            },
            "triggers":{
                "type":"array",
                "items":{
                    "oneOf":[
                        {
                            "type":"object","additionalProperties":false,
                            "required":["kind","id"],
                            "properties":{
                                "kind":{"type":"string","enum":["manual"]},
                                "id":{"type":"string"}
                            }
                        },
                        {
                            "type":"object","additionalProperties":false,
                            "required":["kind","id","everySeconds"],
                            "properties":{
                                "kind":{"type":"string","enum":["schedule"]},
                                "id":{"type":"string"},
                                "everySeconds":{"type":"integer","minimum":1},
                                "input":{}
                            }
                        },
                        {
                            "type":"object","additionalProperties":false,
                            "required":["kind","id","topic"],
                            "properties":{
                                "kind":{"type":"string","enum":["engine_event"]},
                                "id":{"type":"string"},
                                "topic":{"type":"string","minLength":1},
                                "filter":{"type":"object"},
                                "input":{}
                            }
                        },
                        {
                            "type":"object","additionalProperties":false,
                            "required":["kind","id"],
                            "properties":{
                                "kind":{"type":"string","enum":["webhook"]},
                                "id":{"type":"string"},
                                "input":{}
                            }
                        }
                    ]
                }
            },
            "secretBindings":{
                "type":"array",
                "description":"Logical vault names only; never include secret values.",
                "items":{
                    "oneOf":[
                        {"type":"string"},
                        {
                            "type":"object","additionalProperties":false,
                            "required":["name"],
                            "properties":{
                                "name":{"type":"string"},
                                "required":{"type":"boolean"}
                            }
                        }
                    ]
                }
            },
            "smokeTests":{"type":"array","items":command},
            "healthChecks":{"type":"array","items":command},
            "provenance":{
                "type":"array","minItems":1,
                "items":{
                    "type":"object","additionalProperties":false,
                    "required":["source"],
                    "properties":{
                        "source":{"type":"string","minLength":1},
                        "revision":{"type":"string"},
                        "checksum":{"type":"string"}
                    }
                }
            },
            "routing":{
                "type":"object","additionalProperties":false,
                "properties":{
                    "intents":{"type":"array","items":{"type":"string"}},
                    "examples":{"type":"array","items":{"type":"string"}}
                }
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn upsert_exposes_the_complete_worker_bundle_authoring_schema() {
        let upsert = capabilities()
            .unwrap()
            .into_iter()
            .find(|spec| spec.function_id.as_str() == "worker_kernel::upsert")
            .expect("worker upsert contract");
        let schema = upsert.request_schema.expect("upsert request schema");
        let bundle = &schema["properties"]["bundle"];
        assert_eq!(bundle["additionalProperties"], false);
        assert!(
            bundle["required"]
                .as_array()
                .unwrap()
                .iter()
                .any(|field| field == "provenance")
        );
        assert_eq!(
            bundle["properties"]["runner"]["oneOf"]
                .as_array()
                .unwrap()
                .len(),
            3
        );
        assert_eq!(
            bundle["properties"]["triggers"]["items"]["oneOf"]
                .as_array()
                .unwrap()
                .len(),
            4
        );
        assert_eq!(
            bundle["properties"]["healthChecks"]["items"]["properties"]["timeoutSeconds"]["maximum"],
            7200
        );
        assert_eq!(
            bundle["properties"]["files"]["additionalProperties"]["type"],
            "string"
        );
    }
}
