//! Fixed primitive contracts and their single canonical identity manifest.
//!
//! `manifest` defines stable model names, function IDs, groups, and ordering.
//! This module builds request contracts from that inventory; `response` owns
//! output schemas, and `bundle` owns the complete atomic worker-authoring
//! schema. Contract tests live beside all three owners.

use serde_json::{Value, json};

use crate::domains::registration::contract::FunctionContract;
use crate::engine::{
    EffectClass, FunctionDefinition, FunctionVisibility, IdempotencyContract, RiskLevel,
};

mod bundle;
mod manifest;
mod response;

#[cfg(test)]
pub(crate) use manifest::CorePrimitiveGroup;
pub(crate) use manifest::{core_primitive_for_function, core_primitives};
use response::{open_response, response_schema, worker_id_schema};

const WORKER: &str = "worker_kernel";
const WORKER_UPSERT_DESCRIPTION: &str = "\
Create or improve a persistent worker in one atomic validate, test, activate operation. \
Canonical authoring protocol: (1) use worker_discover, worker_list, or worker_inspect only when existing-worker context is useful; semantic overlap is also checked during upsert; \
(2) design the complete typed bundle from this public operation schema, including runner, triggers, named-secret bindings, provenance, smoke tests, and health checks; \
(3) author and exercise source in a temporary directory with the public host tools, then pass sourceDirectory instead of echoing files into the call; \
(4) call worker_upsert once to import, validate, dependency-lock, smoke-test, atomically publish, activate, and project the direct tool; \
(5) use the returned worker id/version and public worker tools to verify behavior. \
This operation description and request schema are the complete authoritative authoring contract. Never inspect or modify Tron databases, auth stores, binaries, runtime files, lock files, or private server endpoints to infer schemas, activate a worker, or discover hidden steps. \
If a required behavior is absent from the public contract, report a concrete engine-contract gap instead of guessing or probing internals. Inspect external sources and user workspace data only when they are inputs to the worker's useful behavior. \
Imported source is published as non-executable text: command runners and smoke/health commands use exact argv without shell parsing, start in files/, and must invoke scripts through an explicit interpreter such as python3 or bash. They read typed JSON from stdin and emit JSON on stdout. \
A fetched dependency <name> is available at ../dependencies/<name>; its optional install command runs inside that dependency directory first. A dependency may omit checksum; worker_upsert fetches it and seals the actual digest into the immutable bundle. \
Engine-event input supplies typed defaults; matching top-level event payload keys declared by inputSchema override them. bundle.engineHooks contains the complete authoritative engine-hook contracts.";
pub(crate) const ENGINE_SURFACE_SNAPSHOT_FUNCTION: &str = "engine::surface_snapshot";
pub(crate) const CONTEXT_SUMMARY_FUNCTION: &str = "worker_kernel::context_summary";
pub(crate) const CONTEXT_SUMMARY_MAX_ESTIMATED_TOKENS: usize = 10_000;
pub(crate) const CONTEXT_SUMMARY_MAX_NARRATIVE_BYTES: usize = 40_000;
pub(crate) const SESSION_TITLE_FUNCTION: &str = "worker_kernel::session_title";
pub(crate) const WORKER_RELEVANCE_FUNCTION: &str = "worker_kernel::worker_relevance";
pub(super) const DEFAULT_TEXT_SEARCH_TIMEOUT_SECONDS: u64 = 5;
pub(super) const MAX_TEXT_SEARCH_TIMEOUT_SECONDS: u64 = 60;
pub(super) const DEFAULT_TEXT_SEARCH_WALK_ENTRIES: usize = 20_000;
pub(super) const MAX_TEXT_SEARCH_WALK_ENTRIES: usize = 100_000;

/// Estimate semantic-summary tokens with the same cheap pre-call heuristic
/// used by the agent context budget. Provider-reported usage remains the
/// source of truth for completed model calls.
#[must_use]
pub(crate) fn estimate_context_summary_tokens(narrative: &str) -> usize {
    narrative.len().div_ceil(4)
}

