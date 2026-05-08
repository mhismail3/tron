use serde_json::{Value, json};

pub(crate) fn response_schema_for_method(method: &str) -> Option<Value> {
    Some(match method {
        "discover" | "engine::discover" => json!({
            "type": "object",
            "required": ["catalogRevision", "functions"],
            "additionalProperties": false,
            "properties": {
                "catalogRevision": {"type": "integer"},
                "functions": {"type": "array", "items": {"type": "object", "additionalProperties": true}}
            }
        }),
        "inspect" | "engine::inspect" => json!({
            "type": "object",
            "required": ["catalogRevision", "kind", "definition"],
            "additionalProperties": false,
            "properties": {
                "catalogRevision": {"type": "integer"},
                "kind": {"type": "string"},
                "definition": {"type": "object", "additionalProperties": true}
            }
        }),
        "watch" | "engine::watch" => json!({
            "type": "object",
            "required": ["changes", "currentRevision", "hasMore"],
            "additionalProperties": false,
            "properties": {
                "changes": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
                "currentRevision": {"type": "integer"},
                "hasMore": {"type": "boolean"}
            }
        }),
        "invoke" | "engine::invoke" => json!({
            "type": "object",
            "required": ["catalogRevision", "child"],
            "additionalProperties": false,
            "properties": {
                "catalogRevision": {"type": "integer"},
                "child": {"type": "object", "additionalProperties": true}
            }
        }),
        "promote" | "engine::promote" => json!({
            "type": "object",
            "required": ["functionId", "revision", "visibility"],
            "additionalProperties": false,
            "properties": {
                "functionId": {"type": "string"},
                "revision": {"type": "integer"},
                "visibility": {"type": "string"}
            }
        }),
        "system::ping" => json!({
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
        "system::get_info" => json!({
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
        "settings::get" => json!({
            "type": "object",
            "additionalProperties": true
        }),
        "settings::update" => json!({
            "type": "object",
            "required": ["success"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"}
            }
        }),
        "settings::reset_to_defaults" => json!({
            "type": "object",
            "additionalProperties": true
        }),
        "approval::get" => json!({
            "type": "object",
            "required": ["approval"],
            "additionalProperties": false,
            "properties": {"approval": {}}
        }),
        "approval::list" => json!({
            "type": "object",
            "required": ["approvals"],
            "additionalProperties": false,
            "properties": {"approvals": {"type": "array"}}
        }),
        "approval::resolve" => json!({
            "type": "object",
            "required": ["approval", "child"],
            "additionalProperties": false,
            "properties": {
                "approval": {"type": "object"},
                "child": {}
            }
        }),
        "model::list" => json!({
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
        "model::switch" => json!({
            "type": "object",
            "required": ["previousModel", "newModel"],
            "additionalProperties": false,
            "properties": {
                "previousModel": {"type": "string"},
                "newModel": {"type": "string"}
            }
        }),
        "config::set_reasoning_level" => json!({
            "type": "object",
            "required": ["previousLevel", "newLevel", "changed"],
            "additionalProperties": false,
            "properties": {
                "previousLevel": {"type": ["string", "null"]},
                "newLevel": {"type": "string"},
                "changed": {"type": "boolean"}
            }
        }),
        "memory::retain" => json!({
            "type": "object",
            "required": ["retained"],
            "additionalProperties": false,
            "properties": {
                "retained": {"type": "boolean"},
                "status": {"type": "string"},
                "reason": {"type": "string"}
            }
        }),
        "import::execute" => json!({
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
        "skills::list" => json!({
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
        "skills::get" => json!({
            "type": "object",
            "required": ["skill", "found"],
            "additionalProperties": false,
            "properties": {
                "skill": {"type": "object", "additionalProperties": true},
                "found": {"type": "boolean"}
            }
        }),
        "skills::refresh" => json!({
            "type": "object",
            "required": ["success", "skillCount"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "skillCount": {"type": "integer"}
            }
        }),
        "skills::activate" => json!({
            "type": "object",
            "required": ["success", "skill"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "alreadyActive": {"type": "boolean"},
                "skill": {"type": "object", "additionalProperties": true}
            }
        }),
        "skills::deactivate" => json!({
            "type": "object",
            "required": ["success", "wasActive", "deactivatedSkill"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "wasActive": {"type": "boolean"},
                "deactivatedSkill": {"type": "string"}
            }
        }),
        "skills::active" => json!({
            "type": "object",
            "required": ["skills"],
            "additionalProperties": false,
            "properties": {
                "skills": {"type": "array", "items": {"type": "object", "additionalProperties": true}}
            }
        }),
        "logs::recent" => json!({
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
        "logs::ingest" => json!({
            "type": "object",
            "required": ["success", "inserted"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "inserted": {"type": "integer"}
            }
        }),
        "system::get_diagnostics"
        | "system::get_update_status"
        | "system::check_for_updates"
        | "codex_app::status"
        | "cron::list"
        | "cron::get"
        | "cron::create"
        | "cron::update"
        | "cron::status"
        | "cron::get_runs" => json!({
            "type": "object",
            "additionalProperties": true
        }),
        "system::shutdown" => json!({
            "type": "object",
            "required": ["acknowledged"],
            "additionalProperties": false,
            "properties": {
                "acknowledged": {"type": "boolean"}
            }
        }),
        "auth::get"
        | "auth::update"
        | "auth::clear"
        | "auth::oauth_complete"
        | "auth::rename_account"
        | "auth::set_active"
        | "auth::remove_account"
        | "auth::remove_api_key" => json!({
            "type": "object",
            "required": ["providers", "services"],
            "additionalProperties": false,
            "properties": {
                "providers": {"type": "object", "additionalProperties": true},
                "services": {"type": "object", "additionalProperties": true}
            }
        }),
        "auth::oauth_begin" => json!({
            "type": "object",
            "required": ["flowId", "authUrl"],
            "additionalProperties": false,
            "properties": {
                "flowId": {"type": "string"},
                "authUrl": {"type": "string"}
            }
        }),
        "blob::get" => json!({
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
        "tool::result" => json!({
            "type": "object",
            "required": ["success", "toolCallId"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "toolCallId": {"type": "string"}
            }
        }),
        "message::delete" => json!({
            "type": "object",
            "required": ["success", "deletionEventId", "targetType"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "deletionEventId": {"type": "string"},
                "targetType": {"type": "string"}
            }
        }),
        "cron::delete" => json!({
            "type": "object",
            "required": ["deleted"],
            "additionalProperties": false,
            "properties": {"deleted": {"type": "boolean"}}
        }),
        "cron::run" => json!({
            "type": "object",
            "required": ["triggered", "jobId"],
            "additionalProperties": false,
            "properties": {
                "triggered": {"type": "boolean"},
                "jobId": {"type": "string"}
            }
        }),
        "events::get_history" => json!({
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
        "events::get_since" => json!({
            "type": "object",
            "required": ["events", "hasMore", "nextCursor"],
            "additionalProperties": false,
            "properties": {
                "events": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
                "hasMore": {"type": "boolean"},
                "nextCursor": {"type": ["string", "null"]}
            }
        }),
        "events::append" => json!({
            "type": "object",
            "required": ["event", "newHeadEventId"],
            "additionalProperties": false,
            "properties": {
                "event": {"type": "object", "additionalProperties": true},
                "newHeadEventId": {"type": ["string", "null"]}
            }
        }),
        "events::subscribe" => json!({
            "type": "object",
            "required": ["subscribed"],
            "additionalProperties": false,
            "properties": {"subscribed": {"type": "boolean"}}
        }),
        "events::unsubscribe" => json!({
            "type": "object",
            "required": ["unsubscribed"],
            "additionalProperties": false,
            "properties": {"unsubscribed": {"type": "boolean"}}
        }),
        "filesystem::list_dir" => json!({
            "type": "object",
            "required": ["path", "parent", "entries"],
            "additionalProperties": false,
            "properties": {
                "path": {"type": "string"},
                "parent": {"type": ["string", "null"]},
                "entries": {"type": "array", "items": {"type": "object", "additionalProperties": true}}
            }
        }),
        "filesystem::get_home" => json!({
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
        "filesystem::read_file" => json!({
            "type": "object",
            "required": ["content", "path"],
            "additionalProperties": false,
            "properties": {
                "content": {"type": "string"},
                "path": {"type": "string"}
            }
        }),
        "filesystem::create_dir" => json!({
            "type": "object",
            "required": ["created", "path"],
            "additionalProperties": false,
            "properties": {
                "created": {"type": "boolean"},
                "path": {"type": "string"}
            }
        }),
        "session::list"
        | "session::create"
        | "session::resume"
        | "session::delete"
        | "session::fork"
        | "session::get_head"
        | "session::get_state"
        | "session::get_history"
        | "session::reconstruct"
        | "session::archive"
        | "session::unarchive"
        | "session::archive_older_than"
        | "session::export"
        | "context::get_snapshot"
        | "context::get_detailed_snapshot"
        | "context::get_audit_trace"
        | "context::should_compact"
        | "context::preview_compaction"
        | "context::can_accept_turn"
        | "context::confirm_compaction"
        | "context::clear"
        | "context::compact"
        | "tree::get_visualization"
        | "tree::get_branches"
        | "tree::get_subtree"
        | "tree::get_ancestors"
        | "tree::compare_branches"
        | "repo::list_sessions"
        | "repo::get_divergence"
        | "import::list_sources"
        | "import::list_sessions"
        | "import::preview_session"
        | "voice_notes::list"
        | "transcription::list_models"
        | "sandbox::list_containers" => json!({
            "type": "object",
            "additionalProperties": true
        }),
        "browser::get_status" => json!({
            "type": "object",
            "required": ["hasBrowser", "isStreaming"],
            "additionalProperties": false,
            "properties": {
                "hasBrowser": {"type": "boolean"},
                "isStreaming": {"type": "boolean"}
            }
        }),
        "browser::start_stream" => json!({
            "type": "object",
            "additionalProperties": true
        }),
        "browser::stop_stream" => json!({
            "type": "object",
            "required": ["success"],
            "additionalProperties": false,
            "properties": {"success": {"type": "boolean"}}
        }),
        "display::stop_stream" => json!({
            "type": "object",
            "required": ["streamId", "stopped"],
            "additionalProperties": false,
            "properties": {
                "streamId": {"type": "string"},
                "stopped": {"type": "boolean"}
            }
        }),
        "device::register" => json!({
            "type": "object",
            "required": ["id", "created"],
            "additionalProperties": false,
            "properties": {
                "id": {"type": "string"},
                "created": {"type": "boolean"}
            }
        }),
        "device::unregister" => json!({
            "type": "object",
            "required": ["success"],
            "additionalProperties": false,
            "properties": {"success": {"type": "boolean"}}
        }),
        "device::respond" => json!({
            "type": "object",
            "required": ["resolved"],
            "additionalProperties": false,
            "properties": {"resolved": {"type": "boolean"}}
        }),
        "transcription::audio" => json!({
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
        "transcription::download_model" => json!({
            "type": "object",
            "required": ["started", "reason"],
            "additionalProperties": false,
            "properties": {
                "started": {"type": "boolean"},
                "reason": {"type": "string"},
                "message": {"type": "string"}
            }
        }),
        "voice_notes::save" => json!({
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
        "voice_notes::delete" => json!({
            "type": "object",
            "required": ["success", "filename"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "filename": {"type": "string"}
            }
        }),
        "sandbox::start_container"
        | "sandbox::stop_container"
        | "sandbox::kill_container"
        | "sandbox::remove_container" => json!({
            "type": "object",
            "required": ["success"],
            "additionalProperties": false,
            "properties": {"success": {"type": "boolean"}}
        }),
        "agent::prompt" => json!({
            "type": "object",
            "required": ["acknowledged", "runId"],
            "additionalProperties": false,
            "properties": {
                "acknowledged": {"type": "boolean"},
                "runId": {"type": "string"}
            }
        }),
        "agent::status"
        | "agent::abort"
        | "agent::abort_tool"
        | "agent::queue_prompt"
        | "agent::dequeue_prompt"
        | "agent::clear_queue"
        | "agent::deliver_subagent_results"
        | "agent::submit_confirmation"
        | "agent::submit_answers" => json!({
            "type": "object",
            "additionalProperties": true
        }),
        "mcp::status" => json!({
            "type": "array",
            "items": {"type": "object", "additionalProperties": true}
        }),
        "mcp::list_tools" => json!({
            "type": "array",
            "items": {"type": "object", "additionalProperties": true}
        }),
        "mcp::add_server" | "mcp::restart_server" => json!({
            "type": "object",
            "required": ["success", "toolCount"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "toolCount": {"type": "integer"}
            }
        }),
        "mcp::remove_server" | "mcp::enable_server" | "mcp::disable_server" => json!({
            "type": "object",
            "required": ["success"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"}
            }
        }),
        "mcp::reload" => json!({
            "type": "object",
            "required": ["success", "serverCount"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "serverCount": {"type": "integer"}
            }
        }),
        "job::background" => json!({
            "type": "object",
            "required": ["jobId", "backgrounded"],
            "additionalProperties": false,
            "properties": {
                "jobId": {"type": "string"},
                "backgrounded": {"type": "boolean"}
            }
        }),
        "job::cancel" => json!({
            "type": "object",
            "required": ["jobId", "cancelled"],
            "additionalProperties": false,
            "properties": {
                "jobId": {"type": "string"},
                "cancelled": {"type": "boolean"}
            }
        }),
        "job::list" => json!({
            "type": "object",
            "required": ["jobs"],
            "additionalProperties": false,
            "properties": {"jobs": {"type": "array"}}
        }),
        "job::subscribe" => json!({
            "type": "object",
            "required": ["subscribed", "jobId"],
            "additionalProperties": false,
            "properties": {
                "subscribed": {"type": "boolean"},
                "jobId": {"type": "string"}
            }
        }),
        "job::unsubscribe" => json!({
            "type": "object",
            "required": ["jobId", "unsubscribed"],
            "additionalProperties": false,
            "properties": {
                "jobId": {"type": "string"},
                "unsubscribed": {"type": "boolean"}
            }
        }),
        "notifications::list" => json!({
            "type": "object",
            "required": ["notifications", "unreadCount"],
            "additionalProperties": false,
            "properties": {
                "notifications": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
                "unreadCount": {"type": "integer"}
            }
        }),
        "notifications::mark_read" => json!({
            "type": "object",
            "required": ["success"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"}
            }
        }),
        "notifications::mark_all_read" => json!({
            "type": "object",
            "required": ["marked"],
            "additionalProperties": false,
            "properties": {
                "marked": {"type": "integer"}
            }
        }),
        "plan::enter" | "plan::exit" | "plan::get_state" => json!({
            "type": "object",
            "required": ["planMode"],
            "additionalProperties": false,
            "properties": {
                "planMode": {"type": "boolean"}
            }
        }),
        "prompt_library::history_list" => json!({
            "type": "object",
            "required": ["items", "nextCursor"],
            "additionalProperties": false,
            "properties": {
                "items": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
                "nextCursor": {"type": ["string", "null"]}
            }
        }),
        "prompt_library::history_delete" => json!({
            "type": "object",
            "required": ["deleted"],
            "additionalProperties": false,
            "properties": {
                "deleted": {"type": "boolean"}
            }
        }),
        "prompt_library::history_clear" => json!({
            "type": "object",
            "required": ["deletedCount"],
            "additionalProperties": false,
            "properties": {
                "deletedCount": {"type": "integer"}
            }
        }),
        "prompt_library::snippet_list" => json!({
            "type": "object",
            "required": ["items"],
            "additionalProperties": false,
            "properties": {
                "items": {"type": "array", "items": {"type": "object", "additionalProperties": true}}
            }
        }),
        "prompt_library::snippet_get" => json!({
            "type": "object",
            "required": ["snippet"],
            "additionalProperties": false,
            "properties": {
                "snippet": {"type": "object", "additionalProperties": true}
            }
        }),
        "prompt_library::snippet_create" | "prompt_library::snippet_update" => json!({
            "type": "object",
            "required": ["snippet"],
            "additionalProperties": false,
            "properties": {
                "snippet": {"type": "object", "additionalProperties": true}
            }
        }),
        "prompt_library::snippet_delete" => json!({
            "type": "object",
            "required": ["deleted"],
            "additionalProperties": false,
            "properties": {
                "deleted": {"type": "boolean"}
            }
        }),
        method if method.starts_with("git::") || method.starts_with("worktree::") => {
            json!({
                "type": "object",
                "additionalProperties": true
            })
        }
        _ => return None,
    })
}
