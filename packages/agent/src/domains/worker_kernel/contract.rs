use serde::Serialize;
use serde_json::{Value, json};

use crate::domains::registration::catalog::{CapabilitySpec, TransportIdempotencyMode};
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{EffectClass, IdempotencyContract, RiskLevel, VisibilityScope};

const WORKER: &str = "worker_kernel";
pub(crate) const ENGINE_SURFACE_SNAPSHOT_FUNCTION: &str = "engine::surface_snapshot";
pub(super) const DEFAULT_TEXT_SEARCH_TIMEOUT_SECONDS: u64 = 5;
pub(super) const MAX_TEXT_SEARCH_TIMEOUT_SECONDS: u64 = 60;
pub(super) const DEFAULT_TEXT_SEARCH_WALK_ENTRIES: usize = 20_000;
pub(super) const MAX_TEXT_SEARCH_WALK_ENTRIES: usize = 100_000;

/// Stable model-facing primitive families.
///
/// This is deliberately narrower than the complete worker-kernel contract:
/// internal webhook and inbox projection functions are kernel mechanics, not
/// model vocabulary.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum CorePrimitiveGroup {
    Host,
    WorkerControl,
    CoreChange,
}

impl CorePrimitiveGroup {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Host => "host",
            Self::WorkerControl => "worker_control",
            Self::CoreChange => "core_change",
        }
    }
}

/// One canonical model-facing primitive identity.
///
/// Contracts, handlers, provider projection, dashboard projection, and tests
/// must derive identity and ordering from this manifest instead of maintaining
/// parallel name maps.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct CorePrimitiveDescriptor {
    pub(crate) operation_key: &'static str,
    pub(crate) model_name: &'static str,
    pub(crate) group: CorePrimitiveGroup,
    pub(crate) order: u16,
}

