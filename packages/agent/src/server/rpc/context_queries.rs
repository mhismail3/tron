use std::path::Path;
use std::sync::Arc;

use parking_lot::RwLock;
use serde_json::{Value, json};
use crate::skills::registry::SkillRegistry;

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::context_service::{
    PreparedSessionContext, build_active_skill_context, build_context_manager_for_session,
    build_summarizer, retry_context_read, tool_definitions,
};
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::session_context::{RuleFileLevel, collect_dynamic_rule_paths};

pub(crate) struct ContextQueryService;

impl ContextQueryService {
    pub(crate) async fn get_snapshot(
        ctx: &RpcContext,
        session_id: String,
    ) -> Result<Value, RpcError> {
        let session_manager = ctx.session_manager.clone();
        let event_store = ctx.event_store.clone();
        let context_artifacts = ctx.context_artifacts.clone();
        let tool_definitions = tool_definitions(ctx);
        let session_id_for_query = session_id.clone();
        ctx.run_blocking("context.get_snapshot", move || {
            retry_context_read("context.get_snapshot", || {
                let prepared = build_context_manager_for_session(
                    &session_id_for_query,
                    session_manager.as_ref(),
                    event_store.as_ref(),
                    context_artifacts.as_ref(),
                    tool_definitions.clone(),
                )?;
                let snapshot = prepared.context_manager.get_snapshot();
                Ok(snapshot_response(&snapshot))
            })
        })
        .await
    }

    pub(crate) async fn get_detailed_snapshot(
        ctx: &RpcContext,
        session_id: String,
    ) -> Result<Value, RpcError> {
        let session_manager = ctx.session_manager.clone();
        let event_store = ctx.event_store.clone();
        let context_artifacts = ctx.context_artifacts.clone();
        let skill_registry = ctx.skill_registry.clone();
        let tool_definitions = tool_definitions(ctx);
        let session_id_for_query = session_id.clone();
        ctx.run_blocking("context.get_detailed_snapshot", move || {
            retry_context_read("context.get_detailed_snapshot", || {
                let prepared = build_context_manager_for_session(
                    &session_id_for_query,
                    session_manager.as_ref(),
                    event_store.as_ref(),
                    context_artifacts.as_ref(),
                    tool_definitions.clone(),
                )?;
                build_detailed_snapshot_response(
                    event_store.as_ref(),
                    &session_id_for_query,
                    prepared,
                    &skill_registry,
                )
            })
        })
        .await
    }

    pub(crate) async fn should_compact(
        ctx: &RpcContext,
        session_id: String,
    ) -> Result<Value, RpcError> {
        let session_manager = ctx.session_manager.clone();
        let event_store = ctx.event_store.clone();
        let context_artifacts = ctx.context_artifacts.clone();
        let tool_definitions = tool_definitions(ctx);
        let session_id_for_query = session_id.clone();
        ctx.run_blocking("context.should_compact", move || {
            retry_context_read("context.should_compact", || {
                let prepared = build_context_manager_for_session(
                    &session_id_for_query,
                    session_manager.as_ref(),
                    event_store.as_ref(),
                    context_artifacts.as_ref(),
                    tool_definitions.clone(),
                )?;
                Ok(json!({
                    "shouldCompact": prepared.context_manager.should_compact(),
                }))
            })
        })
        .await
    }

    pub(crate) async fn preview_compaction(
        ctx: &RpcContext,
        session_id: String,
    ) -> Result<Value, RpcError> {
        let prepared =
            prepare_session_context(ctx, "context.preview_compaction.prepare", &session_id).await?;
        let summarizer = build_summarizer(ctx, &session_id, &prepared.session.working_directory);
        let preview = prepared
            .context_manager
            .preview_compaction(summarizer.as_ref())
            .await
            .map_err(|error| RpcError::Internal {
                message: format!("Compaction preview failed: {error}"),
            })?;

        Ok(json!({
            "tokensBefore": preview.tokens_before,
            "tokensAfter": preview.tokens_after,
            "compressionRatio": preview.compression_ratio,
            "preservedMessages": preview.preserved_messages,
            "summarizedMessages": preview.summarized_messages,
            "summary": preview.summary,
            "extractedData": preview.extracted_data,
        }))
    }

    pub(crate) async fn can_accept_turn(
        ctx: &RpcContext,
        session_id: String,
    ) -> Result<Value, RpcError> {
        let session_manager = ctx.session_manager.clone();
        let event_store = ctx.event_store.clone();
        let context_artifacts = ctx.context_artifacts.clone();
        let tool_definitions = tool_definitions(ctx);
        let session_id_for_query = session_id.clone();
        ctx.run_blocking("context.can_accept_turn", move || {
            retry_context_read("context.can_accept_turn", || {
                let prepared = build_context_manager_for_session(
                    &session_id_for_query,
                    session_manager.as_ref(),
                    event_store.as_ref(),
                    context_artifacts.as_ref(),
                    tool_definitions.clone(),
                )?;
                Ok(json!({
                    "canAcceptTurn": prepared.context_manager.can_accept_turn().can_proceed,
                }))
            })
        })
        .await
    }
}

