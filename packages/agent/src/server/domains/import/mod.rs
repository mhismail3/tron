//! import domain worker.
//!
//! This module owns canonical function execution for the import namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;

use std::path::PathBuf;

use serde_json::{Value, json};

use super::*;

pub(crate) fn worker_module(
    deps: &EngineCapabilityDeps,
) -> crate::engine::Result<DomainWorkerModule> {
    super::domain_worker_module(
        "import",
        contract::capabilities()?,
        Deps::from_engine(deps),
        super::import_handler,
    )
}
#[derive(Clone)]
pub(crate) struct Deps {
    capability_context: Arc<ServerCapabilityContext>,
    event_store: Arc<EventStore>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &EngineCapabilityDeps) -> Self {
        Self {
            capability_context: deps.capability_context.clone(),
            event_store: deps.event_store.clone(),
        }
    }
}

use crate::server::shared::error_mapping::map_import_error;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    match method {
        "import::list_sources" => list_sources(deps).await,
        "import::list_sessions" => list_sessions(&invocation.payload, deps).await,
        "import::preview_session" => preview_session(&invocation.payload, deps).await,
        "import::execute" => execute_import(&invocation.payload, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("import method {method} is not engine-owned"),
        }),
    }
}

async fn list_sources(deps: &Deps) -> Result<Value, CapabilityError> {
    deps.capability_context
        .run_blocking("import::list_sources", move || {
            let claude_projects =
                PathBuf::from(crate::core::paths::home_dir()).join(".claude").join("projects");
            let Ok(projects) = crate::import::discover_projects(&claude_projects) else {
                return Ok(json!({ "sources": [] }));
            };
            let sources: Vec<Value> = projects
                .into_iter()
                .map(|project| {
                    json!({
                        "projectPath": project.project_path,
                        "projectName": project.project_path.rsplit('/').next().unwrap_or(&project.project_path),
                        "encodedDir": project.encoded_dir,
                        "sessionCount": project.session_count,
                    })
                })
                .collect();
            Ok(json!({ "sources": sources }))
        })
        .await
}

async fn list_sessions(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    let encoded_dir = require_string_param(Some(payload), "encodedDir")?;
    let event_store = deps.event_store.clone();
    deps.capability_context
        .run_blocking("import::list_sessions", move || {
            let claude_projects = PathBuf::from(crate::core::paths::home_dir())
                .join(".claude")
                .join("projects");
            let project_dir = claude_projects.join(&encoded_dir);
            let sessions =
                crate::import::discover_sessions(&project_dir).map_err(map_import_error)?;
            let result: Vec<Value> = sessions
                .into_iter()
                .map(|session| {
                    let (imported, existing_id) =
                        check_already_imported(&event_store, &session.session_uuid)
                            .unwrap_or((false, None));
                    Ok(json!({
                        "sessionPath": session.file_path,
                        "title": session.title,
                        "slug": session.slug,
                        "createdAt": session.first_timestamp,
                        "lastActivityAt": session.last_timestamp,
                        "messageCount": session.message_count,
                        "model": session.model,
                        "inputTokens": session.input_tokens,
                        "outputTokens": session.output_tokens,
                        "alreadyImported": imported,
                        "existingTronSessionId": existing_id,
                    }))
                })
                .collect::<Result<Vec<_>, CapabilityError>>()?;
            Ok(json!({ "sessions": result }))
        })
        .await
}