const CORE_PRIMITIVES: &[CorePrimitiveDescriptor] = &[
    CorePrimitiveDescriptor {
        operation_key: "filesystem_read",
        model_name: "filesystem_read",
        group: CorePrimitiveGroup::Host,
        order: 10,
    },
    CorePrimitiveDescriptor {
        operation_key: "filesystem_list",
        model_name: "filesystem_list",
        group: CorePrimitiveGroup::Host,
        order: 20,
    },
    CorePrimitiveDescriptor {
        operation_key: "filesystem_search_text",
        model_name: "filesystem_search_text",
        group: CorePrimitiveGroup::Host,
        order: 30,
    },
    CorePrimitiveDescriptor {
        operation_key: "filesystem_write",
        model_name: "filesystem_write",
        group: CorePrimitiveGroup::Host,
        order: 40,
    },
    CorePrimitiveDescriptor {
        operation_key: "filesystem_edit",
        model_name: "filesystem_edit",
        group: CorePrimitiveGroup::Host,
        order: 45,
    },
    CorePrimitiveDescriptor {
        operation_key: "process_run",
        model_name: "process_run",
        group: CorePrimitiveGroup::Host,
        order: 50,
    },
    CorePrimitiveDescriptor {
        operation_key: "web_fetch",
        model_name: "web_fetch",
        group: CorePrimitiveGroup::Host,
        order: 60,
    },
    CorePrimitiveDescriptor {
        operation_key: "upsert",
        model_name: "worker_upsert",
        group: CorePrimitiveGroup::WorkerControl,
        order: 100,
    },
    CorePrimitiveDescriptor {
        operation_key: "discover",
        model_name: "worker_discover",
        group: CorePrimitiveGroup::WorkerControl,
        order: 110,
    },
    CorePrimitiveDescriptor {
        operation_key: "list",
        model_name: "worker_list",
        group: CorePrimitiveGroup::WorkerControl,
        order: 120,
    },
    CorePrimitiveDescriptor {
        operation_key: "inspect",
        model_name: "worker_inspect",
        group: CorePrimitiveGroup::WorkerControl,
        order: 130,
    },
    CorePrimitiveDescriptor {
        operation_key: "invoke",
        model_name: "worker_invoke",
        group: CorePrimitiveGroup::WorkerControl,
        order: 140,
    },
    CorePrimitiveDescriptor {
        operation_key: "await",
        model_name: "worker_await",
        group: CorePrimitiveGroup::WorkerControl,
        order: 145,
    },
    CorePrimitiveDescriptor {
        operation_key: "stop",
        model_name: "worker_stop",
        group: CorePrimitiveGroup::WorkerControl,
        order: 150,
    },
    CorePrimitiveDescriptor {
        operation_key: "disable",
        model_name: "worker_disable",
        group: CorePrimitiveGroup::WorkerControl,
        order: 160,
    },
    CorePrimitiveDescriptor {
        operation_key: "enable",
        model_name: "worker_enable",
        group: CorePrimitiveGroup::WorkerControl,
        order: 170,
    },
    CorePrimitiveDescriptor {
        operation_key: "rollback",
        model_name: "worker_rollback",
        group: CorePrimitiveGroup::WorkerControl,
        order: 180,
    },
    CorePrimitiveDescriptor {
        operation_key: "retire",
        model_name: "worker_retire",
        group: CorePrimitiveGroup::WorkerControl,
        order: 190,
    },
    CorePrimitiveDescriptor {
        operation_key: "purge",
        model_name: "worker_purge",
        group: CorePrimitiveGroup::WorkerControl,
        order: 200,
    },
    CorePrimitiveDescriptor {
        operation_key: "inbox",
        model_name: "worker_inbox",
        group: CorePrimitiveGroup::WorkerControl,
        order: 210,
    },
    CorePrimitiveDescriptor {
        operation_key: "runs",
        model_name: "worker_runs",
        group: CorePrimitiveGroup::WorkerControl,
        order: 220,
    },
    CorePrimitiveDescriptor {
        operation_key: "webhook_rotate",
        model_name: "worker_webhook_rotate",
        group: CorePrimitiveGroup::WorkerControl,
        order: 230,
    },
    CorePrimitiveDescriptor {
        operation_key: "stop_all",
        model_name: "worker_stop_all",
        group: CorePrimitiveGroup::WorkerControl,
        order: 240,
    },
    CorePrimitiveDescriptor {
        operation_key: "core_proposal_create",
        model_name: "core_proposal_create",
        group: CorePrimitiveGroup::CoreChange,
        order: 300,
    },
    CorePrimitiveDescriptor {
        operation_key: "core_proposal_list",
        model_name: "core_proposal_list",
        group: CorePrimitiveGroup::CoreChange,
        order: 310,
    },
    CorePrimitiveDescriptor {
        operation_key: "core_proposal_inspect",
        model_name: "core_proposal_inspect",
        group: CorePrimitiveGroup::CoreChange,
        order: 320,
    },
    CorePrimitiveDescriptor {
        operation_key: "core_proposal_apply",
        model_name: "core_proposal_apply",
        group: CorePrimitiveGroup::CoreChange,
        order: 330,
    },
];

pub(crate) const fn core_primitives() -> &'static [CorePrimitiveDescriptor] {
    CORE_PRIMITIVES
}

pub(crate) fn core_primitive_for_operation(
    operation_key: &str,
) -> Option<&'static CorePrimitiveDescriptor> {
    core_primitives()
        .iter()
        .find(|descriptor| descriptor.operation_key == operation_key)
}

/// Server-owned architectural component shown by engine introspection.
/// Components explain the compiled substrate without pretending that internal
/// services are additional model tools.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CoreComponentDescriptor {
    pub(crate) id: &'static str,
    pub(crate) title: &'static str,
    pub(crate) role: &'static str,
    pub(crate) category: &'static str,
    pub(crate) status: &'static str,
}