pub(crate) async fn prepare_session_context(
    ctx: &RpcContext,
    task_name: &'static str,
    session_id: &str,
) -> Result<PreparedSessionContext, RpcError> {
    let session_manager = ctx.session_manager.clone();
    let event_store = ctx.event_store.clone();
    let context_artifacts = ctx.context_artifacts.clone();
    let tool_definitions = tool_definitions(ctx);
    let session_id = session_id.to_owned();
    ctx.run_blocking(task_name, move || {
        retry_context_read(task_name, || {
            build_context_manager_for_session(
                &session_id,
                session_manager.as_ref(),
                event_store.as_ref(),
                context_artifacts.as_ref(),
                tool_definitions.clone(),
            )
        })
    })
    .await
}

fn snapshot_response(snapshot: &crate::runtime::context::types::ContextSnapshot) -> Value {
    json!({
        "currentTokens": snapshot.current_tokens,
        "contextLimit": snapshot.context_limit,
        "usagePercent": snapshot.usage_percent,
        "thresholdLevel": snapshot.threshold_level,
        "breakdown": {
            "systemPrompt": snapshot.breakdown.system_prompt,
            "tools": snapshot.breakdown.tools,
            "rules": snapshot.breakdown.rules,
            "messages": snapshot.breakdown.messages,
        },
    })
}

fn build_detailed_snapshot_response(
    event_store: &crate::events::EventStore,
    session_id: &str,
    prepared: PreparedSessionContext,
    skill_registry: &Arc<RwLock<SkillRegistry>>,
) -> Result<Value, RpcError> {
    let PreparedSessionContext {
        session,
        artifacts,
        context_manager,
    } = prepared;
    let detailed = context_manager.get_detailed_snapshot();
    let added_skills = build_added_skills(event_store, session_id)?;
    let composed_system_prompt =
        build_composed_system_prompt(&context_manager, &session, &added_skills, skill_registry);

    Ok(json!({
        "currentTokens": detailed.snapshot.current_tokens,
        "contextLimit": detailed.snapshot.context_limit,
        "usagePercent": detailed.snapshot.usage_percent,
        "thresholdLevel": detailed.snapshot.threshold_level,
        "breakdown": {
            "systemPrompt": detailed.snapshot.breakdown.system_prompt,
            "tools": detailed.snapshot.breakdown.tools,
            "rules": detailed.snapshot.breakdown.rules,
            "messages": detailed.snapshot.breakdown.messages,
        },
        "messages": build_detailed_messages(&detailed.messages),
        "systemPromptContent": detailed.system_prompt_content,
        "toolClarificationContent": detailed.tool_clarification_content,
        "toolsContent": detailed.tools_content,
        "addedSkills": added_skills,
        "rules": build_rules_info(event_store, session_id, &session, &artifacts, detailed.snapshot.breakdown.rules),
        "memory": build_memory_info(artifacts.memory.as_ref()),
        "sessionMemories": build_session_memory_info(context_manager.get_session_memories()),
        "taskContext": null,
        "composedSystemPrompt": composed_system_prompt,
        "environment": {
            "workingDirectory": session.working_directory,
            "serverOrigin": session.origin,
        },
    }))
}

fn build_detailed_messages(
    messages: &[crate::runtime::context::types::DetailedMessageInfo],
) -> Vec<Value> {
    messages
        .iter()
        .map(|message| {
            let mut value = json!({
                "index": message.index,
                "role": message.role,
                "tokens": message.tokens,
                "summary": message.summary,
                "content": message.content,
            });
            if let Some(tool_calls) = message.tool_calls.as_ref() {
                value["toolCalls"] = json!(
                    tool_calls
                        .iter()
                        .map(|tool_call| json!({
                            "id": tool_call.id,
                            "name": tool_call.name,
                            "tokens": tool_call.tokens,
                            "arguments": tool_call.arguments,
                        }))
                        .collect::<Vec<_>>()
                );
            }
            if let Some(tool_call_id) = message.tool_call_id.as_ref() {
                value["toolCallId"] = json!(tool_call_id);
            }
            if let Some(is_error) = message.is_error {
                value["isError"] = json!(is_error);
            }
            if let Some(event_id) = message.event_id.as_ref() {
                value["eventId"] = json!(event_id);
            }
            value
        })
        .collect()
}

