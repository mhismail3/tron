//! Complete model-discoverable schema for atomic worker authoring.
//!
//! Runtime decoding remains owned by `WorkerBundle`; this projection keeps the
//! atomic `worker_upsert` operation self-describing without a proposal,
//! installer, binding, or private source-documentation plane.

use serde_json::{Value, json};

const ENGINE_HOOK_AUTHORING_CONTRACT: &str = "\
Optional semantic engine roles activated atomically with this version. No separate binding or grant is required. \
The bundle inputSchema and outputSchema are the complete worker-facing contracts below; toolInputSchema affects only direct model calls and never changes an engine hook contract. These schemas are authoritative, so do not inspect Tron databases, auth stores, binaries, runtime files, or private server endpoints to discover hook schemas. \
continuity_context input is a closed object requiring action:continuity_context and query:string(1..12000), and permitting project:string(max 2048) and limit:integer(1..8); output must accept a closed object requiring narrative:string(max 6000), where an empty narrative means no continuity should be injected. It may also return sources:array(max 6) of closed {memoryId:string(max 96),revision:integer(min 1),scope:global|project,project?:string(max 2048)} records for request-specific audit provenance; older bundles may omit sources and are reported as provenance unavailable. The engine supplies the current working-directory identity as project when available, redacts sensitive credential shapes, and bounds the provider-context projection. \
session_organization input is a closed object requiring action:session_organization, one closed canonical session projection, and the completed userPrompt/assistantResponse strings(max 4096 each). Output requires one bounded proposal and may include the explicitly declared reserved sessionOrganizationMutations array(max 16). Each closed mutation names sessionId and only preserve, archive, or restore; replacement labels(max 12 strings of max 64 characters) and one nullable group(max 80) are optional. Omitted labels or group preserve canonical state, while explicit null clears the group. The engine preserves system tags and applies the exact batch durably after successful completion; delete and arbitrary tags are not expressible. \
session_title input is a closed object requiring userPrompt:string(max 4096) and assistantResponse:string(max 4096); output is a closed object requiring title:string(1..160). It runs after the first successful exchange of an untitled ordinary session. \
context_summary input is a closed object requiring messages:array(max 256) of closed {role:user|assistant|tool,text:string(max 4096)} and permitting originWorkerId:string; output is a closed object requiring narrative:string(1..40000 characters), with authoritative runtime ceilings of 10000 estimated tokens and 40000 UTF-8 bytes. \
mailbox_curation input is a closed object requiring sessionId:string and candidates:array(max 32) of closed {deliveryId,sourceKind,intent,preview,createdAt,expiresAt?} records; output is a closed object requiring selectedDeliveryIds:unique string array(max 8). The engine revalidates the selected subset and atomically claims all selected deliveries or none. \
worker_relevance input is a closed object requiring query:string(max 12000) and candidates:array(max 256) of closed worker summaries with workerId,name,description,intents,examples,provenance,completedRuns,updatedAt, and permitting originWorkerId:string; output is a closed object requiring rankings:array(max 256) of closed {workerId:string(min 1),score:integer(0..1000000000),reason?:string}.";

const ENGINE_DELIVERY_AUTHORING_CONTRACT: &str = "\
Optional worker-to-agent delivery effects activated atomically with this version. \
agent_delivery reserves the top-level output field agentDeliveries, which outputSchema must explicitly declare. When present it is an array(max 16) of closed objects requiring deduplicationKey:string(1..64 UTF-8 bytes without whitespace), target, and content:string(1..40000 UTF-8 bytes). \
target is either closed {kind:session,sessionId} or {kind:mailbox,scope:workspace|profile,name}. Optional policy is intent:information|request, wakePolicy:passive|wake, boundary:next_turn|next_run, and expiresAt:RFC3339. Mailboxes are always passive. \
The engine derives sender session, workspace, invocation, trace, root, causal depth, and result authority; same-workspace and mailbox-scope validation occurs again during durable import. Completion and immutable outbox effects are one workers transaction.";

const CLIENT_ACTION_AUTHORING_CONTRACT: &str = "\
Optional native-client actions activated atomically with this version. No separate binding, private endpoint, or client-specific installation is required. \
The bundle inputSchema and outputSchema are authoritative; do not inspect Tron databases, auth stores, binaries, runtime files, or private server endpoints to discover these contracts. \
speech_transcription input is a closed object requiring audioBase64:string(min 1), mimeType:string(min 1), and fileName:string(min 1). The iOS client supplies a mono PCM WAV recording as base64 with mimeType audio/wav. \
speech_transcription output is a closed object requiring text:string. It may additionally return language:string, durationSeconds:number(min 0), processingTimeMs:number(min 0), model:string, device:string, computeType:string, and cleanupMode:string. \
The worker owns decoding, speech recognition, model/dependency choice, text cleanup, and optional metadata. The client owns microphone permission, bounded capture, WAV encoding, durable invocation, and inserting the returned text into the draft.";

