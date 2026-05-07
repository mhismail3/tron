use serde_json::{Value, json};

fn session_scoped_schema() -> Value {
    json!({
        "type": "object",
        "required": ["sessionId"],
        "additionalProperties": false,
        "properties": {
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"}
        }
    })
}

pub(super) fn request_schema_for_method(method: &str) -> Option<Value> {
    Some(match method {
        "system.ping" => json!({
            "type": "object",
            "required": ["protocolVersion"],
            "additionalProperties": false,
            "properties": {
                "protocolVersion": {"type": "integer"},
                "clientVersion": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "logs.recent" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "limit": {"type": "integer"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "logs.ingest" => json!({
            "type": "object",
            "required": ["entries"],
            "additionalProperties": false,
            "properties": {
                "entries": {
                    "type": "array",
                    "maxItems": 10_000,
                    "items": {
                        "type": "object",
                        "required": ["timestamp", "level", "category", "message"],
                        "additionalProperties": false,
                        "properties": {
                            "timestamp": {"type": "string"},
                            "level": {"type": "string"},
                            "category": {"type": "string"},
                            "message": {"type": "string"}
                        }
                    }
                },
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "system.getDiagnostics"
        | "system.getUpdateStatus"
        | "system.checkForUpdates"
        | "system.shutdown"
        | "codexApp.status"
        | "cron.status"
        | "transcribe.downloadModel" => {
            json!({
                "type": "object",
                "additionalProperties": false,
                "properties": {
                    "sessionId": {"type": "string"},
                    "workspaceId": {"type": "string"}
                }
            })
        }
        "auth.get" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "auth.update" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "provider": {"type": "string"},
                "service": {"type": "string"},
                "apiKey": {"type": ["string", "null"]},
                "apiKeyLabel": {"type": "string"},
                "oauth": {"type": ["object", "null"], "additionalProperties": true},
                "clientId": {"type": ["string", "null"]},
                "clientSecret": {"type": ["string", "null"]},
                "projectId": {"type": ["string", "null"]},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "auth.clear" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "provider": {"type": "string"},
                "service": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "auth.oauthBegin" => json!({
            "type": "object",
            "required": ["provider"],
            "additionalProperties": false,
            "properties": {
                "provider": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "auth.oauthComplete" => json!({
            "type": "object",
            "required": ["flowId", "code", "label"],
            "additionalProperties": false,
            "properties": {
                "flowId": {"type": "string"},
                "code": {"type": "string"},
                "label": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "auth.renameAccount" => json!({
            "type": "object",
            "required": ["provider", "oldLabel", "newLabel"],
            "additionalProperties": false,
            "properties": {
                "provider": {"type": "string"},
                "oldLabel": {"type": "string"},
                "newLabel": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "auth.setActive" => json!({
            "type": "object",
            "required": ["provider", "credential"],
            "additionalProperties": false,
            "properties": {
                "provider": {"type": "string"},
                "credential": {"type": "object", "additionalProperties": true},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "auth.removeAccount" | "auth.removeApiKey" => json!({
            "type": "object",
            "required": ["provider", "label"],
            "additionalProperties": false,
            "properties": {
                "provider": {"type": "string"},
                "label": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "browser.startStream" | "browser.stopStream" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "display.stopStream" => json!({
            "type": "object",
            "required": ["streamId"],
            "additionalProperties": false,
            "properties": {
                "streamId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "device.register" => json!({
            "type": "object",
            "required": ["deviceToken", "bundleId"],
            "additionalProperties": false,
            "properties": {
                "deviceToken": {"type": "string"},
                "bundleId": {"type": "string"},
                "environment": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "device.unregister" => json!({
            "type": "object",
            "required": ["deviceToken"],
            "additionalProperties": false,
            "properties": {
                "deviceToken": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "device.respond" => json!({
            "type": "object",
            "required": ["requestId"],
            "additionalProperties": false,
            "properties": {
                "requestId": {"type": "string"},
                "result": {},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "transcribe.audio" => json!({
            "type": "object",
            "required": ["audioBase64"],
            "additionalProperties": false,
            "properties": {
                "audioBase64": {"type": "string"},
                "mimeType": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "voiceNotes.save" => json!({
            "type": "object",
            "required": ["audioBase64"],
            "additionalProperties": false,
            "properties": {
                "audioBase64": {"type": "string"},
                "mimeType": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "voiceNotes.delete" => json!({
            "type": "object",
            "required": ["filename"],
            "additionalProperties": false,
            "properties": {
                "filename": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "sandbox.startContainer"
        | "sandbox.stopContainer"
        | "sandbox.killContainer"
        | "sandbox.removeContainer" => json!({
            "type": "object",
            "required": ["name"],
            "additionalProperties": false,
            "properties": {
                "name": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "blob.get" => json!({
            "type": "object",
            "required": ["blobId"],
            "additionalProperties": false,
            "properties": {
                "blobId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "tool.result" => json!({
            "type": "object",
            "required": ["sessionId", "toolUseId", "result"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "toolUseId": {"type": "string"},
                "result": {},
                "workspaceId": {"type": "string"}
            }
        }),
        "message.delete" => json!({
            "type": "object",
            "required": ["sessionId", "targetEventId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "targetEventId": {"type": "string"},
                "reason": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "cron.list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "enabled": {"type": "boolean"},
                "tags": {"type": "array", "items": {"type": "string"}},
                "workspaceId": {"type": "string"},
                "sessionId": {"type": "string"}
            }
        }),
        "cron.get" | "cron.delete" | "cron.run" => json!({
            "type": "object",
            "required": ["jobId"],
            "additionalProperties": false,
            "properties": {
                "jobId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "cron.getRuns" => json!({
            "type": "object",
            "required": ["jobId"],
            "additionalProperties": false,
            "properties": {
                "jobId": {"type": "string"},
                "status": {"type": "string"},
                "limit": {"type": "integer"},
                "offset": {"type": "integer"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "cron.create" => json!({
            "type": "object",
            "required": ["job"],
            "additionalProperties": false,
            "properties": {
                "job": {"type": "object", "additionalProperties": true},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "cron.update" => json!({
            "type": "object",
            "required": ["jobId"],
            "additionalProperties": false,
            "properties": {
                "jobId": {"type": "string"},
                "name": {"type": "string"},
                "description": {"type": ["string", "null"]},
                "enabled": {"type": "boolean"},
                "schedule": {"type": "object", "additionalProperties": true},
                "payload": {"type": "object", "additionalProperties": true},
                "delivery": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
                "overlapPolicy": {"type": "string"},
                "misfirePolicy": {"type": "string"},
                "maxRetries": {"type": "integer"},
                "autoDisableAfter": {"type": "integer"},
                "stuckTimeoutSecs": {"type": "integer"},
                "tags": {"type": "array", "items": {"type": "string"}},
                "toolRestrictions": {"type": ["object", "null"], "additionalProperties": true},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": ["string", "null"]}
            }
        }),
        "skill.list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "workingDirectory": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "skill.get" => json!({
            "type": "object",
            "required": ["name"],
            "additionalProperties": false,
            "properties": {
                "name": {"type": "string"},
                "workingDirectory": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "skill.refresh" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "workingDirectory": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "skill.activate" | "skill.deactivate" => json!({
            "type": "object",
            "required": ["sessionId", "skillName"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "skillName": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "skill.active" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "events.getHistory" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "limit": {"type": "integer"},
                "types": {"type": "array", "items": {"type": "string"}},
                "beforeEventId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "events.getSince" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "afterEventId": {"type": "string"},
                "afterSequence": {"type": "integer"},
                "limit": {"type": "integer"},
                "workspaceId": {"type": "string"}
            }
        }),
        "events.append" => json!({
            "type": "object",
            "required": ["sessionId", "type", "payload"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "type": {"type": "string"},
                "payload": {},
                "parentId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "events.subscribe" | "events.unsubscribe" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "filesystem.listDir" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "path": {"type": "string"},
                "showHidden": {"type": "boolean"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "file.read" => json!({
            "type": "object",
            "required": ["path"],
            "additionalProperties": false,
            "properties": {
                "path": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "filesystem.getHome" | "promptSnippet.list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "filesystem.createDir" => json!({
            "type": "object",
            "required": ["path"],
            "additionalProperties": false,
            "properties": {
                "path": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "tree.getVisualization" | "tree.getBranches" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "tree.getSubtree" | "tree.getAncestors" => json!({
            "type": "object",
            "required": ["eventId"],
            "additionalProperties": false,
            "properties": {
                "eventId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "tree.compareBranches" => json!({
            "type": "object",
            "required": ["branchA", "branchB"],
            "additionalProperties": false,
            "properties": {
                "branchA": {"type": "string"},
                "branchB": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "repo.listSessions" | "repo.getDivergence" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "import.listSources"
        | "browser.getStatus"
        | "transcribe.listModels"
        | "sandbox.listContainers" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "import.listSessions" => json!({
            "type": "object",
            "required": ["encodedDir"],
            "additionalProperties": false,
            "properties": {
                "encodedDir": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "import.previewSession" => json!({
            "type": "object",
            "required": ["sessionPath"],
            "additionalProperties": false,
            "properties": {
                "sessionPath": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "import.execute" => json!({
            "type": "object",
            "required": ["sessionPath"],
            "additionalProperties": false,
            "properties": {
                "sessionPath": {"type": "string"},
                "workingDirectory": {"type": "string"},
                "tags": {"type": "array", "items": {"type": "string"}},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "voiceNotes.list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "limit": {"type": "integer"},
                "offset": {"type": "integer"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "session.list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "includeArchived": {"type": "boolean"},
                "limit": {"type": "integer"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "session.create" => json!({
            "type": "object",
            "required": ["workingDirectory"],
            "additionalProperties": false,
            "properties": {
                "workingDirectory": {"type": "string"},
                "model": {"type": "string"},
                "title": {"type": "string"},
                "source": {"type": "string"},
                "profile": {"type": "string"},
                "useWorktree": {"type": "boolean"},
                "__rpcContext": {
                    "type": "object",
                    "additionalProperties": false,
                    "properties": {
                        "transportId": {"type": "string"}
                    }
                },
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "session.resume" | "session.delete" | "session.archive" | "session.unarchive"
        | "session.export" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "session.fork" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "fromEventId": {"type": "string"},
                "title": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "session.archiveOlderThan" => json!({
            "type": "object",
            "required": ["days"],
            "additionalProperties": false,
            "properties": {
                "days": {"type": "integer"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "session.getHead" | "session.getState" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "session.reconstruct" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "limit": {"type": "integer"},
                "beforeSequence": {"type": "integer"},
                "workspaceId": {"type": "string"}
            }
        }),
        "session.getHistory" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "limit": {"type": "integer"},
                "beforeId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "context.getSnapshot"
        | "context.getDetailedSnapshot"
        | "context.shouldCompact"
        | "context.previewCompaction"
        | "context.canAcceptTurn" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "context.getAuditTrace" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "turn": {"type": "integer"},
                "workspaceId": {"type": "string"}
            }
        }),
        "context.confirmCompaction" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "editedSummary": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "context.clear" | "context.compact" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "agent.prompt" => json!({
            "type": "object",
            "required": ["sessionId", "prompt"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "prompt": {"type": "string"},
                "reasoningLevel": {"type": "string"},
                "images": {
                    "type": "array",
                    "items": {"type": "object", "additionalProperties": true}
                },
                "attachments": {
                    "type": "array",
                    "items": {"type": "object", "additionalProperties": true}
                },
                "source": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "agent.queuePrompt" => json!({
            "type": "object",
            "required": ["sessionId", "prompt"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "prompt": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "agent.dequeuePrompt" => json!({
            "type": "object",
            "required": ["sessionId", "queueId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "queueId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "agent.clearQueue" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "agent.status" | "agent.abort" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "agent.abortTool" => json!({
            "type": "object",
            "required": ["sessionId", "toolCallId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "toolCallId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "agent.deliverSubagentResults" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "agent.submitConfirmation" => json!({
            "type": "object",
            "required": ["sessionId", "action", "decision"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "action": {"type": "string"},
                "decision": {"type": "string"},
                "note": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "agent.submitAnswers" => json!({
            "type": "object",
            "required": ["sessionId", "questions"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "questions": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["question"],
                        "additionalProperties": false,
                        "properties": {
                            "question": {"type": "string"},
                            "selectedValues": {"type": "array", "items": {"type": "string"}},
                            "otherValue": {"type": "string"}
                        }
                    }
                },
                "workspaceId": {"type": "string"}
            }
        }),
        "mcp.status" | "mcp.reload" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "mcp.listTools" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "server": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "mcp.addServer" => json!({
            "type": "object",
            "required": ["name"],
            "additionalProperties": false,
            "properties": {
                "name": {"type": "string"},
                "command": {"type": "string"},
                "args": {"type": "array", "items": {"type": "string"}},
                "env": {"type": "object", "additionalProperties": true},
                "url": {"type": "string"},
                "enabled": {"type": "boolean"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "mcp.removeServer" | "mcp.enableServer" | "mcp.disableServer" | "mcp.restartServer" => {
            json!({
                "type": "object",
                "required": ["name"],
                "additionalProperties": false,
                "properties": {
                    "name": {"type": "string"},
                    "sessionId": {"type": "string"},
                    "workspaceId": {"type": "string"}
                }
            })
        }
        "job.list" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "job.background" | "job.cancel" => json!({
            "type": "object",
            "required": ["jobId", "sessionId"],
            "additionalProperties": false,
            "properties": {
                "jobId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "job.subscribe" => json!({
            "type": "object",
            "required": ["jobId", "sessionId"],
            "additionalProperties": false,
            "properties": {
                "jobId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "job.unsubscribe" => json!({
            "type": "object",
            "required": ["jobId"],
            "additionalProperties": false,
            "properties": {
                "jobId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "notifications.list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "limit": {"type": "integer"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "notifications.markRead" => json!({
            "type": "object",
            "required": ["eventId"],
            "additionalProperties": false,
            "properties": {
                "eventId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "notifications.markAllRead" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "plan.enter" | "plan.exit" | "plan.getState" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "settings.get" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {}
        }),
        "settings.update" => json!({
            "type": "object",
            "required": ["settings"],
            "additionalProperties": false,
            "properties": {
                "settings": {"type": "object", "additionalProperties": true},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "settings.resetToDefaults" => json!({
            "type": "object",
            "additionalProperties": true
        }),
        "approval.get" => json!({
            "type": "object",
            "required": ["approvalId"],
            "additionalProperties": false,
            "properties": {
                "approvalId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "approval.list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "status": {"type": "string"},
                "sessionId": {"type": "string"},
                "limit": {"type": "integer"},
                "workspaceId": {"type": "string"}
            }
        }),
        "approval.resolve" => json!({
            "type": "object",
            "required": ["approvalId", "decision"],
            "additionalProperties": false,
            "properties": {
                "approvalId": {"type": "string"},
                "decision": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "model.list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "__rpcContext": {
                    "type": "object",
                    "additionalProperties": false,
                    "properties": {
                        "authPath": {"type": "string"}
                    }
                },
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "model.switch" => json!({
            "type": "object",
            "required": ["sessionId", "model"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "model": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "config.setReasoningLevel" => json!({
            "type": "object",
            "required": ["sessionId", "level"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "level": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "memory.retain" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "promptHistory.list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "limit": {"type": "integer"},
                "cursor": {"type": "string"},
                "query": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "promptHistory.delete" => json!({
            "type": "object",
            "required": ["id"],
            "additionalProperties": false,
            "properties": {
                "id": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "promptHistory.clear" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "promptSnippet.get" => json!({
            "type": "object",
            "required": ["id"],
            "additionalProperties": false,
            "properties": {
                "id": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "promptSnippet.create" => json!({
            "type": "object",
            "required": ["name", "text"],
            "additionalProperties": false,
            "properties": {
                "name": {"type": "string"},
                "text": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "promptSnippet.update" => json!({
            "type": "object",
            "required": ["id"],
            "additionalProperties": false,
            "properties": {
                "id": {"type": "string"},
                "name": {"type": "string"},
                "text": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "promptSnippet.delete" => json!({
            "type": "object",
            "required": ["id"],
            "additionalProperties": false,
            "properties": {
                "id": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "system.getInfo" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "__rpcContext": {
                    "type": "object",
                    "additionalProperties": false,
                    "properties": {
                        "onboardedMarkerPath": {"type": "string"}
                    }
                },
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "git.clone" => json!({
            "type": "object",
            "required": ["url", "targetPath"],
            "additionalProperties": false,
            "properties": {
                "url": {"type": "string"},
                "targetPath": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "git.syncMain" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "targetBranch": {"type": "string"},
                "remote": {"type": "string"},
                "fetchTimeoutMs": {"type": "integer"},
                "prune": {"type": "boolean"},
                "dryRun": {"type": "boolean"},
                "workspaceId": {"type": "string"}
            }
        }),
        "git.push" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "branch": {"type": "string"},
                "remote": {"type": "string"},
                "forceWithLease": {"type": "boolean"},
                "setUpstream": {"type": "boolean"},
                "dryRun": {"type": "boolean"},
                "overrideProtected": {"type": "boolean"},
                "protectedBranches": {"type": "array", "items": {"type": "string"}},
                "workspaceId": {"type": "string"}
            }
        }),
        "git.listLocalBranches" => session_scoped_schema(),
        "git.listRemoteBranches" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "remote": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree.getStatus"
        | "worktree.listSessionBranches"
        | "worktree.getCommittedDiff"
        | "worktree.acquire"
        | "worktree.release"
        | "worktree.pruneBranches"
        | "worktree.listConflicts"
        | "worktree.continueMerge" => session_scoped_schema(),
        "worktree.isGitRepo" => json!({
            "type": "object",
            "required": ["path"],
            "additionalProperties": false,
            "properties": {
                "path": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree.list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree.getDiff" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "file": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree.commit" => json!({
            "type": "object",
            "required": ["sessionId", "message", "stageAll"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "message": {"type": "string"},
                "stageAll": {"type": "boolean"},
                "amend": {"type": "boolean"},
                "signoff": {"type": "boolean"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree.merge" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "targetBranch": {"type": "string"},
                "strategy": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree.finalizeSession" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "sourceBranch": {"type": "string"},
                "targetBranch": {"type": "string"},
                "strategy": {"type": "string"},
                "newBranchName": {"type": "string"},
                "preserveOld": {"type": "boolean"},
                "rebranch": {"type": "boolean"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree.deleteBranch" => json!({
            "type": "object",
            "required": ["sessionId", "branch"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "branch": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree.stageFiles" | "worktree.unstageFiles" | "worktree.discardFiles" => json!({
            "type": "object",
            "required": ["sessionId", "paths"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "paths": {"type": "array", "items": {"type": "string"}},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree.rebaseOnMain" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "strategy": {"type": "string"},
                "mainBranch": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree.startMerge" => json!({
            "type": "object",
            "required": ["sessionId", "sourceBranch", "targetBranch"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "sourceBranch": {"type": "string"},
                "targetBranch": {"type": "string"},
                "strategy": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree.resolveConflict" => json!({
            "type": "object",
            "required": ["sessionId", "path", "resolution"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "path": {"type": "string"},
                "resolution": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree.abortMerge" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "reason": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree.resolveConflictsWithSubagent" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        _ => return None,
    })
}

pub(super) fn response_schema_for_method(method: &str) -> Option<Value> {
    Some(match method {
        "system.ping" => json!({
            "type": "object",
            "required": [
                "pong",
                "timestamp",
                "serverVersion",
                "serverProtocolVersion",
                "minClientProtocolVersion",
                "compatible"
            ],
            "additionalProperties": false,
            "properties": {
                "pong": {"type": "boolean"},
                "timestamp": {"type": "string"},
                "serverVersion": {"type": "string"},
                "serverProtocolVersion": {"type": "integer"},
                "minClientProtocolVersion": {"type": "integer"},
                "compatible": {"type": "boolean"}
            }
        }),
        "system.getInfo" => json!({
            "type": "object",
            "required": [
                "version",
                "uptime",
                "activeSessions",
                "platform",
                "arch",
                "runtime",
                "port",
                "tailscaleIp",
                "paired"
            ],
            "additionalProperties": false,
            "properties": {
                "version": {"type": "string"},
                "uptime": {"type": "integer"},
                "activeSessions": {"type": "integer"},
                "platform": {"type": "string"},
                "arch": {"type": "string"},
                "runtime": {"type": "string"},
                "port": {"type": "integer"},
                "tailscaleIp": {"type": ["string", "null"]},
                "paired": {"type": "boolean"}
            }
        }),
        "settings.get" => json!({
            "type": "object",
            "additionalProperties": true
        }),
        "settings.update" => json!({
            "type": "object",
            "required": ["success"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"}
            }
        }),
        "settings.resetToDefaults" => json!({
            "type": "object",
            "additionalProperties": true
        }),
        "approval.get" => json!({
            "type": "object",
            "required": ["approval"],
            "additionalProperties": false,
            "properties": {"approval": {}}
        }),
        "approval.list" => json!({
            "type": "object",
            "required": ["approvals"],
            "additionalProperties": false,
            "properties": {"approvals": {"type": "array"}}
        }),
        "approval.resolve" => json!({
            "type": "object",
            "required": ["approval", "child"],
            "additionalProperties": false,
            "properties": {
                "approval": {"type": "object"},
                "child": {}
            }
        }),
        "model.list" => json!({
            "type": "object",
            "required": ["models"],
            "additionalProperties": false,
            "properties": {
                "models": {
                    "type": "array",
                    "items": {"type": "object", "additionalProperties": true}
                }
            }
        }),
        "model.switch" => json!({
            "type": "object",
            "required": ["previousModel", "newModel"],
            "additionalProperties": false,
            "properties": {
                "previousModel": {"type": "string"},
                "newModel": {"type": "string"}
            }
        }),
        "config.setReasoningLevel" => json!({
            "type": "object",
            "required": ["previousLevel", "newLevel", "changed"],
            "additionalProperties": false,
            "properties": {
                "previousLevel": {"type": ["string", "null"]},
                "newLevel": {"type": "string"},
                "changed": {"type": "boolean"}
            }
        }),
        "memory.retain" => json!({
            "type": "object",
            "required": ["retained"],
            "additionalProperties": false,
            "properties": {
                "retained": {"type": "boolean"},
                "status": {"type": "string"},
                "reason": {"type": "string"}
            }
        }),
        "import.execute" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workingDirectory": {"type": "string"},
                "model": {"type": "string"},
                "eventCount": {"type": "integer"},
                "turnCount": {"type": "integer"},
                "messageCount": {"type": "integer"},
                "cost": {"type": "number"},
                "warnings": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
                "alreadyImported": {"type": "boolean"},
                "existingSessionId": {"type": "string"}
            }
        }),
        "skill.list" => json!({
            "type": "object",
            "required": ["skills"],
            "additionalProperties": false,
            "properties": {
                "skills": {
                    "type": "array",
                    "items": {"type": "object", "additionalProperties": true}
                }
            }
        }),
        "skill.get" => json!({
            "type": "object",
            "required": ["skill", "found"],
            "additionalProperties": false,
            "properties": {
                "skill": {"type": "object", "additionalProperties": true},
                "found": {"type": "boolean"}
            }
        }),
        "skill.refresh" => json!({
            "type": "object",
            "required": ["success", "skillCount"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "skillCount": {"type": "integer"}
            }
        }),
        "skill.activate" => json!({
            "type": "object",
            "required": ["success", "skill"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "alreadyActive": {"type": "boolean"},
                "skill": {"type": "object", "additionalProperties": true}
            }
        }),
        "skill.deactivate" => json!({
            "type": "object",
            "required": ["success", "wasActive", "deactivatedSkill"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "wasActive": {"type": "boolean"},
                "deactivatedSkill": {"type": "string"}
            }
        }),
        "skill.active" => json!({
            "type": "object",
            "required": ["skills"],
            "additionalProperties": false,
            "properties": {
                "skills": {"type": "array", "items": {"type": "object", "additionalProperties": true}}
            }
        }),
        "logs.recent" => json!({
            "type": "object",
            "required": ["entries", "count"],
            "additionalProperties": false,
            "properties": {
                "entries": {
                    "type": "array",
                    "items": {"type": "object", "additionalProperties": true}
                },
                "count": {"type": "integer"}
            }
        }),
        "logs.ingest" => json!({
            "type": "object",
            "required": ["success", "inserted"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "inserted": {"type": "integer"}
            }
        }),
        "system.getDiagnostics"
        | "system.getUpdateStatus"
        | "system.checkForUpdates"
        | "codexApp.status"
        | "cron.list"
        | "cron.get"
        | "cron.create"
        | "cron.update"
        | "cron.status"
        | "cron.getRuns" => json!({
            "type": "object",
            "additionalProperties": true
        }),
        "system.shutdown" => json!({
            "type": "object",
            "required": ["acknowledged"],
            "additionalProperties": false,
            "properties": {
                "acknowledged": {"type": "boolean"}
            }
        }),
        "auth.get" | "auth.update" | "auth.clear" | "auth.oauthComplete" | "auth.renameAccount"
        | "auth.setActive" | "auth.removeAccount" | "auth.removeApiKey" => json!({
            "type": "object",
            "required": ["providers", "services"],
            "additionalProperties": false,
            "properties": {
                "providers": {"type": "object", "additionalProperties": true},
                "services": {"type": "object", "additionalProperties": true}
            }
        }),
        "auth.oauthBegin" => json!({
            "type": "object",
            "required": ["flowId", "authUrl"],
            "additionalProperties": false,
            "properties": {
                "flowId": {"type": "string"},
                "authUrl": {"type": "string"}
            }
        }),
        "blob.get" => json!({
            "type": "object",
            "required": ["blobId", "mimeType", "data", "sizeBytes"],
            "additionalProperties": false,
            "properties": {
                "blobId": {"type": "string"},
                "mimeType": {"type": "string"},
                "data": {"type": "string"},
                "sizeBytes": {"type": "integer"}
            }
        }),
        "tool.result" => json!({
            "type": "object",
            "required": ["success", "toolCallId"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "toolCallId": {"type": "string"}
            }
        }),
        "message.delete" => json!({
            "type": "object",
            "required": ["success", "deletionEventId", "targetType"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "deletionEventId": {"type": "string"},
                "targetType": {"type": "string"}
            }
        }),
        "cron.delete" => json!({
            "type": "object",
            "required": ["deleted"],
            "additionalProperties": false,
            "properties": {"deleted": {"type": "boolean"}}
        }),
        "cron.run" => json!({
            "type": "object",
            "required": ["triggered", "jobId"],
            "additionalProperties": false,
            "properties": {
                "triggered": {"type": "boolean"},
                "jobId": {"type": "string"}
            }
        }),
        "events.getHistory" => json!({
            "type": "object",
            "required": ["sessionId", "events", "hasMore", "oldestEventId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "events": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
                "hasMore": {"type": "boolean"},
                "oldestEventId": {"type": ["string", "null"]}
            }
        }),
        "events.getSince" => json!({
            "type": "object",
            "required": ["events", "hasMore", "nextCursor"],
            "additionalProperties": false,
            "properties": {
                "events": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
                "hasMore": {"type": "boolean"},
                "nextCursor": {"type": ["string", "null"]}
            }
        }),
        "events.append" => json!({
            "type": "object",
            "required": ["event", "newHeadEventId"],
            "additionalProperties": false,
            "properties": {
                "event": {"type": "object", "additionalProperties": true},
                "newHeadEventId": {"type": ["string", "null"]}
            }
        }),
        "events.subscribe" => json!({
            "type": "object",
            "required": ["subscribed"],
            "additionalProperties": false,
            "properties": {"subscribed": {"type": "boolean"}}
        }),
        "events.unsubscribe" => json!({
            "type": "object",
            "required": ["unsubscribed"],
            "additionalProperties": false,
            "properties": {"unsubscribed": {"type": "boolean"}}
        }),
        "filesystem.listDir" => json!({
            "type": "object",
            "required": ["path", "parent", "entries"],
            "additionalProperties": false,
            "properties": {
                "path": {"type": "string"},
                "parent": {"type": ["string", "null"]},
                "entries": {"type": "array", "items": {"type": "object", "additionalProperties": true}}
            }
        }),
        "filesystem.getHome" => json!({
            "type": "object",
            "required": ["homePath", "suggestedPaths"],
            "additionalProperties": false,
            "properties": {
                "homePath": {"type": "string"},
                "suggestedPaths": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["name", "path", "exists"],
                        "additionalProperties": false,
                        "properties": {
                            "name": {"type": "string"},
                            "path": {"type": "string"},
                            "exists": {"type": "boolean"}
                        }
                    }
                }
            }
        }),
        "file.read" => json!({
            "type": "object",
            "required": ["content", "path"],
            "additionalProperties": false,
            "properties": {
                "content": {"type": "string"},
                "path": {"type": "string"}
            }
        }),
        "filesystem.createDir" => json!({
            "type": "object",
            "required": ["created", "path"],
            "additionalProperties": false,
            "properties": {
                "created": {"type": "boolean"},
                "path": {"type": "string"}
            }
        }),
        "session.list"
        | "session.create"
        | "session.resume"
        | "session.delete"
        | "session.fork"
        | "session.getHead"
        | "session.getState"
        | "session.getHistory"
        | "session.reconstruct"
        | "session.archive"
        | "session.unarchive"
        | "session.archiveOlderThan"
        | "session.export"
        | "context.getSnapshot"
        | "context.getDetailedSnapshot"
        | "context.getAuditTrace"
        | "context.shouldCompact"
        | "context.previewCompaction"
        | "context.canAcceptTurn"
        | "context.confirmCompaction"
        | "context.clear"
        | "context.compact"
        | "tree.getVisualization"
        | "tree.getBranches"
        | "tree.getSubtree"
        | "tree.getAncestors"
        | "tree.compareBranches"
        | "repo.listSessions"
        | "repo.getDivergence"
        | "import.listSources"
        | "import.listSessions"
        | "import.previewSession"
        | "voiceNotes.list"
        | "transcribe.listModels"
        | "sandbox.listContainers" => json!({
            "type": "object",
            "additionalProperties": true
        }),
        "browser.getStatus" => json!({
            "type": "object",
            "required": ["hasBrowser", "isStreaming"],
            "additionalProperties": false,
            "properties": {
                "hasBrowser": {"type": "boolean"},
                "isStreaming": {"type": "boolean"}
            }
        }),
        "browser.startStream" => json!({
            "type": "object",
            "additionalProperties": true
        }),
        "browser.stopStream" => json!({
            "type": "object",
            "required": ["success"],
            "additionalProperties": false,
            "properties": {"success": {"type": "boolean"}}
        }),
        "display.stopStream" => json!({
            "type": "object",
            "required": ["streamId", "stopped"],
            "additionalProperties": false,
            "properties": {
                "streamId": {"type": "string"},
                "stopped": {"type": "boolean"}
            }
        }),
        "device.register" => json!({
            "type": "object",
            "required": ["id", "created"],
            "additionalProperties": false,
            "properties": {
                "id": {"type": "string"},
                "created": {"type": "boolean"}
            }
        }),
        "device.unregister" => json!({
            "type": "object",
            "required": ["success"],
            "additionalProperties": false,
            "properties": {"success": {"type": "boolean"}}
        }),
        "device.respond" => json!({
            "type": "object",
            "required": ["resolved"],
            "additionalProperties": false,
            "properties": {"resolved": {"type": "boolean"}}
        }),
        "transcribe.audio" => json!({
            "type": "object",
            "required": [
                "text",
                "rawText",
                "language",
                "durationSeconds",
                "processingTimeMs",
                "model",
                "device",
                "computeType",
                "cleanupMode"
            ],
            "additionalProperties": false,
            "properties": {
                "text": {"type": "string"},
                "rawText": {"type": "string"},
                "language": {"type": "string"},
                "durationSeconds": {"type": "number"},
                "processingTimeMs": {"type": "integer"},
                "model": {"type": "string"},
                "device": {"type": "string"},
                "computeType": {"type": "string"},
                "cleanupMode": {"type": "string"}
            }
        }),
        "transcribe.downloadModel" => json!({
            "type": "object",
            "required": ["started", "reason"],
            "additionalProperties": false,
            "properties": {
                "started": {"type": "boolean"},
                "reason": {"type": "string"},
                "message": {"type": "string"}
            }
        }),
        "voiceNotes.save" => json!({
            "type": "object",
            "required": ["success", "filename", "filepath", "transcription"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "filename": {"type": "string"},
                "filepath": {"type": "string"},
                "transcription": {"type": "object", "additionalProperties": true}
            }
        }),
        "voiceNotes.delete" => json!({
            "type": "object",
            "required": ["success", "filename"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "filename": {"type": "string"}
            }
        }),
        "sandbox.startContainer"
        | "sandbox.stopContainer"
        | "sandbox.killContainer"
        | "sandbox.removeContainer" => json!({
            "type": "object",
            "required": ["success"],
            "additionalProperties": false,
            "properties": {"success": {"type": "boolean"}}
        }),
        "agent.prompt" => json!({
            "type": "object",
            "required": ["acknowledged", "runId"],
            "additionalProperties": false,
            "properties": {
                "acknowledged": {"type": "boolean"},
                "runId": {"type": "string"}
            }
        }),
        "agent.status"
        | "agent.abort"
        | "agent.abortTool"
        | "agent.queuePrompt"
        | "agent.dequeuePrompt"
        | "agent.clearQueue"
        | "agent.deliverSubagentResults"
        | "agent.submitConfirmation"
        | "agent.submitAnswers" => json!({
            "type": "object",
            "additionalProperties": true
        }),
        "mcp.status" => json!({
            "type": "array",
            "items": {"type": "object", "additionalProperties": true}
        }),
        "mcp.listTools" => json!({
            "type": "array",
            "items": {"type": "object", "additionalProperties": true}
        }),
        "mcp.addServer" | "mcp.restartServer" => json!({
            "type": "object",
            "required": ["success", "toolCount"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "toolCount": {"type": "integer"}
            }
        }),
        "mcp.removeServer" | "mcp.enableServer" | "mcp.disableServer" => json!({
            "type": "object",
            "required": ["success"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"}
            }
        }),
        "mcp.reload" => json!({
            "type": "object",
            "required": ["success", "serverCount"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "serverCount": {"type": "integer"}
            }
        }),
        "job.background" => json!({
            "type": "object",
            "required": ["jobId", "backgrounded"],
            "additionalProperties": false,
            "properties": {
                "jobId": {"type": "string"},
                "backgrounded": {"type": "boolean"}
            }
        }),
        "job.cancel" => json!({
            "type": "object",
            "required": ["jobId", "cancelled"],
            "additionalProperties": false,
            "properties": {
                "jobId": {"type": "string"},
                "cancelled": {"type": "boolean"}
            }
        }),
        "job.list" => json!({
            "type": "object",
            "required": ["jobs"],
            "additionalProperties": false,
            "properties": {"jobs": {"type": "array"}}
        }),
        "job.subscribe" => json!({
            "type": "object",
            "required": ["subscribed", "jobId"],
            "additionalProperties": false,
            "properties": {
                "subscribed": {"type": "boolean"},
                "jobId": {"type": "string"}
            }
        }),
        "job.unsubscribe" => json!({
            "type": "object",
            "required": ["jobId", "unsubscribed"],
            "additionalProperties": false,
            "properties": {
                "jobId": {"type": "string"},
                "unsubscribed": {"type": "boolean"}
            }
        }),
        "notifications.list" => json!({
            "type": "object",
            "required": ["notifications", "unreadCount"],
            "additionalProperties": false,
            "properties": {
                "notifications": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
                "unreadCount": {"type": "integer"}
            }
        }),
        "notifications.markRead" => json!({
            "type": "object",
            "required": ["success"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"}
            }
        }),
        "notifications.markAllRead" => json!({
            "type": "object",
            "required": ["marked"],
            "additionalProperties": false,
            "properties": {
                "marked": {"type": "integer"}
            }
        }),
        "plan.enter" | "plan.exit" | "plan.getState" => json!({
            "type": "object",
            "required": ["planMode"],
            "additionalProperties": false,
            "properties": {
                "planMode": {"type": "boolean"}
            }
        }),
        "promptHistory.list" => json!({
            "type": "object",
            "required": ["items", "nextCursor"],
            "additionalProperties": false,
            "properties": {
                "items": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
                "nextCursor": {"type": ["string", "null"]}
            }
        }),
        "promptHistory.delete" => json!({
            "type": "object",
            "required": ["deleted"],
            "additionalProperties": false,
            "properties": {
                "deleted": {"type": "boolean"}
            }
        }),
        "promptHistory.clear" => json!({
            "type": "object",
            "required": ["deletedCount"],
            "additionalProperties": false,
            "properties": {
                "deletedCount": {"type": "integer"}
            }
        }),
        "promptSnippet.list" => json!({
            "type": "object",
            "required": ["items"],
            "additionalProperties": false,
            "properties": {
                "items": {"type": "array", "items": {"type": "object", "additionalProperties": true}}
            }
        }),
        "promptSnippet.get" => json!({
            "type": "object",
            "required": ["snippet"],
            "additionalProperties": false,
            "properties": {
                "snippet": {"type": "object", "additionalProperties": true}
            }
        }),
        "promptSnippet.create" | "promptSnippet.update" => json!({
            "type": "object",
            "required": ["snippet"],
            "additionalProperties": false,
            "properties": {
                "snippet": {"type": "object", "additionalProperties": true}
            }
        }),
        "promptSnippet.delete" => json!({
            "type": "object",
            "required": ["deleted"],
            "additionalProperties": false,
            "properties": {
                "deleted": {"type": "boolean"}
            }
        }),
        method if method.starts_with("git.") || method.starts_with("worktree.") => {
            json!({
                "type": "object",
                "additionalProperties": true
            })
        }
        _ => return None,
    })
}
