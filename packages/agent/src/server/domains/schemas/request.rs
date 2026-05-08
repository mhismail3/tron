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

pub(crate) fn request_schema_for_method(method: &str) -> Option<Value> {
    Some(match method {
        "discover" | "engine::discover" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "visibility": {"type": "string"},
                "namespacePrefix": {"type": "string"},
                "text": {"type": "string"},
                "effectClass": {"type": "string"},
                "maxRisk": {"type": "string"},
                "health": {"type": "string"},
                "includeInternal": {"type": "boolean"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "inspect" | "engine::inspect" => json!({
            "type": "object",
            "required": ["kind", "id"],
            "additionalProperties": false,
            "properties": {
                "kind": {"type": "string", "enum": ["function", "worker", "trigger_type", "trigger"]},
                "id": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "watch" | "engine::watch" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "afterRevision": {"type": "integer"},
                "limit": {"type": "integer"},
                "classes": {"type": "array", "items": {"type": "string"}},
                "kinds": {"type": "array", "items": {"type": "string"}},
                "subjectPrefix": {"type": "string"},
                "ownerWorker": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "invoke" | "engine::invoke" => json!({
            "type": "object",
            "required": ["functionId"],
            "additionalProperties": false,
            "properties": {
                "functionId": {"type": "string"},
                "payload": {},
                "expectedFunctionRevision": {"type": "integer"},
                "deliveryMode": {"type": "string", "enum": ["sync"]},
                "idempotencyKey": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "promote" | "engine::promote" => json!({
            "type": "object",
            "required": [
                "functionId",
                "targetVisibility",
                "expectedFunctionRevision",
                "idempotencyKey"
            ],
            "additionalProperties": false,
            "properties": {
                "functionId": {"type": "string"},
                "ownerWorker": {"type": "string"},
                "targetVisibility": {"type": "string", "enum": ["workspace", "system"]},
                "expectedFunctionRevision": {"type": "integer"},
                "workspaceId": {"type": "string"},
                "idempotencyKey": {"type": "string"}
            }
        }),
        "system::ping" => json!({
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
        "logs::recent" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "limit": {"type": "integer"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "logs::ingest" => json!({
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
        "system::get_diagnostics"
        | "system::get_update_status"
        | "system::check_for_updates"
        | "system::shutdown"
        | "codex_app::status"
        | "cron::status"
        | "transcription::download_model" => {
            json!({
                "type": "object",
                "additionalProperties": false,
                "properties": {
                    "sessionId": {"type": "string"},
                    "workspaceId": {"type": "string"}
                }
            })
        }
        "auth::get" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "auth::update" => json!({
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
        "auth::clear" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "provider": {"type": "string"},
                "service": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "auth::oauth_begin" => json!({
            "type": "object",
            "required": ["provider"],
            "additionalProperties": false,
            "properties": {
                "provider": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "auth::oauth_complete" => json!({
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
        "auth::rename_account" => json!({
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
        "auth::set_active" => json!({
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
        "auth::remove_account" | "auth::remove_api_key" => json!({
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
        "browser::start_stream" | "browser::stop_stream" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "display::stop_stream" => json!({
            "type": "object",
            "required": ["streamId"],
            "additionalProperties": false,
            "properties": {
                "streamId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "device::register" => json!({
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
        "device::unregister" => json!({
            "type": "object",
            "required": ["deviceToken"],
            "additionalProperties": false,
            "properties": {
                "deviceToken": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "device::respond" => json!({
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
        "transcription::audio" => json!({
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
        "voice_notes::save" => json!({
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
        "voice_notes::delete" => json!({
            "type": "object",
            "required": ["filename"],
            "additionalProperties": false,
            "properties": {
                "filename": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "sandbox::start_container"
        | "sandbox::stop_container"
        | "sandbox::kill_container"
        | "sandbox::remove_container" => json!({
            "type": "object",
            "required": ["name"],
            "additionalProperties": false,
            "properties": {
                "name": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "blob::get" => json!({
            "type": "object",
            "required": ["blobId"],
            "additionalProperties": false,
            "properties": {
                "blobId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "tool::result" => json!({
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
        "message::delete" => json!({
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
        "cron::list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "enabled": {"type": "boolean"},
                "tags": {"type": "array", "items": {"type": "string"}},
                "workspaceId": {"type": "string"},
                "sessionId": {"type": "string"}
            }
        }),
        "cron::get" | "cron::delete" | "cron::run" => json!({
            "type": "object",
            "required": ["jobId"],
            "additionalProperties": false,
            "properties": {
                "jobId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "cron::get_runs" => json!({
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
        "cron::create" => json!({
            "type": "object",
            "required": ["job"],
            "additionalProperties": false,
            "properties": {
                "job": {"type": "object", "additionalProperties": true},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "cron::update" => json!({
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
        "skills::list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "workingDirectory": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "skills::get" => json!({
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
        "skills::refresh" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "workingDirectory": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "skills::activate" | "skills::deactivate" => json!({
            "type": "object",
            "required": ["sessionId", "skillName"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "skillName": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "skills::active" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "events::get_history" => json!({
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
        "events::get_since" => json!({
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
        "events::append" => json!({
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
        "events::subscribe" | "events::unsubscribe" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "filesystem::list_dir" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "path": {"type": "string"},
                "showHidden": {"type": "boolean"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "filesystem::read_file" => json!({
            "type": "object",
            "required": ["path"],
            "additionalProperties": false,
            "properties": {
                "path": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "filesystem::get_home" | "prompt_library::snippet_list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "filesystem::create_dir" => json!({
            "type": "object",
            "required": ["path"],
            "additionalProperties": false,
            "properties": {
                "path": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "tree::get_visualization" | "tree::get_branches" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "tree::get_subtree" | "tree::get_ancestors" => json!({
            "type": "object",
            "required": ["eventId"],
            "additionalProperties": false,
            "properties": {
                "eventId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "tree::compare_branches" => json!({
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
        "repo::list_sessions" | "repo::get_divergence" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "import::list_sources"
        | "browser::get_status"
        | "transcription::list_models"
        | "sandbox::list_containers" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "import::list_sessions" => json!({
            "type": "object",
            "required": ["encodedDir"],
            "additionalProperties": false,
            "properties": {
                "encodedDir": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "import::preview_session" => json!({
            "type": "object",
            "required": ["sessionPath"],
            "additionalProperties": false,
            "properties": {
                "sessionPath": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "import::execute" => json!({
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
        "voice_notes::list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "limit": {"type": "integer"},
                "offset": {"type": "integer"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "session::list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "includeArchived": {"type": "boolean"},
                "limit": {"type": "integer"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "session::create" => json!({
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
                "__capabilityContext": {
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
        "session::resume" | "session::delete" | "session::archive" | "session::unarchive"
        | "session::export" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "session::fork" => json!({
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
        "session::archive_older_than" => json!({
            "type": "object",
            "required": ["days"],
            "additionalProperties": false,
            "properties": {
                "days": {"type": "integer"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "session::get_head" | "session::get_state" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "session::reconstruct" => json!({
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
        "session::get_history" => json!({
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
        "context::get_snapshot"
        | "context::get_detailed_snapshot"
        | "context::should_compact"
        | "context::preview_compaction"
        | "context::can_accept_turn" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "context::get_audit_trace" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "turn": {"type": "integer"},
                "workspaceId": {"type": "string"}
            }
        }),
        "context::confirm_compaction" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "editedSummary": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "context::clear" | "context::compact" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "agent::prompt" => json!({
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
        "agent::queue_prompt" => json!({
            "type": "object",
            "required": ["sessionId", "prompt"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "prompt": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "agent::dequeue_prompt" => json!({
            "type": "object",
            "required": ["sessionId", "queueId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "queueId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "agent::clear_queue" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "agent::status" | "agent::abort" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "agent::abort_tool" => json!({
            "type": "object",
            "required": ["sessionId", "toolCallId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "toolCallId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "agent::deliver_subagent_results" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "agent::submit_confirmation" => json!({
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
        "agent::submit_answers" => json!({
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
        "mcp::status" | "mcp::reload" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "mcp::list_tools" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "server": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "mcp::add_server" => json!({
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
        "mcp::remove_server"
        | "mcp::enable_server"
        | "mcp::disable_server"
        | "mcp::restart_server" => {
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
        "job::list" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "job::background" | "job::cancel" => json!({
            "type": "object",
            "required": ["jobId", "sessionId"],
            "additionalProperties": false,
            "properties": {
                "jobId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "job::subscribe" => json!({
            "type": "object",
            "required": ["jobId", "sessionId"],
            "additionalProperties": false,
            "properties": {
                "jobId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "job::unsubscribe" => json!({
            "type": "object",
            "required": ["jobId"],
            "additionalProperties": false,
            "properties": {
                "jobId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "notifications::list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "limit": {"type": "integer"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "notifications::mark_read" => json!({
            "type": "object",
            "required": ["eventId"],
            "additionalProperties": false,
            "properties": {
                "eventId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "notifications::mark_all_read" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "plan::enter" | "plan::exit" | "plan::get_state" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "settings::get" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {}
        }),
        "settings::update" => json!({
            "type": "object",
            "required": ["settings"],
            "additionalProperties": false,
            "properties": {
                "settings": {"type": "object", "additionalProperties": true},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "settings::reset_to_defaults" => json!({
            "type": "object",
            "additionalProperties": true
        }),
        "approval::get" => json!({
            "type": "object",
            "required": ["approvalId"],
            "additionalProperties": false,
            "properties": {
                "approvalId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "approval::list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "status": {"type": "string"},
                "sessionId": {"type": "string"},
                "limit": {"type": "integer"},
                "workspaceId": {"type": "string"}
            }
        }),
        "approval::resolve" => json!({
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
        "model::list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "__capabilityContext": {
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
        "model::switch" => json!({
            "type": "object",
            "required": ["sessionId", "model"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "model": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "config::set_reasoning_level" => json!({
            "type": "object",
            "required": ["sessionId", "level"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "level": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "memory::retain" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "prompt_library::history_list" => json!({
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
        "prompt_library::history_delete" => json!({
            "type": "object",
            "required": ["id"],
            "additionalProperties": false,
            "properties": {
                "id": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "prompt_library::history_clear" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "prompt_library::snippet_get" => json!({
            "type": "object",
            "required": ["id"],
            "additionalProperties": false,
            "properties": {
                "id": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "prompt_library::snippet_create" => json!({
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
        "prompt_library::snippet_update" => json!({
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
        "prompt_library::snippet_delete" => json!({
            "type": "object",
            "required": ["id"],
            "additionalProperties": false,
            "properties": {
                "id": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "system::get_info" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "__capabilityContext": {
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
        "git::clone" => json!({
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
        "git::sync_main" => json!({
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
        "git::push" => json!({
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
        "git::list_local_branches" => session_scoped_schema(),
        "git::list_remote_branches" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "remote": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree::get_status"
        | "worktree::list_session_branches"
        | "worktree::get_committed_diff"
        | "worktree::acquire"
        | "worktree::release"
        | "worktree::prune_branches"
        | "worktree::list_conflicts"
        | "worktree::continue_merge" => session_scoped_schema(),
        "worktree::is_git_repo" => json!({
            "type": "object",
            "required": ["path"],
            "additionalProperties": false,
            "properties": {
                "path": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree::list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree::get_diff" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "file": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree::commit" => json!({
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
        "worktree::merge" => json!({
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
        "worktree::finalize_session" => json!({
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
        "worktree::delete_branch" => json!({
            "type": "object",
            "required": ["sessionId", "branch"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "branch": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree::stage_files" | "worktree::unstage_files" | "worktree::discard_files" => json!({
            "type": "object",
            "required": ["sessionId", "paths"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "paths": {"type": "array", "items": {"type": "string"}},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree::rebase_on_main" => json!({
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
        "worktree::start_merge" => json!({
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
        "worktree::resolve_conflict" => json!({
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
        "worktree::abort_merge" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "reason": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree::resolve_conflicts_with_subagent" => json!({
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
