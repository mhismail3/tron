//! Claude Code session import handlers.
//!
//! Four RPC methods for discovering, previewing, and importing
//! Claude Code sessions:
//!
//! | Method                 | Purpose |
//! |------------------------|---------|
//! | `import.listSources`   | List Claude Code project directories |
//! | `import.listSessions`  | List sessions in a project |
//! | `import.previewSession` | Preview a session before import |
//! | `import.execute`       | Import a session into Tron |

use std::path::PathBuf;

use async_trait::async_trait;
use serde_json::{Value, json};
use tracing::instrument;

use super::{opt_string, require_string_param};
use crate::core::paths::home_dir;
use crate::import;
use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::registry::MethodHandler;

/// List Claude Code project directories.
pub struct ListSourcesHandler;

#[async_trait]
impl MethodHandler for ListSourcesHandler {
    #[instrument(skip(self, ctx), fields(method = "import.listSources"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        ctx.run_blocking("import.listSources", move || {
            let claude_projects = PathBuf::from(home_dir())
                .join(".claude")
                .join("projects");

            // No Claude dir or I/O error → empty list (not an error for the client)
            let Ok(projects) = import::discover_projects(&claude_projects) else {
                return Ok(json!({ "sources": [] }));
            };

            let sources: Vec<Value> = projects
                .into_iter()
                .map(|p| {
                    json!({
                        "projectPath": p.project_path,
                        "projectName": p.project_path.rsplit('/').next().unwrap_or(&p.project_path),
                        "encodedDir": p.encoded_dir,
                        "sessionCount": p.session_count,
                    })
                })
                .collect();
            Ok(json!({ "sources": sources }))
        })
        .await
    }
}

/// List sessions within a Claude Code project directory.
pub struct ListSessionsHandler;

#[async_trait]
impl MethodHandler for ListSessionsHandler {
    #[instrument(skip(self, ctx), fields(method = "import.listSessions"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let encoded_dir = require_string_param(params.as_ref(), "encodedDir")?;
        let event_store = ctx.event_store.clone();

        ctx.run_blocking("import.listSessions", move || {
            let claude_projects = PathBuf::from(home_dir())
                .join(".claude")
                .join("projects");

            let project_dir = claude_projects.join(&encoded_dir);

            let sessions = import::discover_sessions(&project_dir)
                .map_err(|e| RpcError::Internal { message: e.to_string() })?;

            let result: Vec<Value> = sessions
                .into_iter()
                .map(|s| {
                    let already_imported =
                        check_already_imported(&event_store, &s.session_uuid);
                    let (imported, existing_id) = already_imported
                        .unwrap_or((false, None));

                    json!({
                        "sessionPath": s.file_path,
                        "title": s.title,
                        "slug": s.slug,
                        "createdAt": s.first_timestamp,
                        "lastActivityAt": s.last_timestamp,
                        "messageCount": s.message_count,
                        "model": s.model,
                        "inputTokens": s.input_tokens,
                        "outputTokens": s.output_tokens,
                        "alreadyImported": imported,
                        "existingTronSessionId": existing_id,
                    })
                })
                .collect();

            Ok(json!({ "sessions": result }))
        })
        .await
    }
}

/// Preview a Claude Code session before importing.
pub struct PreviewSessionHandler;

#[async_trait]
impl MethodHandler for PreviewSessionHandler {
    #[instrument(skip(self, ctx), fields(method = "import.previewSession"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_path = require_string_param(params.as_ref(), "sessionPath")?;

        ctx.run_blocking("import.previewSession", move || {
            let path = PathBuf::from(&session_path);
            let records = import::parser::parse_session(&path)
                .map_err(|e| RpcError::Internal { message: e.to_string() })?;

            let linear = import::tree::linearize(records);
            let assembled = import::assembler::assemble(linear);
            let result = import::transformer::transform(assembled);

            let mut messages = Vec::new();
            let mut msg_idx = 0;
            for spec in &result.events {
                match spec.event_type {
                    crate::events::EventType::MessageUser => {
                        let content = spec.payload.get("content");
                        let preview = content_preview(content, 200);
                        messages.push(json!({
                            "id": format!("preview_{msg_idx}"),
                            "role": "user",
                            "contentPreview": preview,
                            "hasToolUse": false,
                        }));
                        msg_idx += 1;
                    }
                    crate::events::EventType::MessageAssistant => {
                        let content = spec.payload.get("content");
                        let has_tool_use = content
                            .and_then(|c| c.as_array())
                            .is_some_and(|blocks| {
                                blocks.iter().any(|b| {
                                    b.get("type").and_then(Value::as_str) == Some("tool_use")
                                })
                            });
                        let tool_name = content
                            .and_then(|c| c.as_array())
                            .and_then(|blocks| {
                                blocks.iter().find_map(|b| {
                                    if b.get("type").and_then(Value::as_str) == Some("tool_use") {
                                        b.get("name").and_then(Value::as_str).map(String::from)
                                    } else {
                                        None
                                    }
                                })
                            });
                        let preview = content_preview(content, 200);
                        messages.push(json!({
                            "id": format!("preview_{msg_idx}"),
                            "role": "assistant",
                            "contentPreview": preview,
                            "hasToolUse": has_tool_use,
                            "toolName": tool_name,
                        }));
                        msg_idx += 1;
                    }
                    _ => {}
                }
                if messages.len() >= 20 {
                    break;
                }
            }

            let total_messages = result.message_count;
            let has_compaction = result.events.iter().any(|e| {
                e.event_type == crate::events::EventType::CompactBoundary
            });

            Ok(json!({
                "messages": messages,
                "totalMessages": total_messages,
                "stats": {
                    "inputTokens": result.total_input_tokens,
                    "outputTokens": result.total_output_tokens,
                    "estimatedCost": result.total_cost,
                    "model": result.model,
                    "hasCompaction": has_compaction,
                }
            }))
        })
        .await
    }
}