const CORE_COMPONENTS: &[CoreComponentDescriptor] = &[
    CoreComponentDescriptor {
        id: "model_agent_execution",
        title: "Model & Agent Execution",
        role: "Runs provider-neutral model turns and direct typed tool calls.",
        category: "kernel",
        status: "active",
    },
    CoreComponentDescriptor {
        id: "host_substrate",
        title: "Host Substrate",
        role: "Owns filesystem, process, network, schema, and function routing mechanics.",
        category: "kernel",
        status: "active",
    },
    CoreComponentDescriptor {
        id: "durable_truth",
        title: "Durable Truth",
        role: "Persists sessions, events, causal traces, state, audit evidence, and recovery records.",
        category: "kernel",
        status: "active",
    },
    CoreComponentDescriptor {
        id: "worker_runtime",
        title: "Worker Runtime",
        role: "Versions, activates, dispatches, triggers, supervises, and recovers persistent workers.",
        category: "kernel",
        status: "active",
    },
    CoreComponentDescriptor {
        id: "secret_observation_boundary",
        title: "Secret & Provenance Boundary",
        role: "Injects declared named secrets and records redacted provenance and operational evidence.",
        category: "kernel",
        status: "active",
    },
    CoreComponentDescriptor {
        id: "authenticated_transport",
        title: "Authenticated Transport",
        role: "Connects trusted clients without projecting client APIs as model vocabulary.",
        category: "product_infrastructure",
        status: "active",
    },
    CoreComponentDescriptor {
        id: "settings_provider_shell",
        title: "Settings & Provider Shell",
        role: "Owns engine settings, provider credentials, protocol adapters, and application lifecycle.",
        category: "product_infrastructure",
        status: "active",
    },
    CoreComponentDescriptor {
        id: "core_change_guard",
        title: "Core-Change Guard",
        role: "Custodies isolated tested proposals and requires later conversational approval before application.",
        category: "protected_boundary",
        status: "active",
    },
];

pub(crate) const fn core_components() -> &'static [CoreComponentDescriptor] {
    CORE_COMPONENTS
}

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
        json!({"type":"object","additionalProperties":false,"required":["path","content"],"properties":{"path":{"type":"string"},"content":{"type":"string"},"createParents":{"type":"boolean"},"expectedSha256":{"type":"string","description":"Optional compare-and-swap precondition. Use sha256:<hex>, raw hex, or absent when creating a new file."}}}),
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
                "expectedSha256":{"type":"string","description":"Optional compare-and-swap precondition from filesystem_read or a prior mutation."},
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
        "Apply a tested core proposal only after verifying a later, unambiguous, non-negated user-authored conversational approval that names it.",
    )?);
    specs.push(spec(
        "worker_kernel::upsert",
        EffectClass::ExternalSideEffect,
        RiskLevel::High,
        json!({
            "type":"object","additionalProperties":false,"required":["bundle"],
            "properties":{
                "bundle":worker_bundle_schema(),
                "sourceDirectory":{"type":"string","description":"Optional local directory containing staged UTF-8 worker source. Files are imported recursively into bundle.files; explicit inline files win. Use this after authoring and testing locally so the model does not read and echo file contents back through JSON."},
                "predecessorWorkerId":{"type":"string"}
            }
        }),
        "Create or improve a persistent worker in one atomic validate, test, activate operation. This schema is the complete authoring contract: do not search Tron's files for private examples. Author source in a temporary directory and pass sourceDirectory instead of reading and echoing files into the call. Command runners and smoke/health commands start in files/, read typed JSON from stdin, and emit JSON on stdout; fetched dependency <name> is available at ../dependencies/<name>, and its optional install command runs inside that dependency directory first. A dependency may omit checksum; this operation fetches it and seals the actual digest into the immutable bundle. Engine-event input supplies typed defaults; matching top-level event payload keys declared by inputSchema override them, and Tron never injects an event envelope.",
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
        "Permanently purge a previously retired worker, its bundle, runs, and inbox history.",
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
        "Stop or resume all persistent worker dispatch for this engine.",
    )?);
    specs.push(
        CapabilityContract::new(
            ENGINE_SURFACE_SNAPSHOT_FUNCTION,
            "engine",
            EffectClass::PureRead,
            RiskLevel::Low)
        .domain_worker(WORKER)
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
            "required":["format","autonomousWorkers","dispatchStopped","coreComponents","fixedTools","surface","workers"],
            "properties":{
                "format":{"type":"integer"},
                "autonomousWorkers":{"type":"boolean"},
                "dispatchStopped":{"type":"boolean"},
                "coreComponents":{"type":"array"},
                "fixedTools":{"type":"array"},
                "surface":{
                    "type":"object",
                    "additionalProperties":false,
                    "required":["format","catalogRevision","surfaceHash","fixedToolCount","projectedWorkerCount","availableWorkerCount","tools","availableWorkers"],
                    "properties":{
                        "format":{"type":"integer"},
                        "catalogRevision":{"type":"integer"},
                        "surfaceHash":{"type":"string"},
                        "fixedToolCount":{"type":"integer"},
                        "projectedWorkerCount":{"type":"integer"},
                        "availableWorkerCount":{"type":"integer"},
                        "tools":{"type":"array"},
                        "availableWorkers":{"type":"array"}
                    }
                },
                "workers":{"type":"array"}
            }
        }))
        .description(
            "Return authoritative fixed-tool, selected-worker, and engine worker inventory for authenticated clients.",
        )
        .tags(vec!["kernel", "introspection", "workers", "surface"])
        .build()?,
    );
    specs.push(
        CapabilityContract::new(
            "worker_kernel::inbox_attach",
            WORKER,
            EffectClass::IdempotentWrite,
            RiskLevel::Low)
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
            RiskLevel::High)
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
    let mut contract = CapabilityContract::new(function, WORKER, effect, risk)
        .request_schema(request)
        .response_schema(response_schema(function))
        .description(description)
        .tags(vec!["kernel", "worker", "self-extension", "persistent"]);
    if effect.requires_idempotency() {
        contract = contract
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .idempotency_mode(TransportIdempotencyMode::ExplicitRequired);
    }
    contract.build()
}