const CLIENT_DELIVERY_AUTHORING_CONTRACT: &str = "\
Optional worker-to-client deliveries activated atomically with this version. They are distinct from client-initiated actions and never grant general device control. \
notification_delivery reserves the top-level output field notificationDeliveries. When present it is an array(max 32) of closed objects requiring deduplicationKey:string(1..64 UTF-8 bytes), title:string(1..120 characters), body:string(1..512 characters), and expiresAt:future RFC3339 timestamp no later than 30 days. \
Each item may additionally carry notBefore:RFC3339 timestamp earlier than expiresAt, threadKey:string(1..64 UTF-8 bytes), sourceRecordId:string(1..128 UTF-8 bytes), actions:unique array containing only snooze or complete, and onOpen:complete. \
The engine generates delivery and routing identity, durably fans out to authenticated installations, and rejects arbitrary URLs, APNs dictionaries, sounds, priorities, media, device identifiers, or action names. \
artifact_delivery reserves the top-level output field artifactDeliveries, which outputSchema must explicitly declare. When present it is an array(max 8) of closed objects requiring artifactId:string(1..128 identifier bytes), displayName:safe file name(1..160 UTF-8 bytes), mediaType from the closed native-preview allowlist, sizeBytes:integer(1..2097152), and contentReference. \
contentReference is a closed {kind:worker_result_reference,invocationId,pointer,encoding:base64} object. It must name the current invocation and a non-root RFC 6901 pointer(max 256 bytes) resolving to base64 inside that invocation's validated result. Total decoded artifact bytes are capped at 2097152. The engine gives exact bytes content-addressed custody atomically with invocation completion. URLs, paths, active HTML, client commands, and draft mutations are not expressible.";

const WORKER_DISPATCH_AUTHORING_CONTRACT: &str = "\
Optional fixed asynchronous worker handoffs activated with this immutable version. Each route binds one route name to one targetWorkerId and a clientResponseOwner of source or target. \
Successful output may include the reserved workerDispatches array only when outputSchema explicitly declares that property. Each item is a closed object requiring route, deduplicationKey, and input. \
Output cannot choose a worker id, worker version, causal trace, session, device, response destination, or credential. The engine validates target input against the selected immutable target version, then atomically commits source completion, handoff evidence, and the queued child invocation. \
At most 32 handoffs are accepted per invocation; route and deduplication keys are at most 64 UTF-8 bytes, each input at most 64 KiB, and all inputs together at most 256 KiB. Handoffs are asynchronous only.";

const WORKER_WAKEUP_AUTHORING_CONTRACT: &str = "\
 A successful worker may request one durable future invocation of the same immutable worker version by explicitly declaring the reserved workerWakeup property in outputSchema and returning a closed {at,deduplicationKey,input} object. \
 at is a future RFC3339 timestamp no more than 366 days away; deduplicationKey contains 1..64 UTF-8 bytes without whitespace or controls; input is at most 64 KiB and must satisfy the complete inputSchema. \
 The worker cannot select another worker, version, trace, session, device, or credential. Completion and wakeup admission are one transaction. Use this for the next useful reconciliation time instead of an always-running short schedule trigger.";

fn presentation_action_schema() -> Value {
    json!({
        "type":"object",
        "additionalProperties":false,
        "required":["actionId","label","input"],
        "properties":{
            "actionId":{"type":"string","minLength":1,"maxLength":96},
            "label":{"type":"string","minLength":1,"maxLength":80},
            "input":{"type":"object"}
        }
    })
}

fn presentation_section_schema(
    kind: &str,
    extra_required: &[&str],
    extra_properties: Value,
) -> Value {
    let mut required = vec![json!("sectionId"), json!("kind")];
    required.extend(extra_required.iter().map(|field| json!(field)));
    let mut properties = serde_json::Map::from_iter([
        (
            "sectionId".to_owned(),
            json!({"type":"string","minLength":1,"maxLength":96}),
        ),
        ("kind".to_owned(), json!({"type":"string","const":kind})),
        (
            "title".to_owned(),
            json!({"type":"string","minLength":1,"maxLength":80}),
        ),
        (
            "detail".to_owned(),
            json!({"type":"string","minLength":1,"maxLength":512}),
        ),
    ]);
    if let Some(extra) = extra_properties.as_object() {
        properties.extend(extra.clone());
    }
    json!({
        "type":"object",
        "additionalProperties":false,
        "required":required,
        "properties":properties
    })
}