fn build_added_skills(
    event_store: &crate::events::EventStore,
    session_id: &str,
) -> Result<Vec<Value>, RpcError> {
    let added_events = event_store
        .get_events_by_type(session_id, &["skill.added"], None)
        .map_err(|error| RpcError::Internal {
            message: error.to_string(),
        })?;
    let removed_events = event_store
        .get_events_by_type(session_id, &["skill.removed"], None)
        .map_err(|error| RpcError::Internal {
            message: error.to_string(),
        })?;

    let removed_names: std::collections::HashSet<String> = removed_events
        .iter()
        .filter_map(|event| {
            serde_json::from_str::<Value>(&event.payload)
                .ok()
                .and_then(|payload| {
                    payload
                        .get("skillName")
                        .and_then(Value::as_str)
                        .map(String::from)
                })
        })
        .collect();

    Ok(added_events
        .iter()
        .filter_map(|event| {
            let payload: Value = serde_json::from_str(&event.payload).ok()?;
            let name = payload.get("skillName")?.as_str()?;
            if removed_names.contains(name) {
                return None;
            }
            let source = payload
                .get("source")
                .and_then(Value::as_str)
                .unwrap_or("global");
            let added_via = payload
                .get("addedVia")
                .and_then(Value::as_str)
                .unwrap_or("mention");
            let tokens = payload.get("tokens").and_then(Value::as_u64);

            let mut skill = json!({
                "name": name,
                "source": source,
                "addedVia": added_via,
                "eventId": event.id,
            });
            if let Some(tokens) = tokens {
                skill["tokens"] = json!(tokens);
            }
            Some(skill)
        })
        .collect())
}

fn build_composed_system_prompt(
    context_manager: &crate::runtime::context::context_manager::ContextManager,
    session: &crate::events::sqlite::row_types::SessionRow,
    added_skills: &[Value],
    skill_registry: &Arc<RwLock<SkillRegistry>>,
) -> String {
    let active_skill_names: Vec<String> = added_skills
        .iter()
        .filter_map(|skill| skill.get("name").and_then(Value::as_str).map(String::from))
        .collect();
    let skill_context = build_active_skill_context(&active_skill_names, skill_registry);

    let mut composed_context = context_manager.build_base_context();
    composed_context.server_origin.clone_from(&session.origin);
    composed_context.skill_context = skill_context;

    crate::llm::compose_context_parts(&composed_context).join("\n\n")
}

fn build_rules_info(
    event_store: &crate::events::EventStore,
    session_id: &str,
    session: &crate::events::sqlite::row_types::SessionRow,
    artifacts: &crate::server::rpc::session_context::SessionContextArtifacts,
    rules_tokens: u64,
) -> Option<Value> {
    let mut files: Vec<Value> = artifacts
        .rules
        .files
        .iter()
        .map(|file| {
            let relative_path = if file.level == RuleFileLevel::Global {
                format!("~/{}", file.relative_path)
            } else {
                file.relative_path.clone()
            };
            let depth = if file.level == RuleFileLevel::Global {
                -1_i64
            } else {
                #[allow(clippy::cast_possible_wrap)]
                {
                    file.depth as i64
                }
            };
            json!({
                "path": file.path.to_string_lossy(),
                "relativePath": relative_path,
                "level": file.level.as_str(),
                "depth": depth,
            })
        })
        .collect();

    let dynamic_paths = collect_dynamic_rule_paths(event_store, session_id);
    let mut existing_paths: std::collections::HashSet<String> = files
        .iter()
        .filter_map(|file| {
            file.get("relativePath")
                .and_then(Value::as_str)
                .map(String::from)
        })
        .collect();
    for relative_path in dynamic_paths {
        if existing_paths.insert(relative_path.clone()) {
            let abs = Path::new(&session.working_directory).join(&relative_path);
            files.push(json!({
                "path": abs.to_string_lossy(),
                "relativePath": relative_path,
                "level": "directory",
                "depth": relative_path.matches('/').count(),
            }));
        }
    }

    let total_files = files.len();
    if total_files == 0 {
        None
    } else {
        Some(json!({
            "files": files,
            "totalFiles": total_files,
            "tokens": rules_tokens,
        }))
    }
}

fn build_memory_info(memory: Option<&crate::server::rpc::session_context::LoadedMemory>) -> Option<Value> {
    let memory = memory?;
    if memory.entries.is_empty() {
        return None;
    }
    let entries: Vec<Value> = memory
        .entries
        .iter()
        .map(|entry| {
            json!({
                "title": entry.title,
                "content": entry.summary,
            })
        })
        .collect();
    Some(json!({
        "count": entries.len(),
        "tokens": memory.content_tokens_estimate(),
        "entries": entries,
    }))
}

fn build_session_memory_info(
    memories: &[crate::runtime::context::types::SessionMemoryEntry],
) -> Option<Value> {
    if memories.is_empty() {
        return None;
    }
    let entries: Vec<Value> = memories
        .iter()
        .map(|memory| json!({ "title": memory.title, "content": memory.content }))
        .collect();
    let total_tokens: u64 = memories.iter().map(|memory| memory.tokens).sum();
    Some(json!({
        "count": memories.len(),
        "tokens": total_tokens,
        "entries": entries,
    }))
}