fn response_schema(function: &str) -> Value {
    match function {
        "worker_kernel::filesystem_read" => json!({
            "type":"object","additionalProperties":false,
            "required":["path","content","bytes","retainedBytes","truncated"],
            "properties":{"path":{"type":"string"},"content":{"type":"string"},"bytes":{},"retainedBytes":{"type":"integer"},"truncated":{"type":"boolean"}}
        }),
        "worker_kernel::filesystem_list" => json!({
            "type":"object","additionalProperties":false,
            "required":["path","entries","visitedEntries","resultLimitReached","walkLimitReached","truncated"],
            "properties":{"path":{"type":"string"},"entries":{"type":"array"},"visitedEntries":{"type":"integer"},"resultLimitReached":{"type":"boolean"},"walkLimitReached":{"type":"boolean"},"truncated":{"type":"boolean"}}
        }),
        "worker_kernel::filesystem_search_text" => json!({
            "type":"object","additionalProperties":false,
            "required":["query","path","matches","visitedEntries","skippedDirectories","resultLimitReached","walkLimitReached","timeLimitReached","truncated"],
            "properties":{"query":{"type":"string"},"path":{"type":"string"},"matches":{"type":"array"},"visitedEntries":{"type":"integer"},"skippedDirectories":{"type":"integer"},"resultLimitReached":{"type":"boolean"},"walkLimitReached":{"type":"boolean"},"timeLimitReached":{"type":"boolean"},"truncated":{"type":"boolean"}}
        }),
        "worker_kernel::filesystem_write" => mutation_file_response_schema(false),
        "worker_kernel::filesystem_edit" => mutation_file_response_schema(true),
        "worker_kernel::process_run" => json!({
            "type":"object","additionalProperties":false,
            "required":["command","cwd","status","success","stdout","stderr","stdoutTruncated","stderrTruncated"],
            "properties":{"command":{"type":"array"},"cwd":{"type":"string"},"status":{},"success":{"type":"boolean"},"stdout":{"type":"string"},"stderr":{"type":"string"},"stdoutTruncated":{"type":"boolean"},"stderrTruncated":{"type":"boolean"}}
        }),
        "worker_kernel::web_fetch" => json!({
            "type":"object","additionalProperties":false,
            "required":["url","status","contentType","contentLength","observedBytes","retainedBytes","truncated","content"],
            "properties":{"url":{"type":"string"},"status":{"type":"integer"},"contentType":{},"contentLength":{},"observedBytes":{"type":"integer"},"retainedBytes":{"type":"integer"},"truncated":{"type":"boolean"},"content":{"type":"string"}}
        }),
        "worker_kernel::core_proposal_create"
        | "worker_kernel::core_proposal_inspect"
        | "worker_kernel::core_proposal_apply" => core_proposal_response_schema(),
        "worker_kernel::core_proposal_list" => json!({
            "type":"object","additionalProperties":false,"required":["proposals"],
            "properties":{"proposals":{"type":"array","items":core_proposal_response_schema()}}
        }),
        "worker_kernel::upsert" => json!({
            "type":"object","additionalProperties":false,
            "required":["worker","version","created","replacedWorkerId","webhooks"],
            "properties":{"worker":worker_summary_response_schema(),"version":{"type":"string"},"created":{"type":"boolean"},"replacedWorkerId":{},"webhooks":{"type":"array"},"sourceImport":{"type":"object"}}
        }),
        "worker_kernel::discover" => json!({
            "type":"object","additionalProperties":false,"required":["query","workers"],
            "properties":{"query":{"type":"string"},"workers":{"type":"array"}}
        }),
        "worker_kernel::list" => json!({
            "type":"object","additionalProperties":false,"required":["workers","stopAll"],
            "properties":{"workers":{"type":"array","items":worker_summary_response_schema()},"stopAll":{"type":"boolean"}}
        }),
        "worker_kernel::inspect" => json!({
            "type":"object","additionalProperties":false,
            "required":["worker","bundle","route","versions","triggers","healthHistory","audit","versionDirectory"],
            "properties":{"worker":worker_summary_response_schema(),"bundle":{"type":"object"},"route":{},"versions":{"type":"array"},"triggers":{"type":"array"},"healthHistory":{"type":"array"},"audit":{"type":"array"},"versionDirectory":{"type":"string"}}
        }),
        "worker_kernel::invoke" => invocation_response_schema(),
        "worker_kernel::await" => json!({
            "type":"object","additionalProperties":false,"required":["invocation","timedOut"],
            "properties":{"invocation":invocation_response_schema(),"timedOut":{"type":"boolean"}}
        }),
        "worker_kernel::stop"
        | "worker_kernel::disable"
        | "worker_kernel::enable"
        | "worker_kernel::retire" => worker_summary_response_schema(),
        "worker_kernel::rollback" => json!({
            "type":"object","additionalProperties":false,"required":["worker","webhooks"],
            "properties":{"worker":worker_summary_response_schema(),"webhooks":{"type":"array"}}
        }),
        "worker_kernel::purge" => json!({
            "type":"object","additionalProperties":false,"required":["workerId","purged"],
            "properties":{"workerId":{"type":"string"},"purged":{"type":"boolean"}}
        }),
        "worker_kernel::inbox" => json!({
            "type":"object","additionalProperties":false,"required":["items"],
            "properties":{"items":{"type":"array"}}
        }),
        "worker_kernel::runs" => json!({
            "type":"object","additionalProperties":false,"required":["runs","attempts","traces"],
            "properties":{"runs":{"type":"array","items":invocation_response_schema()},"attempts":{"type":"object"},"traces":{"type":"object"}}
        }),
        "worker_kernel::webhook_rotate" => webhook_credential_response_schema(),
        "worker_kernel::stop_all" => json!({
            "type":"object","additionalProperties":false,"required":["stopped"],
            "properties":{"stopped":{"type":"boolean"}}
        }),
        _ => open_response(),
    }
}