/// Execute the import of a Claude Code session into Tron.
pub struct ExecuteImportHandler;

#[async_trait]
impl MethodHandler for ExecuteImportHandler {
    #[instrument(skip(self, ctx), fields(method = "import.execute"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_path = require_string_param(params.as_ref(), "sessionPath")?;
        let tags: Vec<String> = params
            .as_ref()
            .and_then(|p| p.get("tags"))
            .and_then(|t| t.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default();
        let working_directory = opt_string(params.as_ref(), "workingDirectory")
            .unwrap_or_default();

        let event_store = ctx.event_store.clone();
        let origin = ctx.origin.clone();

        ctx.run_blocking("import.execute", move || {
            let path = PathBuf::from(&session_path);

            // Derive working directory from the Claude Code project path if not provided.
            let wd = if working_directory.is_empty() {
                path.parent()
                    .and_then(|p| p.file_name())
                    .and_then(|n| n.to_str())
                    .map(import::parser::decode_project_dir)
                    .ok_or_else(|| RpcError::Internal {
                        message: "Could not derive working directory from session path".to_string(),
                    })?
            } else {
                working_directory
            };

            match import::import_session(&event_store, &path, &wd, &tags, Some(&origin)) {
                Ok(result) => Ok(json!({
                    "sessionId": result.tron_session_id,
                    "workingDirectory": result.working_directory,
                    "model": result.model,
                    "eventCount": result.event_count,
                    "turnCount": result.turn_count,
                    "messageCount": result.message_count,
                    "cost": result.total_cost,
                    "alreadyImported": false,
                })),
                Err(import::ImportError::AlreadyImported { tron_session_id }) => Ok(json!({
                    "alreadyImported": true,
                    "existingSessionId": tron_session_id,
                })),
                Err(e) => Err(RpcError::Internal { message: e.to_string() }),
            }
        })
        .await
    }
}

/// Check if a Claude Code session has already been imported.
fn check_already_imported(
    event_store: &crate::events::EventStore,
    session_uuid: &str,
) -> Result<(bool, Option<String>), RpcError> {
    let tag = format!("claude_code_import:{session_uuid}");
    let result = import::writer::find_session_with_tag(event_store, &tag)
        .map_err(|e| RpcError::Internal { message: e.to_string() })?;
    Ok(match result {
        Some(id) => (true, Some(id)),
        None => (false, None),
    })
}

/// Extract a text preview from content, truncated to `max_len`.
fn content_preview(content: Option<&Value>, max_len: usize) -> String {
    let text = match content {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Array(blocks)) => {
            let mut parts = Vec::new();
            for block in blocks {
                match block.get("type").and_then(Value::as_str) {
                    Some("text") => {
                        if let Some(t) = block.get("text").and_then(Value::as_str) {
                            parts.push(t.to_string());
                        }
                    }
                    Some("thinking") => {
                        if let Some(t) = block.get("thinking").and_then(Value::as_str)
                            && !t.is_empty()
                        {
                            parts.push(format!("[thinking] {t}"));
                        }
                    }
                    Some("tool_use") => {
                        if let Some(name) = block.get("name").and_then(Value::as_str) {
                            parts.push(format!("[tool: {name}]"));
                        }
                    }
                    Some("tool_result") => {
                        parts.push("[tool result]".to_string());
                    }
                    _ => {}
                }
            }
            parts.join(" ")
        }
        _ => String::new(),
    };

    if text.len() > max_len {
        format!("{}…", &text[..max_len])
    } else {
        text
    }
}

#[cfg(test)]
#[path = "import_tests.rs"]
mod tests;
