//! Fixed worker-kernel function contracts.
//!
//! Each executable contract owns its optional model name, audience, group, and
//! ordering. Provider projection and introspection derive from those
//! definitions; no parallel primitive manifest is retained. `response` owns
//! output schemas, `bundle` owns the complete atomic worker-authoring schema,
//! `introspection` owns the closed authenticated architecture projection, and
//! `support` owns shared builders and bounded validation. Contract tests live
//! beside those owners.

use serde_json::json;

use crate::domains::registration::contract::FunctionContract;
use crate::engine::{
    EffectClass, FunctionDefinition, FunctionVisibility, IdempotencyContract, ModelToolAudience,
    RiskLevel,
};

mod bundle;
mod introspection;
mod response;
mod support;

use introspection::worker_architecture_response_schema;
pub(crate) use response::worker_result_reference_schema;
use response::{open_response, worker_id_schema};
pub(crate) use support::{estimate_context_summary_tokens, validate_context_summary_narrative};
use support::{expected_sha256_schema, model_spec, spec};

const WORKER: &str = "worker_kernel";
const WORKER_UPSERT_DESCRIPTION: &str = "\
Create or improve a persistent worker in one atomic validate, test, activate operation. \
Canonical authoring protocol: (1) use worker_discover, worker_list, or worker_inspect only when existing-worker context is useful; semantic overlap is also checked during upsert; \
(2) design the complete typed bundle from this public operation schema, including runner, triggers, named-secret bindings, provenance, smoke tests, and health checks; \
(3) author and exercise source in a temporary directory with the public host tools, then pass sourceDirectory instead of echoing files into the call; \
(4) call worker_upsert once to import, validate, dependency-lock, smoke-test, atomically publish, activate, and, when modelExposure is direct, project the direct tool; \
(5) use the returned worker id/version and public worker tools to verify behavior. \
Use modelExposure=direct only for an intuitive ordinary agent-facing capability and always declare a narrow, outcome-oriented toolInputSchema without internal coordination fields. Use modelExposure=internal for hook, trigger, client-action, worker-dispatch, or exact agentTools specialist owners that should not advertise an ordinary model tool. inputSchema always remains the complete runtime contract. \
For sparse background work, a worker may explicitly declare and emit one closed workerWakeup object to durably invoke the same immutable version at its next useful time; do not add a short periodic trigger merely to poll for work. \
This operation description and request schema are the complete authoritative authoring contract. Never inspect or modify Tron databases, auth stores, binaries, runtime files, lock files, or private server endpoints to infer schemas, activate a worker, or discover hidden steps. \
If a required behavior is absent from the public contract, report a concrete engine-contract gap instead of guessing or probing internals. Inspect external sources and user workspace data only when they are inputs to the worker's useful behavior. \
Imported source is published as non-executable text: command runners and smoke/health commands use exact argv without shell parsing, start in files/, and must invoke scripts through an explicit interpreter such as python3 or bash. They read typed JSON from stdin and emit JSON on stdout. \
A fetched dependency <name> is available at ../dependencies/<name>; its optional install command runs inside that dependency directory first. A dependency may omit checksum; worker_upsert fetches it and seals the actual digest into the immutable bundle. \
Engine-event input supplies typed defaults; matching top-level event payload keys declared by inputSchema override them. bundle.engineHooks contains the complete authoritative engine-hook contracts.";
pub(crate) const ENGINE_SURFACE_SNAPSHOT_FUNCTION: &str = "engine::surface_snapshot";
pub(crate) const CONTINUITY_CONTEXT_FUNCTION: &str = "worker_kernel::continuity_context";
pub(crate) const CONTEXT_SUMMARY_FUNCTION: &str = "worker_kernel::context_summary";
pub(crate) const CONTEXT_SUMMARY_MAX_ESTIMATED_TOKENS: usize = 10_000;
pub(crate) const CONTEXT_SUMMARY_MAX_NARRATIVE_BYTES: usize = 40_000;
pub(crate) const SESSION_TITLE_FUNCTION: &str = "worker_kernel::session_title";
pub(crate) const WORKER_RESULT_PROJECTION_FUNCTION: &str = "worker_kernel::result_projection";
pub(super) const DEFAULT_TEXT_SEARCH_TIMEOUT_SECONDS: u64 = 5;
pub(super) const MAX_TEXT_SEARCH_TIMEOUT_SECONDS: u64 = 60;
pub(super) const DEFAULT_TEXT_SEARCH_WALK_ENTRIES: usize = 20_000;
pub(super) const MAX_TEXT_SEARCH_WALK_ENTRIES: usize = 100_000;