fn mutation_file_response_schema(include_replacements: bool) -> Value {
    let mut properties = serde_json::Map::from_iter([
        ("path".to_owned(), json!({"type":"string"})),
        ("bytes".to_owned(), json!({"type":"integer"})),
        ("changed".to_owned(), json!({"type":"boolean"})),
        ("previousSha256".to_owned(), json!({})),
        ("sha256".to_owned(), json!({"type":"string"})),
    ]);
    let mut required = vec!["path", "bytes", "changed", "previousSha256", "sha256"];
    if include_replacements {
        let _ = properties.insert("replacementsApplied".to_owned(), json!({"type":"integer"}));
        required.push("replacementsApplied");
    } else {
        let _ = properties.insert("written".to_owned(), json!({"type":"boolean"}));
        required.push("written");
    }
    json!({"type":"object","additionalProperties":false,"required":required,"properties":properties})
}

fn worker_summary_response_schema() -> Value {
    json!({
        "type":"object","additionalProperties":false,
        "required":["workerId","name","description","toolName","runnerKind","activeVersion","enabled","retired","health","triggerCount","updatedAt"],
        "properties":{"workerId":{"type":"string"},"name":{"type":"string"},"description":{"type":"string"},"toolName":{"type":"string"},"runnerKind":{"type":"string"},"activeVersion":{"type":"string"},"enabled":{"type":"boolean"},"retired":{"type":"boolean"},"health":{"type":"string"},"triggerCount":{"type":"integer"},"updatedAt":{"type":"string"}}
    })
}

