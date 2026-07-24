//! Strict response schemas for fixed primitive contracts.

use serde_json::{Value, json};

pub(super) fn response_schema(function: &str) -> Value {
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
            "required":["url","status","contentType","contentLength","observedBytes","retainedBytes","contentSha256","truncated","content"],
            "properties":{"url":{"type":"string"},"status":{"type":"integer"},"contentType":{},"contentLength":{},"observedBytes":{"type":"integer"},"retainedBytes":{"type":"integer"},"contentSha256":{"type":"string"},"truncated":{"type":"boolean"},"content":{"type":"string"}}
        }),
        "worker_kernel::session_set_title" => json!({
            "type":"object","additionalProperties":false,
            "required":["sessionId","title","updated"],
            "properties":{"sessionId":{"type":"string"},"title":{"type":"string"},"updated":{"type":"boolean"}}
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
            "required":["detail","worker","bundle","route","versions","triggers","versionDirectory"],
            "properties":{"detail":{"type":"string","enum":["contract","full"]},"worker":worker_summary_response_schema(),"bundle":{"type":"object"},"route":{},"versions":{"type":"array"},"triggers":{"type":"array"},"healthHistory":{"type":"array"},"audit":{"type":"array"},"versionDirectory":{"type":"string"}}
        }),
        "worker_kernel::invoke" => invocation_response_schema(),
        "worker_kernel::cancel" | "worker_kernel::detach" => invocation_response_schema(),
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
            "type":"object","additionalProperties":false,"required":["workerId","purged","archivePath","archiveSha256"],
            "properties":{"workerId":{"type":"string"},"purged":{"type":"boolean"},"archivePath":{"type":"string"},"archiveSha256":{"type":"string"}}
        }),
        "worker_kernel::inbox" => json!({
            "type":"object","additionalProperties":false,"required":["detail","items","returned","truncated","nextOffset","contentTruncated"],
            "properties":{"detail":{"type":"string","enum":["summary","full"]},"items":{"type":"array"},"returned":{"type":"integer"},"truncated":{"type":"boolean"},"nextOffset":{},"contentTruncated":{"type":"boolean"}}
        }),
        "worker_kernel::runs" => json!({
            "type":"object","additionalProperties":false,"required":["detail","runs","attempts","traces","graphs","returned","truncated","nextOffset","contentTruncated"],
            "properties":{"detail":{"type":"string","enum":["summary","full","graph"]},"runs":{"type":"array","items":invocation_response_schema()},"attempts":{"type":"object"},"traces":{"type":"object"},"graphs":{"type":"array","items":worker_run_graph_response_schema()},"returned":{"type":"integer"},"truncated":{"type":"boolean"},"nextOffset":{},"contentTruncated":{"type":"boolean"}}
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
        "properties":{"workerId":{"type":"string"},"name":{"type":"string"},"description":{"type":"string"},"toolName":{"type":"string"},"runnerKind":{"type":"string"},"activeVersion":{"type":"string"},"enabled":{"type":"boolean"},"retired":{"type":"boolean"},"health":{"type":"string"},"triggerCount":{"type":"integer"},"updatedAt":{"type":"string"},"presentation":presentation_response_schema()}
    })
}

fn invocation_response_schema() -> Value {
    json!({
        "type":"object","additionalProperties":false,
        "required":["invocationId","workerId","workerVersion","status","input","output","error","idempotencyKey","traceId","causalDepth","triggerKind","interactionMode","attemptCount","createdAt","startedAt","completedAt"],
        "properties":{"invocationId":{"type":"string"},"workerId":{"type":"string"},"workerVersion":{"type":"string"},"status":{"type":"string"},"input":{},"output":{},"error":{},"idempotencyKey":{"type":"string"},"traceId":{"type":"string"},"causalDepth":{"type":"integer"},"triggerKind":{"type":"string"},"originSessionId":{"type":"string"},"agentSessionId":{"type":"string"},"interactionMode":{"type":"string","enum":["foreground","background"]},"detachedAt":{"type":"string"},"modelToolInvocationId":{"type":"string"},"parentWorkerInvocationId":{"type":"string"},"retryOfInvocationId":{"type":"string"},"attemptCount":{"type":"integer"},"createdAt":{"type":"string"},"startedAt":{},"completedAt":{}}
    })
}