pub(super) fn presentation_schema() -> Value {
    let pointer = json!({
        "type":"string",
        "maxLength":256,
        "pattern":"^(?:|/(?:[^~]|~[01])*)$",
        "description":"RFC 6901 pointer into the exact durable invocation result."
    });
    let action = presentation_action_schema();
    let bound = |kind: &str| {
        presentation_section_schema(
            kind,
            &["valuePointer"],
            json!({"valuePointer":pointer.clone()}),
        )
    };
    json!({
        "type":"object",
        "additionalProperties":false,
        "required":["experienceId","contractVersion"],
        "description":"Optional immutable worker experience plus a closed declarative native presentation. Clients hydrate only bounded RFC 6901 result paths through worker_result_read and otherwise fall back to the generic Worker Console. HTML, JavaScript, custom native code, arbitrary client commands, and arbitrary URL schemes are not expressible.",
        "properties":{
            "experienceId":{"type":"string","minLength":1,"maxLength":96},
            "contractVersion":{"type":"integer","minimum":1},
            "suiteId":{"type":"string","minLength":1,"maxLength":96},
            "componentRole":{"type":"string","minLength":1,"maxLength":96},
            "primary":{"type":"boolean"},
            "sections":{
                "type":"array",
                "maxItems":24,
                "items":{
                    "oneOf":[
                        bound("text"),
                        bound("status"),
                        bound("progress"),
                        presentation_section_schema(
                            "table",
                            &["valuePointer","columns"],
                            json!({
                                "valuePointer":pointer.clone(),
                                "columns":{
                                    "type":"array","minItems":1,"maxItems":8,
                                    "items":{
                                        "type":"object","additionalProperties":false,
                                        "required":["label","valuePointer"],
                                        "properties":{
                                            "label":{"type":"string","minLength":1,"maxLength":80},
                                            "valuePointer":pointer.clone()
                                        }
                                    }
                                }
                            })
                        ),
                        bound("list"),
                        presentation_section_schema(
                            "link",
                            &["label","url"],
                            json!({
                                "label":{"type":"string","minLength":1,"maxLength":80},
                                "url":{"type":"string","minLength":1,"maxLength":2048,"pattern":"^https://"}
                            })
                        ),
                        presentation_section_schema(
                            "artifact",
                            &["label","valuePointer"],
                            json!({
                                "label":{"type":"string","minLength":1,"maxLength":80},
                                "valuePointer":pointer.clone()
                            })
                        ),
                        presentation_section_schema(
                            "confirmation",
                            &["title","detail","action"],
                            json!({"action":action.clone()})
                        ),
                        presentation_section_schema(
                            "worker_action",
                            &["action"],
                            json!({"action":action})
                        )
                    ]
                }
            }
        }
    })
}

fn agent_tools_schema() -> Value {
    json!({
        "type":"array",
        "maxItems":32,
        "uniqueItems":true,
        "items":{
            "type":"string",
            "minLength":1,
            "maxLength":64,
            "pattern":"^[A-Za-z0-9_-]+$"
        },
        "description":"Optional exact allowlist of model-tool names projected inside an agent-runner worker session. It is invalid for command and service runners. Omission preserves the migration surface; an empty array exposes no tools. Names must resolve to current fixed primitives or enabled direct/internal worker functions when the bundle activates. Internal names remain absent from ordinary agent discovery."
    })
}