fn invocation_response_schema() -> Value {
    json!({
        "type":"object","additionalProperties":false,
        "required":["invocationId","workerId","workerVersion","status","input","output","error","idempotencyKey","traceId","causalDepth","triggerKind","attemptCount","createdAt","startedAt","completedAt"],
        "properties":{"invocationId":{"type":"string"},"workerId":{"type":"string"},"workerVersion":{"type":"string"},"status":{"type":"string"},"input":{},"output":{},"error":{},"idempotencyKey":{"type":"string"},"traceId":{"type":"string"},"causalDepth":{"type":"integer"},"triggerKind":{"type":"string"},"attemptCount":{"type":"integer"},"createdAt":{"type":"string"},"startedAt":{},"completedAt":{}}
    })
}

fn webhook_credential_response_schema() -> Value {
    json!({
        "type":"object","additionalProperties":false,"required":["triggerId","path","token"],
        "properties":{"triggerId":{"type":"string"},"path":{"type":"string"},"token":{"type":"string"}}
    })
}

fn core_proposal_response_schema() -> Value {
    json!({
        "type":"object","additionalProperties":false,
        "required":["proposalId","title","intent","repositoryPath","worktreePath","branch","commit","testCommand","testOutput","status","createdAt","appliedAt","appliedCommit","approvalSessionId","approvalMessageId"],
        "properties":{"proposalId":{"type":"string"},"title":{"type":"string"},"intent":{"type":"string"},"repositoryPath":{"type":"string"},"worktreePath":{"type":"string"},"branch":{"type":"string"},"commit":{"type":"string"},"testCommand":{"type":"array"},"testOutput":{"type":"string"},"status":{"type":"string"},"createdAt":{"type":"string"},"appliedAt":{},"appliedCommit":{},"approvalSessionId":{},"approvalMessageId":{}}
    })
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
        "description":"Complete self-contained persistent worker bundle. No external proposal, installer, binding, or private source documentation is required.",
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
                "description":"Optional stable direct tool name. Plain names are normalized to the worker_<name> namespace automatically; omit to retain the predecessor name or derive it from the worker name."
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
                            "command":{"type":"array","minItems":1,"items":{"type":"string"},"description":"Program and arguments executed with files/ as the working directory. Refer to a fetched dependency named N through ../dependencies/N."}
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
                "description":"Relative source-file paths mapped to complete UTF-8 string contents. They are materialized beneath files/, the working directory for runner, smoke-test, and health-check commands.",
                "additionalProperties":{"type":"string"}
            },
            "dependencies":{
                "type":"array",
                "items":{
                    "type":"object","additionalProperties":false,
                    "required":["name","source","version"],
                    "properties":{
                        "name":{"type":"string"},
                        "source":{"type":"string","description":"Use file:// for a local source, git+https:// for a repository, or http(s):// for one downloaded file. The acquired source is materialized at ../dependencies/<name> relative to files/."},
                        "version":{"type":"string","description":"Exact version or source revision; never latest or a range."},
                        "checksum":{"type":"string","description":"Optional expected sha256:<64 hex> source-tree digest. Omit it to let worker_upsert fetch the exact version and persist the actual digest automatically."},
                        "install":{
                            "type":"object",
                            "additionalProperties":false,
                            "required":["command"],
                            "description":"Optional isolated setup command executed with this dependency's ../dependencies/<name> directory as its working directory before smoke tests.",
                            "properties":{
                                "command":{"type":"array","minItems":1,"items":{"type":"string"}},
                                "timeoutSeconds":{"type":"integer","minimum":1,"maximum":7200}
                            }
                        }
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
            "smokeTests":{"type":"array","description":"Pre-activation commands executed from files/ after dependencies and their install commands are ready.","items":command},
            "healthChecks":{"type":"array","description":"Pre-activation commands executed from files/ after dependencies and their install commands are ready.","items":command},
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
#[path = "contract_tests.rs"]
mod tests;