pub(crate) fn validate_context_summary_narrative(narrative: &str) -> Result<(), String> {
    if narrative.trim().is_empty() {
        return Err("context-summary narrative must not be empty".to_owned());
    }
    let estimated_tokens = estimate_context_summary_tokens(narrative);
    if estimated_tokens > CONTEXT_SUMMARY_MAX_ESTIMATED_TOKENS {
        return Err(format!(
            "context-summary narrative is estimated at {estimated_tokens} tokens; the ceiling is {CONTEXT_SUMMARY_MAX_ESTIMATED_TOKENS} tokens"
        ));
    }
    if narrative.len() > CONTEXT_SUMMARY_MAX_NARRATIVE_BYTES {
        return Err(format!(
            "context-summary narrative is {} UTF-8 bytes; the storage ceiling is {} bytes",
            narrative.len(),
            CONTEXT_SUMMARY_MAX_NARRATIVE_BYTES
        ));
    }
    Ok(())
}

pub(super) fn function_definitions() -> crate::engine::Result<Vec<FunctionDefinition>> {
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
        json!({"type":"object","additionalProperties":false,"properties":{"path":{"type":"string"},"maxResults":{"type":"integer","minimum":1,"maximum":5000},"maxWalkEntries":{"type":"integer","minimum":1,"maximum":50000}}}),
        "List a local directory with deterministic ordering and explicit result and traversal ceilings.",
    )?);
    specs.push(spec(
        "worker_kernel::filesystem_search_text",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({
            "type":"object",
            "additionalProperties":false,
            "required":["query"],
            "properties":{
                "path":{"type":"string","description":"Smallest directory or file that can answer the question; defaults to the session working directory."},
                "query":{"type":"string"},
                "maxResults":{"type":"integer","minimum":1,"maximum":1000},
                "maxWalkEntries":{"type":"integer","minimum":1,"maximum":MAX_TEXT_SEARCH_WALK_ENTRIES},
                "timeoutSeconds":{"type":"integer","minimum":1,"maximum":MAX_TEXT_SEARCH_TIMEOUT_SECONDS},
                "includeHidden":{"type":"boolean","description":"Traverse hidden children. An explicitly selected hidden root is always searched."},
                "includeIgnoredDirectories":{"type":"boolean","description":"Traverse common dependency, build, cache, and macOS Library directories."}
            }
        }),
        "Bounded literal search of local UTF-8 files. Choose the smallest path; the default five-second and 20,000-entry ceilings keep agent cancellation and server shutdown responsive.",
    )?);
    specs.push(spec(
        "worker_kernel::filesystem_write",
        EffectClass::IdempotentWrite,
        RiskLevel::High,
        json!({"type":"object","additionalProperties":false,"required":["path","content"],"properties":{"path":{"type":"string"},"content":{"type":"string"},"createParents":{"type":"boolean"},"expectedSha256":expected_sha256_schema(true)}}),
        "Atomically publish a complete local text file. Supply expectedSha256 after reading when overwriting concurrent work would be unsafe.",
    )?);
    specs.push(spec(
        "worker_kernel::filesystem_edit",
        EffectClass::IdempotentWrite,
        RiskLevel::High,
        json!({
            "type":"object",
            "additionalProperties":false,
            "required":["path","replacements"],
            "properties":{
                "path":{"type":"string"},
                "expectedSha256":expected_sha256_schema(false),
                "replacements":{
                    "type":"array","minItems":1,"maxItems":128,
                    "items":{
                        "type":"object","additionalProperties":false,
                        "required":["oldText","newText"],
                        "properties":{
                            "oldText":{"type":"string","minLength":1},
                            "newText":{"type":"string"},
                            "expectedOccurrences":{"type":"integer","minimum":1,"maximum":10000}
                        }
                    }
                }
            }
        }),
        "Apply bounded exact-text replacements to one UTF-8 file and atomically publish only when every expected occurrence and optional checksum still match.",
    )?);
    specs.push(spec(
        "worker_kernel::process_run",
        EffectClass::ExternalSideEffect,
        RiskLevel::High,
        json!({"type":"object","additionalProperties":false,"required":["command"],"properties":{"command":{"type":"array","minItems":1,"maxItems":256,"items":{"type":"string"}},"cwd":{"type":"string"},"stdin":{},"timeoutSeconds":{"type":"integer","minimum":1,"maximum":7200}}}),
        "Run a local command directly with normal user permissions and bounded output.",
    )?);
    specs.push(spec(
        "worker_kernel::web_fetch",
        EffectClass::ExternalSideEffect,
        RiskLevel::Medium,
        json!({"type":"object","additionalProperties":false,"required":["url"],"properties":{"url":{"type":"string"},"maxBytes":{"type":"integer","minimum":1,"maximum":4194304,"default":131072},"timeoutSeconds":{"type":"integer","minimum":1,"maximum":120,"default":30}}}),
        "Fetch one explicit HTTP or HTTPS URL directly and return bounded raw UTF-8 source content, redirect/status metadata, and a retained-content checksum. The context-safe default retains 128 KiB; request a larger ceiling only when needed.",
    )?);
    specs.push(spec(
        "worker_kernel::session_set_title",
        EffectClass::IdempotentWrite,
        RiskLevel::Medium,
        json!({"type":"object","additionalProperties":false,"required":["title"],"properties":{"title":{"type":"string","minLength":1,"maxLength":160}}}),
        "Rename the current conversation only when the user explicitly asks to rename, title, or name it. The target is always the current causal session. Do not use this during ordinary conversation; automatic title policy runs independently in a background worker.",
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
        "List tested and applied core-change proposals.",
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
        "Apply a tested core proposal only after verifying a later, unambiguous, non-negated user-authored conversational approval that names it.",
    )?);
    specs.push(spec(
        "worker_kernel::upsert",
        EffectClass::ExternalSideEffect,
        RiskLevel::High,
        json!({
            "type":"object","additionalProperties":false,"required":["bundle"],
            "properties":{
                "bundle":bundle::worker_bundle_schema(),
                "sourceDirectory":{"type":"string","description":"Optional local directory containing staged UTF-8 worker source. Files are imported recursively into bundle.files; explicit inline files win. Use this after authoring and testing locally so the model does not read and echo file contents back through JSON."},
                "predecessorWorkerId":{"type":"string"}
            }
        }),
        WORKER_UPSERT_DESCRIPTION,
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
        json!({"type":"object","additionalProperties":false,"required":["workerId"],"properties":{"workerId":{"type":"string"},"detail":{"type":"string","enum":["contract","full"],"default":"contract","description":"contract returns the active behavioral contract without source files or operational history; full includes the immutable source manifest and bounded history for operator clients."}}}),
        "Inspect one worker. The context-safe default returns its active typed contract, provenance, triggers, and versions; request detail=full only for immutable source metadata and operational history.",
    )?);
    specs.push(spec(
        "worker_kernel::invoke",
        EffectClass::ExternalSideEffect,
        RiskLevel::High,
        json!({"type":"object","additionalProperties":false,"required":["workerId","input"],"properties":{"workerId":{"type":"string"},"input":{},"idempotencyKey":{"type":"string"},"mode":{"type":"string","enum":["wait","enqueue"],"description":"wait returns the terminal record; enqueue returns immediately after durable admission."}}}),
        "Invoke an enabled persistent worker by id with typed JSON input. Use mode=enqueue for parallel or long-running work, then worker_await when its result is needed.",
    )?);
    specs.push(spec(
        "worker_kernel::await",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({"type":"object","additionalProperties":false,"required":["invocationId"],"properties":{"invocationId":{"type":"string"},"timeoutSeconds":{"type":"integer","minimum":0,"maximum":7200}}}),
        "Wait boundedly for one durable worker invocation. A wait timeout returns current state and never cancels the worker.",
    )?);
    specs.push(spec(
        "worker_kernel::cancel",
        EffectClass::ReversibleSideEffect,
        RiskLevel::High,
        json!({"type":"object","additionalProperties":false,"required":["invocationId"],"properties":{"invocationId":{"type":"string"}}}),
        "Cancel one queued or running worker invocation without stopping unrelated work or disabling its worker.",
    )?);
    for (method, description) in [
        (
            "worker_kernel::stop",
            "Stop one worker's current invocations and resident service without disabling future dispatch.",
        ),
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
        "worker_kernel::purge",
        EffectClass::IrreversibleSideEffect,
        RiskLevel::Critical,
        worker_id_schema(false),
        "Create a verified recovery archive, then purge a previously retired worker's live bundle, state, runs, and inbox history.",
    )?);
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
        json!({"type":"object","additionalProperties":false,"properties":{"workerId":{"type":"string"},"contextAttached":{"type":"boolean"},"severity":{"type":"string","enum":["info","error"]},"attentionOnly":{"type":"boolean","default":false},"limit":{"type":"integer","minimum":1,"maximum":20},"offset":{"type":"integer","minimum":0},"detail":{"type":"string","enum":["summary","full"],"default":"summary"}}}),
        "Read a bounded page of durable worker delivery records. Filter by whether a result was attached to later agent context, severity, or the high-signal attention projection. Attention includes unresolved failures plus pending non-manual background outcomes. A later verified healthy activation or rollback resolves older failures without deleting them from this audit ledger; merely enabling a failed worker does not. Routine successful manual-result copies remain available only in the unfiltered audit ledger. Omit workerId to query the entire profile; continue with nextOffset when present. Compact summaries are the default; explicit full detail is bounded to 20 records and 8 KiB per result.",
    )?);
    specs.push(spec(
        "worker_kernel::runs",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({"type":"object","additionalProperties":false,"properties":{"workerId":{"type":"string"},"originSessionId":{"type":"string"},"status":{"type":"string","enum":["queued","running","completed","failed","cancelled"]},"limit":{"type":"integer","minimum":1,"maximum":20},"offset":{"type":"integer","minimum":0},"detail":{"type":"string","enum":["summary","full"],"default":"summary"}}}),
        "List a bounded page of durable worker invocations, optionally filtered by worker, originating chat session, or execution status. A session filter includes descendant worker calls from the same causal trace even when they ran through child agent sessions. Omit workerId and originSessionId to query the entire profile; continue with nextOffset when present. Compact summaries omit attempt and trace expansion by default; explicit full detail is bounded to 20 records and 8 KiB per input or output.",
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
        "Stop or resume all persistent worker dispatch for this engine.",
    )?);
    specs.push(
        FunctionContract::new(
            ENGINE_SURFACE_SNAPSHOT_FUNCTION,
            "engine",
            EffectClass::PureRead,
            RiskLevel::Low)
        .request_schema(json!({
            "type":"object",
            "additionalProperties":false,
            "properties":{
                "relevanceQuery":{"type":"string"}
            }
        }))
        .response_schema(json!({
            "type":"object",
            "additionalProperties":false,
            "required":["dispatchStopped","activeEngineHooks","activeClientActions","fixedTools","surface","workers"],
            "properties":{
                "dispatchStopped":{"type":"boolean"},
                "activeEngineHooks":{
                    "type":"array",
                    "items":{
                        "type":"object",
                        "additionalProperties":false,
                        "required":["hook","workerId","workerVersion"],
                        "properties":{
                            "hook":{"type":"string"},
                            "workerId":{"type":"string"},
                            "workerVersion":{"type":"string"}
                        }
                    }
                },
                "activeClientActions":{
                    "type":"array",
                    "items":{
                        "type":"object",
                        "additionalProperties":false,
                        "required":["action","workerId","workerVersion"],
                        "properties":{
                            "action":{"type":"string"},
                            "workerId":{"type":"string"},
                            "workerVersion":{"type":"string"}
                        }
                    }
                },
                "fixedTools":{"type":"array"},
                "surface":{
                    "type":"object",
                    "additionalProperties":false,
                    "required":["catalogRevision","surfaceHash","fixedToolCount","projectedWorkerCount","availableWorkerCount","availableWorkers"],
                    "properties":{
                        "catalogRevision":{"type":"integer"},
                        "surfaceHash":{"type":"string"},
                        "fixedToolCount":{"type":"integer"},
                        "projectedWorkerCount":{"type":"integer"},
                        "availableWorkerCount":{"type":"integer"},
                        "availableWorkers":{"type":"array"}
                    }
                },
                "workers":{"type":"array"}
            }
        }))
        .description(
            "Return authoritative fixed-tool, selected-worker, and engine worker inventory for authenticated clients.",
        )
        .build()?,
    );
    specs.push(
        FunctionContract::new(
            CONTEXT_SUMMARY_FUNCTION,
            WORKER,
            EffectClass::ExternalSideEffect,
            RiskLevel::Medium)
        .visibility(FunctionVisibility::Internal)
        .request_schema(json!({
            "type":"object",
            "additionalProperties":false,
            "required":["messages"],
            "properties":{
                "originWorkerId":{"type":"string"},
                "messages":{
                    "type":"array",
                    "maxItems":256,
                    "items":{
                        "type":"object",
                        "additionalProperties":false,
                        "required":["role","text"],
                        "properties":{
                            "role":{"type":"string","enum":["user","assistant","tool"]},
                            "text":{"type":"string","maxLength":4096}
                        }
                    }
                }
            }
        }))
        .response_schema(json!({
            "type":"object",
            "additionalProperties":false,
            "required":["handled"],
            "properties":{
                "handled":{"type":"boolean"},
                "workerId":{"type":"string"},
                "workerVersion":{"type":"string"},
                "narrative":{"type":"string","maxLength":40000}
            }
        }))
        .idempotency(IdempotencyContract::session())
        .description("Invoke the active worker-owned context-summary policy, if any. Kernel callers recover with deterministic summarization when no worker handles it.")
        .build()?,
    );
    specs.push(
        FunctionContract::new(
            SESSION_TITLE_FUNCTION,
            WORKER,
            EffectClass::IdempotentWrite,
            RiskLevel::Medium)
        .visibility(FunctionVisibility::Internal)
        .request_schema(json!({
            "type":"object",
            "additionalProperties":false,
            "required":["userPrompt","assistantResponse"],
            "properties":{
                "userPrompt":{"type":"string","maxLength":4096},
                "assistantResponse":{"type":"string","maxLength":4096}
            }
        }))
        .response_schema(json!({
            "type":"object",
            "additionalProperties":false,
            "required":["handled","updated"],
            "properties":{
                "handled":{"type":"boolean"},
                "updated":{"type":"boolean"},
                "workerId":{"type":"string"},
                "workerVersion":{"type":"string"},
                "title":{"type":"string","minLength":1,"maxLength":160}
            }
        }))
        .idempotency(IdempotencyContract::session())
        .description("Name an untitled ordinary user session through the active worker-owned title policy after its first successful exchange. Explicit titles and worker audit sessions are never eligible.")
        .build()?,
    );
    specs.push(
        FunctionContract::new(
            WORKER_RELEVANCE_FUNCTION,
            WORKER,
            EffectClass::ExternalSideEffect,
            RiskLevel::Medium)
        .visibility(FunctionVisibility::Internal)
        .request_schema(json!({
            "type":"object",
            "additionalProperties":false,
            "required":["query","candidates"],
            "properties":{
                "originWorkerId":{"type":"string"},
                "query":{"type":"string","maxLength":12000},
                "candidates":{
                    "type":"array","maxItems":256,
                    "items":{
                        "type":"object","additionalProperties":false,
                        "required":["workerId","name","description","intents","examples","provenance","completedRuns","updatedAt"],
                        "properties":{
                            "workerId":{"type":"string","minLength":1},
                            "name":{"type":"string"},
                            "description":{"type":"string"},
                            "intents":{"type":"array","items":{"type":"string"}},
                            "examples":{"type":"array","items":{"type":"string"}},
                            "provenance":{"type":"array","items":{"type":"string"}},
                            "completedRuns":{"type":"integer","minimum":0},
                            "updatedAt":{"type":"string"}
                        }
                    }
                }
            }
        }))
        .response_schema(json!({
            "type":"object","additionalProperties":false,"required":["handled","rankings"],
            "properties":{
                "handled":{"type":"boolean"},
                "workerId":{"type":"string"},
                "workerVersion":{"type":"string"},
                "rankings":{
                    "type":"array","maxItems":256,
                    "items":{
                        "type":"object","additionalProperties":false,
                        "required":["workerId","score"],
                        "properties":{
                            "workerId":{"type":"string","minLength":1},
                            "score":{"type":"integer","minimum":0,"maximum":1000000000},
                            "reason":{"type":"string"}
                        }
                    }
                }
            }
        }))
        .idempotency(IdempotencyContract::session())
        .description("Invoke the active worker-owned semantic relevance policy, if any. Kernel callers retain deterministic local ranking as recovery.")
        .build()?,
    );
    specs.push(
        FunctionContract::new(
            "worker_kernel::inbox_attach",
            WORKER,
            EffectClass::ExternalSideEffect,
            RiskLevel::Medium)
        .visibility(FunctionVisibility::Internal)
        .request_schema(json!({
            "type":"object","additionalProperties":false,
            "properties":{
                "limit":{"type":"integer","minimum":1,"maximum":32},
                "relevanceQuery":{"type":"string","maxLength":12000},
                "originWorkerId":{"type":"string"}
            }
        }))
        .response_schema(json!({
            "type":"object","additionalProperties":false,
            "required":["handled","items","narrative"],
            "properties":{
                "handled":{"type":"boolean"},
                "workerId":{"type":"string"},
                "workerVersion":{"type":"string"},
                "narrative":{"type":"string","maxLength":12000},
                "items":{"type":"array","maxItems":32,"items":{"type":"object"}}
            }
        }))
        .idempotency(IdempotencyContract::session())
        .description("Invoke worker-owned pending-result context policy, atomically attach its selected observations, and retain deterministic recovery when no hook is active.")
        .build()?,
    );
    specs.push(
        FunctionContract::new(
            "worker_kernel::webhook_invoke",
            WORKER,
            EffectClass::ExternalSideEffect,
            RiskLevel::High)
        .visibility(FunctionVisibility::Internal)
        .request_schema(json!({"type":"object","additionalProperties":false,"required":["workerId","triggerId","token","input","idempotencyKey"],"properties":{"workerId":{"type":"string"},"triggerId":{"type":"string"},"token":{"type":"string"},"input":{},"idempotencyKey":{"type":"string"}}}))
        .response_schema(open_response())
        .idempotency(IdempotencyContract::profile())
        .description("Authenticated local webhook dispatch into the persistent worker runtime.")
        .build()?,
    );
    Ok(specs)
}