pub(crate) fn background_worker_receipt_message(invocation_id: &str) -> String {
    format!(
        "The durable worker run is continuing in the background. \
Do not poll it or call worker_await. If this task should resume automatically \
when the worker finishes, call agent_wait_for_workers now with \
{{\"invocationIds\":[\"{invocation_id}\"],\"mode\":\"all\"}}. Otherwise report \
that it is running; its passive result will appear in Delivery & Wait Status."
    )
}

pub(super) fn function_definitions() -> crate::engine::Result<Vec<FunctionDefinition>> {
    let mut specs = Vec::new();
    specs.push(model_spec(
        "worker_kernel::filesystem_read",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({"type":"object","additionalProperties":false,"required":["path"],"properties":{"path":{"type":"string"},"maxBytes":{"type":"integer","minimum":1,"maximum":4194304}}}),
        "Read a local UTF-8 file directly with the trusted local user's access.",
        "filesystem_read",
        ModelToolAudience::Ordinary,
        10,
        "host",
    )?);
    specs.push(model_spec(
        "worker_kernel::filesystem_list",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({"type":"object","additionalProperties":false,"properties":{"path":{"type":"string"},"maxResults":{"type":"integer","minimum":1,"maximum":5000},"maxWalkEntries":{"type":"integer","minimum":1,"maximum":50000}}}),
        "List a local directory with deterministic ordering and explicit result and traversal ceilings.",
        "filesystem_list",
        ModelToolAudience::Ordinary,
        20,
        "host",
    )?);
    specs.push(model_spec(
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
        "filesystem_search_text",
        ModelToolAudience::Ordinary,
        30,
        "host",
    )?);
    specs.push(model_spec(
        "worker_kernel::filesystem_write",
        EffectClass::IdempotentWrite,
        RiskLevel::High,
        json!({"type":"object","additionalProperties":false,"required":["path","content"],"properties":{"path":{"type":"string"},"content":{"type":"string"},"createParents":{"type":"boolean"},"expectedSha256":expected_sha256_schema(true)}}),
        "Atomically publish a complete local text file. Supply expectedSha256 after reading when overwriting concurrent work would be unsafe.",
        "filesystem_write",
        ModelToolAudience::Ordinary,
        40,
        "host",
    )?);
    specs.push(model_spec(
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
        "filesystem_edit",
        ModelToolAudience::Ordinary,
        45,
        "host",
    )?);
    specs.push(model_spec(
        "worker_kernel::process_run",
        EffectClass::ExternalSideEffect,
        RiskLevel::High,
        json!({"type":"object","additionalProperties":false,"required":["command"],"properties":{"command":{"type":"array","minItems":1,"maxItems":256,"items":{"type":"string"}},"cwd":{"type":"string"},"stdin":{},"timeoutSeconds":{"type":"integer","minimum":1,"maximum":7200}}}),
        "Run a local command directly with normal user permissions and bounded output. Pass structured JSON directly as stdin and the engine serializes it once; string stdin is written verbatim, so never pre-encode a JSON object into a string.",
        "process_run",
        ModelToolAudience::Ordinary,
        50,
        "host",
    )?);
    specs.push(model_spec(
        "worker_kernel::web_fetch",
        EffectClass::ExternalSideEffect,
        RiskLevel::Medium,
        json!({"type":"object","additionalProperties":false,"required":["url"],"properties":{"url":{"type":"string"},"maxBytes":{"type":"integer","minimum":1,"maximum":4194304,"default":131072},"timeoutSeconds":{"type":"integer","minimum":1,"maximum":120,"default":30}}}),
        "Fetch one explicit HTTP or HTTPS URL directly and return bounded raw UTF-8 source content, redirect/status metadata, and a retained-content checksum. The context-safe default retains 128 KiB; request a larger ceiling only when needed.",
        "web_fetch",
        ModelToolAudience::Ordinary,
        60,
        "host",
    )?);
    specs.push(spec(
        "worker_kernel::notification_device_upsert",
        EffectClass::IdempotentWrite,
        RiskLevel::Medium,
        json!({
            "type":"object","additionalProperties":false,
            "required":[
                "installationId","clientServerId","topic","environment",
                "authorizationStatus"
            ],
            "properties":{
                "installationId":{"type":"string","minLength":1,"maxLength":160},
                "clientServerId":{"type":"string","minLength":1,"maxLength":160},
                "topic":{"type":"string","enum":["com.tron.mobile.beta","com.tron.mobile"]},
                "environment":{"type":"string","enum":["sandbox","production"]},
                "authorizationStatus":{"type":"string","enum":[
                    "not_determined","denied","authorized","provisional","ephemeral"
                ]},
                "token":{"type":"string","minLength":32,"maxLength":512}
            }
        }),
        "Register this authenticated iOS installation's current APNs readiness. Device tokens are accepted only for delivery and are never returned or logged.",
    )?);
    specs.push(spec(
        "worker_kernel::notification_device_disable",
        EffectClass::IdempotentWrite,
        RiskLevel::Medium,
        json!({
            "type":"object","additionalProperties":false,
            "required":["installationId"],
            "properties":{"installationId":{"type":"string","minLength":1,"maxLength":160}}
        }),
        "Disable notification delivery to one authenticated iOS installation.",
    )?);
    specs.push(spec(
        "worker_kernel::notification_deliveries",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({
            "type":"object","additionalProperties":false,
            "properties":{
                "cursor":{"type":"string","minLength":1,"maxLength":160},
                "limit":{"type":"integer","minimum":1,"maximum":200},
                "unreadOnly":{"type":"boolean"}
            }
        }),
        "Synchronize a bounded page of logical notification inbox state and the authoritative unread count.",
    )?);
    specs.push(spec(
        "worker_kernel::notification_delivery_acknowledge",
        EffectClass::IdempotentWrite,
        RiskLevel::Medium,
        json!({
            "type":"object","additionalProperties":false,
            "required":[
                "deliveryId","installationId","clientMutationId","acknowledgement"
            ],
            "properties":{
                "deliveryId":{"type":"string","minLength":1,"maxLength":160},
                "installationId":{"type":"string","minLength":1,"maxLength":160},
                "clientMutationId":{"type":"string","minLength":1,"maxLength":160},
                "acknowledgement":{"type":"string","enum":[
                    "opened","complete","snooze","clear_unread"
                ]},
                "occurredAt":{"type":"string","maxLength":64}
            }
        }),
        "Record one idempotent native notification response. The first terminal response wins; clear_unread never completes worker-owned work.",
    )?);
    specs.push(spec(
        "worker_kernel::notification_delivery_status",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({
            "type":"object","additionalProperties":false,
            "required":["deliveryId"],
            "properties":{"deliveryId":{"type":"string","minLength":1,"maxLength":160}}
        }),
        "Read one logical notification and its sanitized per-installation APNs evidence. APNs acceptance is not represented as human delivery.",
    )?);
    specs.push(spec(
        "worker_kernel::artifact_deliveries",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({
            "type":"object","additionalProperties":false,
            "properties":{
                "limit":{"type":"integer","minimum":1,"maximum":200},
                "offset":{"type":"integer","minimum":0,"maximum":1000000}
            }
        }),
        "Read a bounded page of content-addressed native artifacts and immutable source trace metadata.",
    )?);
    specs.push(spec(
        "worker_kernel::artifact_content",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({
            "type":"object","additionalProperties":false,
            "required":["workerId","artifactId"],
            "properties":{
                "workerId":{"type":"string","minLength":1,"maxLength":128},
                "artifactId":{"type":"string","minLength":1,"maxLength":128}
            }
        }),
        "Read exact integrity-verified base64 content for one native artifact.",
    )?);
    specs.push(spec(
        "worker_kernel::artifact_delete",
        EffectClass::IdempotentWrite,
        RiskLevel::Medium,
        json!({
            "type":"object","additionalProperties":false,
            "required":["workerId","artifactId"],
            "properties":{
                "workerId":{"type":"string","minLength":1,"maxLength":128},
                "artifactId":{"type":"string","minLength":1,"maxLength":128}
            }
        }),
        "Explicitly delete one native artifact and its content custody. Artifacts are never removed by normal diagnostic retention.",
    )?);
    specs.push(model_spec(
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
        "worker_upsert",
        ModelToolAudience::Specialist,
        100,
        "worker_administration",
    )?);
    specs.push(model_spec(
        "worker_kernel::discover",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({"type":"object","additionalProperties":false,"required":["query"],"properties":{"query":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":50}}}),
        "Find persistent workers relevant to a task and make their typed tools discoverable.",
        "worker_discover",
        ModelToolAudience::Ordinary,
        110,
        "worker_interaction",
    )?);
    specs.push(model_spec(
        "worker_kernel::list",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({"type":"object","additionalProperties":false,"properties":{"includeRetired":{"type":"boolean"}}}),
        "List persistent workers and their health, version, runner, and trigger status.",
        "worker_list",
        ModelToolAudience::Specialist,
        120,
        "worker_administration",
    )?);
    specs.push(model_spec(
        "worker_kernel::inspect",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({"type":"object","additionalProperties":false,"required":["workerId"],"properties":{"workerId":{"type":"string"},"detail":{"type":"string","enum":["contract","full"],"default":"contract","description":"contract returns the active behavioral contract without source files or operational history; full includes the immutable source manifest and bounded history for operator clients."}}}),
        "Inspect one worker. The context-safe default returns its active typed contract, provenance, triggers, and versions; request detail=full only for immutable source metadata and operational history.",
        "worker_inspect",
        ModelToolAudience::Specialist,
        130,
        "worker_administration",
    )?);
    specs.push(model_spec(
        "worker_kernel::invoke",
        EffectClass::ExternalSideEffect,
        RiskLevel::High,
        json!({
            "type":"object",
            "additionalProperties":false,
            "properties":{
                "workerId":{"type":"string"},
                "input":{},
                "model":{"type":"string","minLength":1,"description":"Optional model override for this invocation of an agent runner."},
                "reasoningLevel":{"type":"string","minLength":1,"description":"Optional reasoning override validated against the resolved model."},
                "idempotencyKey":{"type":"string"},
                "retryOfInvocationId":{"type":"string","description":"Retry one terminal invocation using its immutable worker version and original typed input."},
                "mode":{"type":"string","enum":["wait","enqueue"],"description":"wait uses the interaction budget and may return a detached running record; enqueue returns immediately after durable admission."}
            },
            "oneOf":[
                {"required":["workerId","input"],"not":{"required":["retryOfInvocationId"]}},
                {"required":["retryOfInvocationId"],"not":{"anyOf":[{"required":["workerId"]},{"required":["input"]},{"required":["idempotencyKey"]},{"required":["model"]},{"required":["reasoningLevel"]}]}}
            ]
        }),
        "Invoke an enabled persistent worker by id with typed JSON input, or retry one terminal invocation from its immutable contract. Predicted or unexpectedly slow top-level waits return the same durable invocation in background mode; nested worker calls remain synchronous.",
        "worker_invoke",
        ModelToolAudience::Ordinary,
        140,
        "worker_interaction",
    )?);
    specs.push(model_spec(
        "worker_kernel::await",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({"type":"object","additionalProperties":false,"required":["invocationId"],"properties":{"invocationId":{"type":"string"},"timeoutSeconds":{"type":"integer","minimum":0,"maximum":10}}}),
        "Observe one durable worker invocation for at most the ten-second interaction budget. A wait timeout returns current state and never cancels the worker.",
        "worker_await",
        ModelToolAudience::Ordinary,
        145,
        "worker_interaction",
    )?);
    specs.push(model_spec(
        "worker_kernel::agent_send",
        EffectClass::IdempotentWrite,
        RiskLevel::Medium,
        json!({
            "type":"object",
            "additionalProperties":false,
            "required":["target","content"],
            "properties":{
                "target":{
                    "type":"object",
                    "additionalProperties":false,
                    "required":["kind"],
                    "properties":{
                        "kind":{"type":"string","enum":["session","new_task","mailbox"]},
                        "sessionId":{"type":"string"},
                        "title":{"type":"string","maxLength":120},
                        "model":{"type":"string","minLength":1},
                        "workingDirectory":{"type":"string","minLength":1},
                        "scope":{"type":"string","enum":["workspace","profile"]},
                        "name":{"type":"string","maxLength":64}
                    }
                },
                "content":{"type":"string","minLength":1,"maxLength":40000},
                "intent":{"type":"string","enum":["information","request"],"default":"information"},
                "wakePolicy":{"type":"string","enum":["passive","wake"],"default":"passive"},
                "boundary":{"type":"string","enum":["next_turn","next_run"],"default":"next_turn"},
                "expiresAt":{"type":"string"}
            }
        }),
        "Send bounded untrusted reference context to a same-workspace task, atomically create and seed a visible task, or place it in a workspace/profile mailbox. Mailboxes are passive; wake requests start only at safe run boundaries.",
        "agent_send",
        ModelToolAudience::Ordinary,
        130,
        "agent_coordination",
    )?);
    specs.push(model_spec(
        "worker_kernel::agent_wait_for_workers",
        EffectClass::IdempotentWrite,
        RiskLevel::Low,
        json!({
            "type":"object",
            "additionalProperties":false,
            "required":["invocationIds"],
            "properties":{
                "invocationIds":{"type":"array","minItems":1,"maxItems":32,"items":{"type":"string"}},
                "mode":{"type":"string","enum":["all","any"],"default":"all"}
            }
        }),
        "Register a durable non-blocking wait for top-level worker invocations owned by this session and causal trace. Completion, failure, or cancellation resumes through an agent delivery.",
        "agent_wait_for_workers",
        ModelToolAudience::Ordinary,
        131,
        "agent_coordination",
    )?);
    specs.push(model_spec(
        "worker_kernel::agent_mailbox_list",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({
            "type":"object",
            "additionalProperties":false,
            "required":["scope","name"],
            "properties":{
                "scope":{"type":"string","enum":["workspace","profile"]},
                "name":{"type":"string","maxLength":64},
                "limit":{"type":"integer","minimum":1,"maximum":100,"default":20}
            }
        }),
        "List bounded redacted summaries and opaque IDs from a workspace or profile mailbox without claiming or semantically interpreting them.",
        "agent_mailbox_list",
        ModelToolAudience::Ordinary,
        132,
        "agent_coordination",
    )?);
    specs.push(model_spec(
        "worker_kernel::agent_mailbox_claim",
        EffectClass::IdempotentWrite,
        RiskLevel::Low,
        json!({
            "type":"object",
            "additionalProperties":false,
            "required":["deliveryIds"],
            "properties":{
                "deliveryIds":{"type":"array","minItems":1,"maxItems":8,"items":{"type":"string"}}
            }
        }),
        "Atomically claim explicitly listed mailbox deliveries into this session as passive next-turn reference context. Concurrent claims have exactly one winner.",
        "agent_mailbox_claim",
        ModelToolAudience::Ordinary,
        133,
        "agent_coordination",
    )?);
    specs.push(model_spec(
        "worker_kernel::result_read",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({
            "type":"object",
            "additionalProperties":false,
            "required":["invocationId"],
            "properties":{
                "invocationId":{"type":"string"},
                "pointer":{"type":"string","maxLength":2048,"description":"RFC 6901 JSON pointer. Omit or use an empty string for the result root."},
                "offset":{"type":"integer","minimum":0},
                "limit":{"type":"integer","minimum":1,"maximum":20}
            }
        }),
        "Read one bounded JSON path/page from an exact validated durable worker result. Prefer passing a worker_result_reference directly to a downstream worker that accepts it; otherwise read only the path needed and follow nextOffset when present.",
        "worker_result_read",
        ModelToolAudience::Ordinary,
        148,
        "worker_interaction",
    )?);
    specs.push(spec(
        "worker_kernel::result_handoff",
        EffectClass::IdempotentWrite,
        RiskLevel::Medium,
        json!({
            "type":"object",
            "additionalProperties":false,
            "required":["invocationId","workingDirectory","model","title"],
            "properties":{
                "invocationId":{"type":"string","minLength":1,"maxLength":160},
                "workingDirectory":{"type":"string","minLength":1},
                "model":{"type":"string","minLength":1,"maxLength":160},
                "title":{"type":"string","minLength":1,"maxLength":120}
            }
        }),
        "Create one visible chat with a passive, exact-result grant for an authenticated client's completed worker result. The session and grant commit atomically; result bytes remain in durable worker custody.",
    )?);
    specs.push(model_spec(
        "worker_kernel::detach",
        EffectClass::ReversibleSideEffect,
        RiskLevel::Low,
        json!({"type":"object","additionalProperties":false,"required":["invocationId"],"properties":{"invocationId":{"type":"string"}}}),
        "Release foreground ownership of one queued or running durable invocation without cancelling or recreating it.",
        "worker_detach",
        ModelToolAudience::Specialist,
        146,
        "worker_administration",
    )?);
    specs.push(model_spec(
        "worker_kernel::cancel",
        EffectClass::ReversibleSideEffect,
        RiskLevel::High,
        json!({"type":"object","additionalProperties":false,"required":["invocationId"],"properties":{"invocationId":{"type":"string"}}}),
        "Cancel one queued or running worker invocation without stopping unrelated work or disabling its worker.",
        "worker_cancel",
        ModelToolAudience::Ordinary,
        147,
        "worker_interaction",
    )?);
    for (method, model_name, order, description) in [
        (
            "worker_kernel::stop",
            "worker_stop",
            150,
            "Stop one worker's current invocations and resident service without disabling future dispatch.",
        ),
        (
            "worker_kernel::disable",
            "worker_disable",
            160,
            "Disable and stop one persistent worker immediately.",
        ),
        (
            "worker_kernel::enable",
            "worker_enable",
            170,
            "Enable a persistent worker and restore its typed tool.",
        ),
        (
            "worker_kernel::retire",
            "worker_retire",
            190,
            "Recoverably retire a worker while preserving versions and run history.",
        ),
    ] {
        specs.push(model_spec(
            method,
            EffectClass::ReversibleSideEffect,
            RiskLevel::High,
            worker_id_schema(false),
            description,
            model_name,
            ModelToolAudience::Specialist,
            order,
            "worker_administration",
        )?);
    }
    specs.push(model_spec(
        "worker_kernel::purge",
        EffectClass::IrreversibleSideEffect,
        RiskLevel::Critical,
        worker_id_schema(false),
        "Create a verified recovery archive, then purge a previously retired worker's live bundle, state, runs, and inbox history.",
        "worker_purge",
        ModelToolAudience::Specialist,
        200,
        "worker_administration",
    )?);
    specs.push(model_spec(
        "worker_kernel::rollback",
        EffectClass::ReversibleSideEffect,
        RiskLevel::High,
        json!({"type":"object","additionalProperties":false,"required":["workerId","version"],"properties":{"workerId":{"type":"string"},"version":{"type":"string"}}}),
        "Activate a retained last-known version of a persistent worker.",
        "worker_rollback",
        ModelToolAudience::Specialist,
        180,
        "worker_administration",
    )?);
    specs.push(model_spec(
        "worker_kernel::inbox",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({"type":"object","additionalProperties":false,"properties":{"workerId":{"type":"string"},"contextAttached":{"type":"boolean"},"severity":{"type":"string","enum":["info","error"]},"attentionOnly":{"type":"boolean","default":false},"limit":{"type":"integer","minimum":1,"maximum":20},"offset":{"type":"integer","minimum":0},"detail":{"type":"string","enum":["summary","full"],"default":"summary"}}}),
        "Read a bounded page of durable worker delivery records. Filter by whether a result was attached to later agent context, severity, or the high-signal attention projection. Attention contains unresolved failures and setup blockers, never successful informational history. Exact bounded timeouts from the deterministic-fallback worker-relevance and inbox-context hooks remain failed audit history without becoming current Attention or future agent context; malformed output and every other hook failure remain actionable. A later verified healthy activation or rollback resolves older failures without deleting them from this audit ledger; merely enabling a failed worker does not. Successful outcomes remain available in the unfiltered audit ledger and may separately be eligible for one-time relevant agent context. Omit workerId to query the entire profile; continue with nextOffset when present. Compact summaries are the default; explicit full detail is bounded to 20 records and 8 KiB per result.",
        "worker_inbox",
        ModelToolAudience::Specialist,
        210,
        "worker_administration",
    )?);
    specs.push(model_spec(
        "worker_kernel::runs",
        EffectClass::PureRead,
        RiskLevel::Low,
        json!({"type":"object","additionalProperties":false,"properties":{"workerId":{"type":"string"},"originSessionId":{"type":"string"},"invocationId":{"type":"string"},"modelToolInvocationId":{"type":"string"},"status":{"type":"string","enum":["queued","running","completed","failed","cancelled"]},"limit":{"type":"integer","minimum":1,"maximum":20},"offset":{"type":"integer","minimum":0},"detail":{"type":"string","enum":["summary","metrics","full","graph"],"default":"summary"}}}),
        "List a bounded page of durable worker invocations, optionally filtered by exact invocation, originating model-tool call, worker, originating chat session, or execution status. A session filter includes descendant worker calls from the same causal trace even when they ran through child agent sessions. Metrics detail returns a compact exact-invocation timing, usage, model, version, and status projection without the causal graph's nodes or timeline. Graph detail reconstructs at most ten causal roots from authoritative invocation, attempt, stage, agent-session, model-turn, and child-link evidence, with structured timing and timeline entries. Omit filters to query the profile; continue with nextOffset when present. Compact summaries omit expansion by default; explicit full detail is bounded to 20 records and 8 KiB per input or output.",
        "worker_runs",
        ModelToolAudience::Specialist,
        220,
        "worker_administration",
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
            "required":["dispatchStopped","nativeCapabilities","activeEngineHooks","activeClientActions","activeClientDeliveries","fixedTools","surface","workers","workerArchitecture"],
            "properties":{
                "dispatchStopped":{"type":"boolean"},
                "nativeCapabilities":{"type":"array","items":{"type":"string"}},
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
                "activeClientDeliveries":{
                    "type":"array",
                    "items":{
                        "type":"object",
                        "additionalProperties":false,
                        "required":["delivery","workerId","workerVersion"],
                        "properties":{
                            "delivery":{"type":"string"},
                            "workerId":{"type":"string"},
                            "workerVersion":{"type":"string"}
                        }
                    }
                },
                "fixedTools":{"type":"array"},
                "surface":{
                    "type":"object",
                    "additionalProperties":false,
                    "required":[
                        "catalogRevision","surfaceHash","fixedToolCount",
                        "ordinaryFixedToolCount","specialistFixedToolCount",
                        "conditionalFixedToolCount","projectedWorkerCount",
                        "availableWorkerCount","availableWorkers"
                    ],
                    "properties":{
                        "catalogRevision":{"type":"integer"},
                        "surfaceHash":{"type":"string"},
                        "fixedToolCount":{"type":"integer"},
                        "ordinaryFixedToolCount":{"type":"integer"},
                        "specialistFixedToolCount":{"type":"integer"},
                        "conditionalFixedToolCount":{"type":"integer"},
                        "projectedWorkerCount":{"type":"integer"},
                        "availableWorkerCount":{"type":"integer"},
                        "availableWorkers":{"type":"array"}
                    }
                },
                "workers":{"type":"array"},
                "workerArchitecture":worker_architecture_response_schema()
            }
        }))
        .description(
            "Return authoritative fixed-tool, selected-worker, and engine worker inventory for authenticated clients.",
        )
        .build()?,
    );
    specs.push(
        FunctionContract::new(
            CONTINUITY_CONTEXT_FUNCTION,
            WORKER,
            EffectClass::ExternalSideEffect,
            RiskLevel::Medium)
        .visibility(FunctionVisibility::Internal)
        .request_schema(json!({
            "type":"object",
            "additionalProperties":false,
            "required":["query"],
            "properties":{
                "query":{"type":"string","minLength":1,"maxLength":12000},
                "project":{"type":"string","minLength":1,"maxLength":2048},
                "originWorkerId":{"type":"string"}
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
                "invocationId":{"type":"string"},
                "narrative":{"type":"string","maxLength":6000},
                "sources":{
                    "type":"array","maxItems":6,
                    "items":{
                        "type":"object","additionalProperties":false,
                        "required":["memoryId","revision","scope"],
                        "properties":{
                            "memoryId":{"type":"string","minLength":1,"maxLength":96},
                            "revision":{"type":"integer","minimum":1},
                            "scope":{"type":"string","enum":["global","project"]},
                            "project":{"type":"string","maxLength":2048}
                        }
                    }
                }
            }
        }))
        .idempotency(IdempotencyContract::session())
        .description("Recall bounded project-first continuity through the active worker-owned memory policy. Missing, empty, or failed recall adds no provider context.")
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
            "required":["handled","queued","updated"],
            "properties":{
                "handled":{"type":"boolean"},
                "queued":{"type":"boolean"},
                "updated":{"type":"boolean"},
                "invocationId":{"type":"string"},
                "workerId":{"type":"string"},
                "workerVersion":{"type":"string"}
            }
        }))
        .idempotency(IdempotencyContract::session())
        .description("Durably enqueue the active worker-owned title policy after the first successful exchange of an untitled ordinary session. The admission receipt never waits for execution; explicit titles and worker audit sessions are never eligible.")
        .build()?,
    );
    specs.push(
        FunctionContract::new(
            "worker_kernel::mailbox_curate",
            WORKER,
            EffectClass::IdempotentWrite,
            RiskLevel::Medium,
        )
        .visibility(FunctionVisibility::Internal)
        .request_schema(json!({
            "type":"object","additionalProperties":false,
            "required":["sessionId"],
            "properties":{"sessionId":{"type":"string","minLength":1}}
        }))
        .response_schema(json!({
            "type":"object","additionalProperties":false,
            "required":["handled","candidateCount","claimedDeliveryIds"],
            "properties":{
                "handled":{"type":"boolean"},
                "candidateCount":{"type":"integer","minimum":0,"maximum":32},
                "workerId":{"type":"string"},
                "workerVersion":{"type":"string"},
                "invocationId":{"type":"string"},
                "claimedDeliveryIds":{
                    "type":"array","maxItems":8,"uniqueItems":true,
                    "items":{"type":"string"}
                }
            }
        }))
        .idempotency(IdempotencyContract::session())
        .description("Asynchronously curate eligible workspace/profile mailbox candidates for one newly created visible session. No candidates or no healthy policy worker is a successful no-op.")
        .build()?,
    );
    specs.push(
        FunctionContract::new(
            WORKER_RESULT_PROJECTION_FUNCTION,
            WORKER,
            EffectClass::PureRead,
            RiskLevel::Low,
        )
        .visibility(FunctionVisibility::Internal)
        .request_schema(json!({
            "type":"object",
            "additionalProperties":false,
            "properties":{
                "modelToolInvocationIds":{
                    "type":"array","maxItems":256,"uniqueItems":true,
                    "items":{"type":"string","minLength":1,"maxLength":256}
                },
                "invocationIds":{
                    "type":"array","maxItems":256,"uniqueItems":true,
                    "items":{"type":"string","minLength":1,"maxLength":256}
                },
                "freshModelToolInvocationIds":{
                    "type":"array","maxItems":256,"uniqueItems":true,
                    "items":{"type":"string","minLength":1,"maxLength":256}
                },
                "freshInvocationIds":{
                    "type":"array","maxItems":256,"uniqueItems":true,
                    "items":{"type":"string","minLength":1,"maxLength":256}
                }
            }
        }))
        .response_schema(json!({
            "type":"object",
            "additionalProperties":false,
            "required":["items"],
            "properties":{
                "items":{"type":"array","maxItems":256,"items":{
                    "type":"object",
                    "additionalProperties":false,
                    "required":[
                        "modelToolInvocationId","invocationId","workerId",
                        "workerVersion","status","interactionMode","reference",
                        "providerValue","fresh"
                    ],
                    "properties":{
                        "modelToolInvocationId":{},
                        "invocationId":{"type":"string"},
                        "workerId":{"type":"string"},
                        "workerVersion":{"type":"string"},
                        "status":{"type":"string"},
                        "interactionMode":{"type":"string"},
                        "reference":{},
                        "providerValue":{},
                        "fresh":{"type":"boolean"}
                    }
                }}
            }
        }))
        .idempotency(IdempotencyContract::session())
        .description("Project canonical worker result references and one-turn fresh typed values for trusted provider-context reconstruction. This internal operation is not model vocabulary.")
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

#[cfg(test)]
mod tests;