async fn preview_session(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    let session_path = require_string_param(Some(payload), "sessionPath")?;
    deps.capability_context
        .run_blocking("import::preview_session", move || {
            let path = PathBuf::from(&session_path);
            let records = crate::import::parser::parse_session(&path).map_err(map_import_error)?;
            let linear = crate::import::tree::linearize(records);
            let assembled = crate::import::assembler::assemble(linear);
            let result = crate::import::transformer::transform(assembled);
            let mut messages = Vec::new();
            let mut msg_idx = 0;
            for spec in &result.events {
                match spec.event_type {
                    crate::events::EventType::MessageUser => {
                        let content = spec.payload.get("content");
                        messages.push(json!({
                            "id": format!("preview_{msg_idx}"),
                            "role": "user",
                            "contentPreview": content_preview(content, 200),
                            "hasToolUse": false,
                        }));
                        msg_idx += 1;
                    }
                    crate::events::EventType::MessageAssistant => {
                        let content = spec.payload.get("content");
                        let has_tool_use =
                            content.and_then(Value::as_array).is_some_and(|blocks| {
                                blocks.iter().any(|block| {
                                    block.get("type").and_then(Value::as_str) == Some("tool_use")
                                })
                            });
                        let tool_name = content.and_then(Value::as_array).and_then(|blocks| {
                            blocks.iter().find_map(|block| {
                                if block.get("type").and_then(Value::as_str) == Some("tool_use") {
                                    block.get("name").and_then(Value::as_str).map(String::from)
                                } else {
                                    None
                                }
                            })
                        });
                        messages.push(json!({
                            "id": format!("preview_{msg_idx}"),
                            "role": "assistant",
                            "contentPreview": content_preview(content, 200),
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
            let validation = crate::import::validate_session(&path).map_err(map_import_error)?;
            let warnings_json = validation
                .warnings
                .iter()
                .map(import_warning_to_json)
                .collect::<Vec<_>>();
            Ok(json!({
                "messages": messages,
                "totalMessages": result.message_count,
                "stats": {
                    "inputTokens": result.total_input_tokens,
                    "outputTokens": result.total_output_tokens,
                    "estimatedCost": result.total_cost,
                    "model": result.model,
                    "hasCompaction": result.events.iter().any(|event| event.event_type == crate::events::EventType::CompactBoundary),
                },
                "warnings": warnings_json,
                "validation": {
                    "recordsParsed": validation.records_parsed,
                    "linesTotal": validation.lines_total,
                    "eventsReady": validation.events_ready,
                },
            }))
        })
        .await
}

async fn execute_import(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    let session_path = require_string_param(Some(payload), "sessionPath")?;
    let tags: Vec<String> = payload
        .get("tags")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|value| value.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();
    let working_directory = opt_string(Some(payload), "workingDirectory").unwrap_or_default();
    let event_store = deps.event_store.clone();
    let origin = deps.capability_context.origin.clone();
    let session_path = session_path.to_owned();

    deps.capability_context
        .run_blocking("import::execute", move || {
            let path = PathBuf::from(&session_path);
            let wd = if working_directory.is_empty() {
                path.parent()
                    .and_then(|p| p.file_name())
                    .and_then(|n| n.to_str())
                    .map(crate::import::parser::decode_project_dir)
                    .ok_or_else(|| CapabilityError::InvalidParams {
                        message: "Could not derive working directory from session path; pass `workingDirectory` explicitly".to_string(),
                    })?
            } else {
                working_directory
            };

            match crate::import::import_session(&event_store, &path, &wd, &tags, Some(&origin)) {
                Ok(result) => {
                    let warnings_json = result
                        .warnings
                        .iter()
                        .map(import_warning_to_json)
                        .collect::<Vec<_>>();
                    Ok(json!({
                        "sessionId": result.tron_session_id,
                        "workingDirectory": result.working_directory,
                        "model": result.model,
                        "eventCount": result.event_count,
                        "turnCount": result.turn_count,
                        "messageCount": result.message_count,
                        "cost": result.total_cost,
                        "alreadyImported": false,
                        "warnings": warnings_json,
                    }))
                }
                Err(crate::import::ImportError::AlreadyImported { tron_session_id }) => {
                    Ok(json!({
                        "alreadyImported": true,
                        "existingSessionId": tron_session_id,
                    }))
                }
                Err(error) => Err(map_import_error(error)),
            }
        })
        .await
}

fn check_already_imported(
    event_store: &EventStore,
    session_uuid: &str,
) -> Result<(bool, Option<String>), CapabilityError> {
    let tag = format!("claude_code_import:{session_uuid}");
    let result = event_store
        .find_session_id_with_metadata_tag(&tag)
        .map_err(map_event_store_error)?;
    Ok(match result {
        Some(id) => (true, Some(id)),
        None => (false, None),
    })
}

fn content_preview(content: Option<&Value>, max_len: usize) -> String {
    let text = match content {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Array(blocks)) => blocks
            .iter()
            .filter_map(|block| match block.get("type").and_then(Value::as_str) {
                Some("text") => block
                    .get("text")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
                Some("thinking") => block
                    .get("thinking")
                    .and_then(Value::as_str)
                    .filter(|value| !value.is_empty())
                    .map(|value| format!("[thinking] {value}")),
                Some("tool_use") => block
                    .get("name")
                    .and_then(Value::as_str)
                    .map(|name| format!("[tool: {name}]")),
                Some("tool_result") => Some("[tool result]".to_owned()),
                _ => None,
            })
            .collect::<Vec<String>>()
            .join(" "),
        _ => String::new(),
    };
    if text.len() > max_len {
        format!("{}…", &text[..max_len])
    } else {
        text
    }
}

fn import_warning_to_json(warning: &crate::import::ImportWarning) -> Value {
    let (kind, details) = match &warning.kind {
        crate::import::ImportWarningKind::UnparseableLine { line_number } => {
            ("unparseable-line", json!({ "lineNumber": line_number }))
        }
        crate::import::ImportWarningKind::OrphanToolResult { tool_call_id } => {
            ("orphan-tool-result", json!({ "toolCallId": tool_call_id }))
        }
        crate::import::ImportWarningKind::OrphanToolUse { tool_call_id } => {
            ("orphan-tool-use", json!({ "toolCallId": tool_call_id }))
        }
        crate::import::ImportWarningKind::AssistantMissingModel => {
            ("assistant-missing-model", json!({}))
        }
    };
    json!({
        "kind": kind,
        "message": warning.message,
        "details": details,
    })
}