fn expected_sha256_schema(allow_absent: bool) -> Value {
    let (pattern, description) = if allow_absent {
        (
            "^(?:absent|(?:sha256:)?[0-9A-Fa-f]{64})$",
            "Optional compare-and-swap precondition. Omit for an unconditional write, use the exact string `absent` to require a new file, or supply sha256:<hex> / raw 64-digit hex after reading an existing file.",
        )
    } else {
        (
            "^(?:sha256:)?[0-9A-Fa-f]{64}$",
            "Optional compare-and-swap precondition from filesystem_read or a prior mutation. Omit it instead of sending an empty string.",
        )
    };
    json!({"type":"string","pattern":pattern,"description":description})
}

fn spec(
    function: &'static str,
    effect: EffectClass,
    risk: RiskLevel,
    request: Value,
    description: &'static str,
) -> crate::engine::Result<FunctionDefinition> {
    let mut contract = FunctionContract::new(function, WORKER, effect, risk)
        .request_schema(request)
        .response_schema(response_schema(function))
        .description(description);
    if effect.requires_idempotency() {
        contract = contract.idempotency(if profile_owned_worker_operation(function) {
            IdempotencyContract::profile()
        } else {
            IdempotencyContract::session()
        });
    }
    contract.build()
}

fn profile_owned_worker_operation(function: &str) -> bool {
    matches!(
        function,
        "worker_kernel::upsert"
            | "worker_kernel::invoke"
            | "worker_kernel::cancel"
            | "worker_kernel::stop"
            | "worker_kernel::disable"
            | "worker_kernel::enable"
            | "worker_kernel::retire"
            | "worker_kernel::purge"
            | "worker_kernel::rollback"
            | "worker_kernel::webhook_rotate"
            | "worker_kernel::stop_all"
    )
}

#[cfg(test)]
mod tests;