fn worker_run_graph_response_schema() -> Value {
    let stage = json!({
        "type":"string",
        "enum":[
            "queued","planning","specialist_execution","retry_repair",
            "synthesis","validation","publication","detached","completed",
            "failed","cancelled","interrupted"
        ]
    });
    let counts = json!({
        "type":"object","additionalProperties":false,
        "required":["queued","running","completed","failed","cancelled"],
        "properties":{
            "queued":{"type":"integer"},"running":{"type":"integer"},
            "completed":{"type":"integer"},"failed":{"type":"integer"},
            "cancelled":{"type":"integer"}
        }
    });
    let timing = json!({
        "type":"object","additionalProperties":false,
        "required":["queueMs","executionMs","wallMs","modelMs","childCriticalPathMs","criticalPathMs","criticalPathNodeIds"],
        "properties":{
            "queueMs":{"type":"integer"},"executionMs":{"type":"integer"},
            "wallMs":{"type":"integer"},"modelMs":{"type":"integer"},
            "childCriticalPathMs":{"type":"integer"},"criticalPathMs":{"type":"integer"},
            "criticalPathNodeIds":{"type":"array","items":{"type":"string"}}
        }
    });
    let usage = json!({
        "type":"object","additionalProperties":false,
        "required":["inputTokens","outputTokens","cacheReadTokens","cacheCreationTokens","cost"],
        "properties":{
            "inputTokens":{"type":"integer"},"outputTokens":{"type":"integer"},
            "cacheReadTokens":{"type":"integer"},"cacheCreationTokens":{"type":"integer"},
            "cost":{"type":"number"}
        }
    });
    let node = json!({
        "type":"object","additionalProperties":false,
        "required":["id","kind","parentId","status","elapsedMs"],
        "properties":{
            "id":{"type":"string"},
            "kind":{"type":"string","enum":["invocation","attempt","agent","model"]},
            "parentId":{},"invocationId":{"type":"string"},"workerId":{"type":"string"},
            "workerName":{"type":"string"},"workerVersion":{"type":"string"},
            "runner":{"type":"string"},"status":{"type":"string"},"mode":{"type":"string"},
            "stage":stage.clone(),"createdAt":{"type":"string"},"startedAt":{},
            "completedAt":{},"elapsedMs":{"type":"integer"},"queueMs":{"type":"integer"},
            "executionMs":{"type":"integer"},"attemptCount":{"type":"integer"},
            "attemptNumber":{"type":"integer"},"sessionId":{},
            "model":{"type":"string"},"turn":{"type":"integer"},
            "modelToolInvocationId":{},"retryOfInvocationId":{},
            "inputTokens":{"type":"integer"},"outputTokens":{"type":"integer"},
            "cacheReadTokens":{"type":"integer"},"cacheCreationTokens":{"type":"integer"},
            "cost":{"type":"number"},"resultPreview":{},
            "errorPreview":{},"presentation":{}
        }
    });
    let timeline = json!({
        "type":"object","additionalProperties":false,
        "required":["occurredAt","nodeId","stage","status","summary","technical"],
        "properties":{
            "occurredAt":{"type":"string"},"nodeId":{"type":"string"},
            "stage":stage.clone(),"status":{"type":"string"},"summary":{"type":"string"},
            "technical":{"type":"boolean"},"invocationId":{"type":"string"}
        }
    });
    json!({
        "type":"object","additionalProperties":false,
        "required":[
            "rootInvocationId","requestedInvocationId","modelToolInvocationId",
            "originSessionId","workerId","workerName","requestPreview","status",
            "mode","stage","stageLabel","expectedNextTransition","createdAt",
            "startedAt","completedAt","elapsedMs","counts","timing","usage",
            "nodes","timeline","resultPreview","errorPreview","truncated"
        ],
        "properties":{
            "rootInvocationId":{"type":"string"},"requestedInvocationId":{"type":"string"},
            "modelToolInvocationId":{},"originSessionId":{},"workerId":{"type":"string"},
            "workerName":{"type":"string"},"requestPreview":{"type":"string"},
            "status":{"type":"string"},"mode":{"type":"string","enum":["foreground","background"]},
            "stage":stage,"stageLabel":{"type":"string"},"expectedNextTransition":{},
            "createdAt":{"type":"string"},"startedAt":{},"completedAt":{},
            "elapsedMs":{"type":"integer"},"counts":counts,"timing":timing,"usage":usage,
            "nodes":{"type":"array","items":node},"timeline":{"type":"array","items":timeline},
            "resultPreview":{},"errorPreview":{},"truncated":{"type":"boolean"}
        }
    })
}

fn presentation_response_schema() -> Value {
    json!({
        "type":"object","additionalProperties":false,
        "required":["experienceId","contractVersion","primary"],
        "properties":{"experienceId":{"type":"string"},"contractVersion":{"type":"integer"},"suiteId":{"type":"string"},"componentRole":{"type":"string"},"primary":{"type":"boolean"}}
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
        "required":["proposalId","title","intent","repositoryPath","branch","commit","testCommand","testOutput","status","createdAt","appliedAt","appliedCommit","approvalSessionId","approvalMessageId"],
        "properties":{"proposalId":{"type":"string"},"title":{"type":"string"},"intent":{"type":"string"},"repositoryPath":{"type":"string"},"branch":{"type":"string"},"commit":{"type":"string"},"testCommand":{"type":"array"},"testOutput":{"type":"string"},"status":{"type":"string"},"createdAt":{"type":"string"},"appliedAt":{},"appliedCommit":{},"approvalSessionId":{},"approvalMessageId":{}}
    })
}

pub(super) fn worker_id_schema(include_version: bool) -> Value {
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

pub(super) fn open_response() -> Value {
    json!({"type":"object","additionalProperties":true})
}
