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
        "worker_kernel::notification_device_upsert" => json!({
            "type":"object","additionalProperties":false,
            "required":["installationId","authorizationStatus","environment","topic","enabled","ready","registeredAt","transport"],
            "properties":{
                "installationId":{"type":"string"},"authorizationStatus":{"type":"string"},
                "environment":{"type":"string"},"topic":{"type":"string"},
                "enabled":{"type":"boolean"},"ready":{"type":"boolean"},
                "registeredAt":{"type":"string"},
                "transport":{
                    "type":"object","additionalProperties":false,
                    "required":["mode","configured"],
                    "properties":{
                        "mode":{"type":"string","enum":["relay","direct"]},
                        "configured":{"type":"boolean"},
                        "problemCode":{"type":"string"}
                    }
                }
            }
        }),
        "worker_kernel::notification_device_disable" => json!({
            "type":"object","additionalProperties":false,
            "required":["installationId","enabled","changed"],
            "properties":{
                "installationId":{"type":"string"},"enabled":{"type":"boolean"},
                "changed":{"type":"boolean"}
            }
        }),
        "worker_kernel::notification_deliveries" => json!({
            "type":"object","additionalProperties":false,
            "required":["deliveries","unreadCount","nextCursor"],
            "properties":{
                "deliveries":{"type":"array"},"unreadCount":{"type":"integer"},
                "nextCursor":{}
            }
        }),
        "worker_kernel::notification_delivery_acknowledge" => json!({
            "type":"object","additionalProperties":false,
            "required":[
                "deliveryId","clientMutationId","acknowledgement","accepted",
                "currentTerminalResponse","read","eventRequired","workerId",
                "sourceRecordId","traceId","occurredAt"
            ],
            "properties":{
                "deliveryId":{"type":"string"},"clientMutationId":{"type":"string"},
                "acknowledgement":{"type":"string"},"accepted":{"type":"boolean"},
                "currentTerminalResponse":{},"read":{"type":"boolean"},
                "eventRequired":{"type":"boolean"},"workerId":{"type":"string"},
                "sourceRecordId":{},"traceId":{"type":"string"},"occurredAt":{"type":"string"}
            }
        }),
        "worker_kernel::notification_delivery_status" => json!({
            "type":"object","additionalProperties":false,
            "required":["delivery","targets","attempts"],
            "properties":{"delivery":{"type":"object"},"targets":{"type":"array"},"attempts":{"type":"array"}}
        }),
        "worker_kernel::artifact_deliveries" => json!({
            "type":"object","additionalProperties":false,
            "required":["artifacts","returned","total","nextOffset","storageAttention"],
            "properties":{
                "artifacts":{"type":"array","items":artifact_metadata_response_schema()},
                "returned":{"type":"integer","minimum":0,"maximum":200},
                "total":{"type":"integer","minimum":0},
                "nextOffset":{
                    "oneOf":[
                        {"type":"integer","minimum":0,"maximum":1000000},
                        {"type":"null"}
                    ]
                },
                "storageAttention":{
                    "type":"object","additionalProperties":false,
                    "required":[
                        "state","artifactBytes","databaseBytes",
                        "databaseBudgetBytes","overBudget","message"
                    ],
                    "properties":{
                        "state":{"type":"string","enum":["normal","attention"]},
                        "artifactBytes":{"type":"integer","minimum":0},
                        "databaseBytes":{"type":"integer","minimum":0},
                        "databaseBudgetBytes":{"type":"integer","minimum":1},
                        "overBudget":{"type":"boolean"},
                        "message":{"oneOf":[{"type":"string"},{"type":"null"}]}
                    }
                }
            }
        }),
        "worker_kernel::artifact_content" => json!({
            "type":"object","additionalProperties":false,
            "required":["artifact","data"],
            "properties":{
                "artifact":artifact_metadata_response_schema(),
                "data":{"type":"string","maxLength":2796204}
            }
        }),
        "worker_kernel::artifact_delete" => json!({
            "type":"object","additionalProperties":false,
            "required":["workerId","artifactId","deleted"],
            "properties":{
                "workerId":{"type":"string"},"artifactId":{"type":"string"},
                "deleted":{"type":"boolean"}
            }
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
        "worker_kernel::result_read" => json!({
            "type":"object","additionalProperties":false,
            "required":[
                "kind","reference","pointer","value","children","offset",
                "returned","total","nextOffset","truncated"
            ],
            "properties":{
                "kind":{"const":"worker_result_chunk"},
                "reference":worker_result_reference_schema(),
                "pointer":{"type":"string"},
                "value":{},
                "children":{"type":"array","items":{
                    "type":"object","additionalProperties":false,
                    "required":["pointer","type","sizeBytes","preview"],
                    "properties":{
                        "pointer":{"type":"string"},"type":{"type":"string"},
                        "sizeBytes":{"type":"integer"},"preview":{"type":"string"}
                    }
                }},
                "offset":{"type":"integer"},"returned":{"type":"integer"},
                "total":{"type":"integer"},"nextOffset":{},"truncated":{"type":"boolean"}
            }
        }),
        "worker_kernel::await" => json!({
            "type":"object","additionalProperties":false,"required":["invocation","timedOut"],
            "properties":{"invocation":invocation_response_schema(),"timedOut":{"type":"boolean"}}
        }),
        "worker_kernel::agent_send" => json!({
            "type":"object","additionalProperties":false,
            "required":[
                "deliveryId","targetSessionId","createdSession","wakePolicy",
                "boundary","wakeSuppressedByCausalDepth"
            ],
            "properties":{
                "deliveryId":{"type":"string"},
                "targetSessionId":{"oneOf":[{"type":"string"},{"type":"null"}]},
                "createdSession":{"type":"boolean"},
                "wakePolicy":{"type":"string","enum":["passive","wake"]},
                "boundary":{"type":"string","enum":["next_turn","next_run"]},
                "wakeSuppressedByCausalDepth":{"type":"boolean"}
            }
        }),
        "worker_kernel::agent_wait_for_workers" => json!({
            "type":"object","additionalProperties":false,
            "required":["waitId","mode","invocationIds","status","deliveryIds"],
            "properties":{
                "waitId":{"type":"string"},
                "mode":{"type":"string","enum":["all","any"]},
                "invocationIds":{"type":"array","items":{"type":"string"}},
                "status":{"type":"string","enum":["pending","satisfied"]},
                "deliveryIds":{"type":"array","items":{"type":"string"}}
            }
        }),
        "worker_kernel::agent_mailbox_list" => json!({
            "type":"object","additionalProperties":false,
            "required":["items","returned"],
            "properties":{
                "items":{"type":"array","items":{
                    "type":"object","additionalProperties":false,
                    "required":[
                        "deliveryId","sourceKind","intent","createdAt",
                        "expiresAt","preview"
                    ],
                    "properties":{
                        "deliveryId":{"type":"string"},
                        "sourceKind":{"type":"string"},
                        "intent":{"oneOf":[{"type":"string"},{"type":"null"}]},
                        "createdAt":{"type":"string"},
                        "expiresAt":{"oneOf":[{"type":"string"},{"type":"null"}]},
                        "preview":{"type":"string","maxLength":512}
                    }
                }},
                "returned":{"type":"integer","minimum":0,"maximum":100}
            }
        }),
        "worker_kernel::agent_mailbox_claim" => json!({
            "type":"object","additionalProperties":false,
            "required":["claimed","deliveryIds","boundary","wakePolicy"],
            "properties":{
                "claimed":{"type":"integer","minimum":1,"maximum":8},
                "deliveryIds":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":8},
                "boundary":{"const":"next_turn"},
                "wakePolicy":{"const":"passive"}
            }
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

fn artifact_metadata_response_schema() -> Value {
    json!({
        "type":"object","additionalProperties":false,
        "required":[
            "workerId","artifactId","displayName","mediaType","sizeBytes",
            "contentSha256","contentReference","sourceInvocationId",
            "sourceWorkerVersion","traceId","createdAt"
        ],
        "properties":{
            "workerId":{"type":"string"},"artifactId":{"type":"string"},
            "displayName":{"type":"string"},"mediaType":{"type":"string"},
            "sizeBytes":{"type":"integer","minimum":1,"maximum":2097152},
            "contentSha256":{"type":"string","pattern":"^sha256:[0-9a-f]{64}$"},
            "contentReference":{
                "type":"object","additionalProperties":false,
                "required":["kind","workerId","artifactId","contentSha256","sizeBytes"],
                "properties":{
                    "kind":{"const":"artifact_content_reference"},
                    "workerId":{"type":"string"},"artifactId":{"type":"string"},
                    "contentSha256":{"type":"string","pattern":"^sha256:[0-9a-f]{64}$"},
                    "sizeBytes":{"type":"integer","minimum":1,"maximum":2097152}
                }
            },
            "sourceInvocationId":{"type":"string"},
            "sourceWorkerVersion":{"type":"string"},
            "traceId":{"type":"string"},
            "createdAt":{"type":"string"}
        }
    })
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
        "properties":{"invocationId":{"type":"string"},"workerId":{"type":"string"},"workerVersion":{"type":"string"},"status":{"type":"string"},"input":{},"output":{},"error":{},"idempotencyKey":{"type":"string"},"traceId":{"type":"string"},"causalDepth":{"type":"integer"},"triggerKind":{"type":"string"},"originSessionId":{"type":"string"},"agentSessionId":{"type":"string"},"interactionMode":{"type":"string","enum":["foreground","background"]},"detachedAt":{"type":"string"},"modelToolInvocationId":{"type":"string"},"parentWorkerInvocationId":{"type":"string"},"retryOfInvocationId":{"type":"string"},"requestedModel":{"type":"string"},"requestedReasoningLevel":{"type":"string"},"effectiveModel":{"type":"string"},"effectiveReasoningLevel":{"type":"string"},"attemptCount":{"type":"integer"},"createdAt":{"type":"string"},"startedAt":{},"completedAt":{}}
    })
}

pub(crate) fn worker_result_reference_schema() -> Value {
    json!({
        "type":"object","additionalProperties":false,
        "required":[
            "kind","invocationId","workerId","workerVersion",
            "outputSchemaSha256","contentSha256","sizeBytes","preview","message"
        ],
        "properties":{
            "kind":{"const":"worker_result_reference"},
            "invocationId":{"type":"string"},
            "workerId":{"type":"string"},
            "workerVersion":{"type":"string"},
            "outputSchemaSha256":{"type":"string","pattern":"^sha256:[0-9a-f]{64}$"},
            "contentSha256":{"type":"string","pattern":"^sha256:[0-9a-f]{64}$"},
            "sizeBytes":{"type":"integer","minimum":0},
            "preview":{"type":"string"},
            "message":{"type":"string"}
        }
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
    let requested_timing = json!({
        "type":"object","additionalProperties":false,
        "required":["queueMs","executionMs","wallMs"],
        "properties":{
            "queueMs":{"type":"integer"},"executionMs":{"type":"integer"},
            "wallMs":{"type":"integer"}
        }
    });
    let requested_usage = json!({
        "type":"object","additionalProperties":false,
        "required":["inputTokens","outputTokens","cacheReadTokens","cacheCreationTokens","cost","includesDescendants"],
        "properties":{
            "inputTokens":{"type":"integer"},"outputTokens":{"type":"integer"},
            "cacheReadTokens":{"type":"integer"},"cacheCreationTokens":{"type":"integer"},
            "cost":{"type":"number"},"includesDescendants":{"type":"boolean"}
        }
    });
    let mut requested_invocation = json!({
        "type":"object","additionalProperties":false,
        "required":[
            "invocationId","workerId","workerName","workerVersion","status",
            "requestedModel","requestedReasoningLevel","effectiveModel",
            "effectiveReasoningLevel","timing","usage"
        ],
        "properties":{
            "invocationId":{"type":"string"},"workerId":{"type":"string"},
            "workerName":{"type":"string"},"workerVersion":{"type":"string"},
            "status":{"type":"string"},"timing":requested_timing,"usage":requested_usage
        }
    });
    if let Some(properties) = requested_invocation
        .get_mut("properties")
        .and_then(Value::as_object_mut)
    {
        for field in [
            "requestedModel",
            "requestedReasoningLevel",
            "effectiveModel",
            "effectiveReasoningLevel",
        ] {
            properties.insert(
                field.to_owned(),
                json!({"oneOf":[{"type":"string"},{"type":"null"}]}),
            );
        }
    }
    let mut node = json!({
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
            "errorPreview":{},"presentation":{
                "oneOf":[presentation_response_schema(),{"type":"null"}]
            }
        }
    });
    if let Some(properties) = node.get_mut("properties").and_then(Value::as_object_mut) {
        for field in [
            "requestedModel",
            "requestedReasoningLevel",
            "effectiveModel",
            "effectiveReasoningLevel",
        ] {
            properties.insert(
                field.to_owned(),
                json!({"oneOf":[{"type":"string"},{"type":"null"}]}),
            );
        }
    }
    let timeline = json!({
        "type":"object","additionalProperties":false,
        "required":["occurredAt","nodeId","stage","status","summary","technical"],
        "properties":{
            "occurredAt":{"type":"string"},"nodeId":{"type":"string"},
            "stage":stage.clone(),"status":{"type":"string"},"summary":{"type":"string"},
            "technical":{"type":"boolean"},"invocationId":{"type":"string"}
        }
    });
    let mut schema = json!({
        "type":"object","additionalProperties":false,
        "required":[
            "rootInvocationId","requestedInvocationId","modelToolInvocationId",
            "originSessionId","workerId","workerName","requestPreview","status",
            "mode","stage","stageLabel","expectedNextTransition","createdAt",
            "startedAt","completedAt","elapsedMs","counts","timing","usage",
            "requestedInvocation",
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
            "requestedInvocation":requested_invocation,
            "nodes":{"type":"array","items":node},"timeline":{"type":"array","items":timeline},
            "resultPreview":{},"errorPreview":{},"truncated":{"type":"boolean"}
        }
    });
    if let Some(properties) = schema.get_mut("properties").and_then(Value::as_object_mut) {
        for field in [
            "requestedModel",
            "requestedReasoningLevel",
            "effectiveModel",
            "effectiveReasoningLevel",
        ] {
            properties.insert(
                field.to_owned(),
                json!({"oneOf":[{"type":"string"},{"type":"null"}]}),
            );
        }
    }
    schema
}

fn presentation_response_schema() -> Value {
    let mut schema = super::bundle::presentation_schema();
    if let Some(required) = schema.get_mut("required").and_then(Value::as_array_mut) {
        required.push(json!("primary"));
    }
    schema
}

fn webhook_credential_response_schema() -> Value {
    json!({
        "type":"object","additionalProperties":false,"required":["triggerId","path","token"],
        "properties":{"triggerId":{"type":"string"},"path":{"type":"string"},"token":{"type":"string"}}
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