pub(super) fn worker_bundle_schema() -> Value {
    let command = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["command"],
        "properties":{
            "command":{
                "type":"array","minItems":1,"items":{"type":"string"},
                "description":"Exact program-and-argument vector; no shell parsing occurs. Worker source files are published as non-executable text, so invoke scripts through an explicit interpreter such as python3 or bash."
            },
            "timeoutSeconds":{"type":"integer","minimum":1,"maximum":7200}
        }
    });
    let mut schema = json!({
        "type":"object",
        "additionalProperties":false,
        "description":"Complete self-contained persistent worker bundle. This public schema is authoritative: no external proposal, installer, binding, private source documentation, database inspection, binary inspection, or private endpoint discovery is required. If it cannot express required behavior, report an engine-contract gap instead of probing Tron internals.",
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
            "modelExposure":{
                "type":"string",
                "enum":["direct","internal"],
                "default":"direct",
                "description":"Whether this version publishes an ordinary agent model tool. direct is the migration default. internal remains absent from ordinary agent discovery while keeping hooks, triggers, client actions, worker dispatches, authenticated generic invocation, and exact agentTools specialist routing active through the same immutable worker function."
            },
            "toolInputSchema":{
                "type":"object",
                "description":"Required JSON object schema for every direct worker model tool. Keep it outcome-oriented and exclude trigger, event, worker-handoff, causal, and storage bookkeeping fields. It is invalid for internal workers. inputSchema remains authoritative for all runtime inputs, and every direct call is still validated against it before durable admission."
            },
            "inputSchema":{
                "type":"object",
                "description":"Complete JSON object schema for every typed runtime input, including direct calls, triggers, events, and worker handoffs."
            },
            "outputSchema":{
                "type":"object",
                "description":format!("JSON object schema for typed worker output.{WORKER_WAKEUP_AUTHORING_CONTRACT}")
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
                            "model":{"type":"string"},
                            "reasoningLevel":{"type":"string","enum":["none","low","medium","high","x_high","max"]}
                        }
                    },
                    {
                        "type":"object","additionalProperties":false,
                        "required":["kind","command"],
                        "properties":{
                            "kind":{"type":"string","enum":["command"]},
                            "command":{"type":"array","minItems":1,"items":{"type":"string"},"description":"Exact program-and-argument vector executed with files/ as the working directory; no shell parsing occurs. Worker source files are non-executable text, so invoke scripts through an explicit interpreter such as python3 or bash. Refer to a fetched dependency named N through ../dependencies/N."}
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
                "description":"Relative source-file paths mapped to complete UTF-8 string contents. They are materialized as non-executable text beneath files/, the working directory for runner, smoke-test, and health-check commands. Script commands must name an explicit interpreter.",
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
                "description":"Logical credential names only; use provider-<id> for a provider API key and never include secret values.",
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
            "engineHooks":{
                "type":"array",
                "uniqueItems":true,
                "description":ENGINE_HOOK_AUTHORING_CONTRACT,
                "items":{"type":"string","enum":["continuity_context","context_summary","mailbox_curation","session_organization","session_title","worker_relevance"]}
            },
            "clientActions":{
                "type":"array",
                "uniqueItems":true,
                "description":CLIENT_ACTION_AUTHORING_CONTRACT,
                "items":{"type":"string","enum":["speech_transcription"]}
            },
            "clientDeliveries":{
                "type":"array",
                "uniqueItems":true,
                "description":CLIENT_DELIVERY_AUTHORING_CONTRACT,
                "items":{"type":"string","enum":["notification_delivery","artifact_delivery"]}
            },
            "workerDispatchRoutes":{
                "type":"array",
                "uniqueItems":true,
                "description":WORKER_DISPATCH_AUTHORING_CONTRACT,
                "items":{
                    "type":"object",
                    "additionalProperties":false,
                    "required":["route","targetWorkerId","clientResponseOwner"],
                    "properties":{
                        "route":{"type":"string","minLength":1,"maxLength":64},
                        "targetWorkerId":{"type":"string","minLength":1},
                        "clientResponseOwner":{"type":"string","enum":["source","target"]}
                    }
                }
            },
            "executionLimits":{
                "type":"object",
                "additionalProperties":false,
                "description":"Optional worker-selected ceilings enforced generically by the kernel. These bound wall-clock invocation time, agent turns, and direct child worker calls without moving task-specific orchestration policy into the engine.",
                "properties":{
                    "maxInvocationSeconds":{"type":"integer","minimum":1,"maximum":7200},
                    "maxAgentTurns":{"type":"integer","minimum":1,"maximum":250},
                    "maxChildInvocations":{"type":"integer","minimum":0,"maximum":256}
                }
            },
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
            "presentation":presentation_schema(),
            "routing":{
                "type":"object","additionalProperties":false,
                "properties":{
                    "intents":{"type":"array","items":{"type":"string"}},
                    "examples":{"type":"array","items":{"type":"string"}}
                }
            }
        }
    });
    schema["properties"]["agentTools"] = agent_tools_schema();
    schema["properties"]["engineDeliveries"] = json!({
        "type":"array",
        "uniqueItems":true,
        "description":ENGINE_DELIVERY_AUTHORING_CONTRACT,
        "items":{"type":"string","enum":["agent_delivery"]}
    });
    schema
}
