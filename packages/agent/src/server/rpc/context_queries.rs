use std::path::Path;
use std::sync::Arc;

use parking_lot::RwLock;
use serde_json::{Value, json};
use crate::skills::registry::SkillRegistry;
use crate::skills::tracker::SkillTracker;
use crate::skills::types::{SkillAddMethod, SkillSource};

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
        let skill_registry = ctx.skill_registry.clone();
        let tool_definitions = tool_definitions(ctx);
        let session_id_for_query = session_id.clone();
        ctx.run_blocking("context.get_snapshot", move || {
            retry_context_read("context.get_snapshot", || {
                let mut prepared = build_context_manager_for_session(
                    &session_id_for_query,
                    session_manager.as_ref(),
                    event_store.as_ref(),
                    context_artifacts.as_ref(),
                    tool_definitions.clone(),
                )?;
                // Skill index: skip for local models (index is stripped at turn time)
                if !prepared.context_manager.is_local_model() {
                    let skill_index_content = {
                        let mut registry = skill_registry.write();
                        let _ = registry.refresh_if_stale(&prepared.session.working_directory);
                        let skills = registry.list(None);
                        let index = crate::skills::injector::build_skill_index(&skills);
                        if index.is_empty() { None } else { Some(index) }
                    };
                    prepared.context_manager.set_skill_index_content(skill_index_content);
                }

                // Reconstruct volatile token estimates from session state
                // (runs for all models — users can manually activate skills)
                let added_skills = build_added_skills(
                    event_store.as_ref(),
                    &session_id_for_query,
                    &skill_registry,
                )?;
                set_volatile_tokens_from_session(
                    &mut prepared.context_manager,
                    &added_skills,
                    &skill_registry,
                    prepared.session.origin.as_deref(),
                );

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

/// Reconstruct volatile token estimates from session state so snapshots
/// queried between turns reflect active skills accurately.
fn set_volatile_tokens_from_session(
    context_manager: &mut crate::runtime::context::context_manager::ContextManager,
    added_skills: &[Value],
    skill_registry: &Arc<RwLock<SkillRegistry>>,
    server_origin: Option<&str>,
) {
    let active_skill_names: Vec<String> = added_skills
        .iter()
        .filter_map(|skill| skill.get("name").and_then(Value::as_str).map(String::from))
        .collect();
    let skill_context = build_active_skill_context(&active_skill_names, skill_registry);
    let skill_context_tokens = skill_context.as_ref().map_or(0, |s| s.len() as u64 / 4);

    context_manager.set_volatile_tokens(skill_context_tokens, 0, 0);
    context_manager.set_server_origin(server_origin.map(String::from));
}

fn snapshot_response(snapshot: &crate::runtime::context::types::ContextSnapshot) -> Value {
    json!({
        "currentTokens": snapshot.current_tokens,
        "contextLimit": snapshot.context_limit,
        "usagePercent": snapshot.usage_percent,
        "thresholdLevel": snapshot.threshold_level,
        "isLocalModel": snapshot.is_local_model,
        "breakdown": {
            "systemPrompt": snapshot.breakdown.system_prompt,
            "tools": snapshot.breakdown.tools,
            "rules": snapshot.breakdown.rules,
            "memory": snapshot.breakdown.memory,
            "skillIndex": snapshot.breakdown.skill_index,
            "skillContext": snapshot.breakdown.skill_context,
            "skillRemoval": snapshot.breakdown.skill_removal,
            "jobResults": snapshot.breakdown.job_results,
            "environment": snapshot.breakdown.environment,
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
        mut context_manager,
    } = prepared;

    // Skill index: skip for local models (index is stripped at turn time)
    if !context_manager.is_local_model() {
        let skill_index_content = {
            let mut registry = skill_registry.write();
            let _ = registry.refresh_if_stale(&session.working_directory);
            let skills = registry.list(None);
            let index = crate::skills::injector::build_skill_index(&skills);
            if index.is_empty() { None } else { Some(index) }
        };
        context_manager.set_skill_index_content(skill_index_content);
    }

    // Reconstruct volatile token estimates from session state so the snapshot
    // reflects active skills even when queried between turns
    // (runs for all models — users can manually activate skills).
    let added_skills = build_added_skills(event_store, session_id, skill_registry)?;
    set_volatile_tokens_from_session(
        &mut context_manager,
        &added_skills,
        skill_registry,
        session.origin.as_deref(),
    );

    let detailed = context_manager.get_detailed_snapshot();
    let composed_system_prompt =
        build_composed_system_prompt(&context_manager, &session, &added_skills, skill_registry);

    Ok(json!({
        "currentTokens": detailed.snapshot.current_tokens,
        "contextLimit": detailed.snapshot.context_limit,
        "usagePercent": detailed.snapshot.usage_percent,
        "thresholdLevel": detailed.snapshot.threshold_level,
        "isLocalModel": context_manager.is_local_model(),
        "breakdown": {
            "systemPrompt": detailed.snapshot.breakdown.system_prompt,
            "tools": detailed.snapshot.breakdown.tools,
            "rules": detailed.snapshot.breakdown.rules,
            "memory": detailed.snapshot.breakdown.memory,
            "skillIndex": detailed.snapshot.breakdown.skill_index,
            "skillContext": detailed.snapshot.breakdown.skill_context,
            "skillRemoval": detailed.snapshot.breakdown.skill_removal,
            "jobResults": detailed.snapshot.breakdown.job_results,
            "environment": detailed.snapshot.breakdown.environment,
            "messages": detailed.snapshot.breakdown.messages,
        },
        "messages": build_detailed_messages(&detailed.messages),
        "systemPromptContent": detailed.system_prompt_content,
        "toolClarificationContent": detailed.tool_clarification_content,
        "toolsContent": detailed.tools_content,
        "addedSkills": added_skills,
        "rules": build_rules_info(event_store, session_id, &session, &artifacts, detailed.snapshot.breakdown.rules),
        "memory": null,
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
    skill_registry: &Arc<RwLock<SkillRegistry>>,
) -> Result<Vec<Value>, RpcError> {
    let policy = {
        let settings = crate::settings::get_settings();
        settings.skills.compaction_policy.clone()
    };

    let events = event_store
        .get_events_by_type(
            session_id,
            &[
                "skill.activated",
                "skill.deactivated",
                "context.cleared",
                "compact.boundary",
                "skills.cleared",
            ],
            None,
        )
        .map_err(|error| RpcError::Internal {
            message: error.to_string(),
        })?;

    let json_events: Vec<Value> = events
        .iter()
        .filter_map(|e| {
            serde_json::from_str::<Value>(&e.payload).ok().map(|payload| {
                json!({
                    "type": e.event_type,
                    "id": e.id,
                    "payload": payload,
                })
            })
        })
        .collect();

    let tracker = SkillTracker::from_events_with_policy(&json_events, &policy);

    Ok(tracker
        .added_skills()
        .into_iter()
        .map(|skill| {
            let source_str = match skill.source {
                SkillSource::Global => "global",
                SkillSource::Project => "project",
            };
            let added_via_str = match skill.added_via {
                SkillAddMethod::Mention => "mention",
                SkillAddMethod::Explicit => "explicit",
            };
            // Enrich with service from registry (robust to historical events
            // that predate the service field on skill.activated payloads).
            let service = skill_registry
                .read()
                .get(&skill.name)
                .map(|m| m.service.clone())
                .unwrap_or_else(|| "unknown".to_string());
            let mut value = json!({
                "name": skill.name,
                "source": source_str,
                "service": service,
                "addedVia": added_via_str,
                "eventId": skill.event_id,
            });
            if let Some(tokens) = skill.tokens {
                value["tokens"] = json!(tokens);
            }
            value
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
            let display_path = if file.level == RuleFileLevel::Global {
                let filename = Path::new(&*file.path.to_string_lossy())
                    .file_name()
                    .map(|f| f.to_string_lossy().to_string())
                    .unwrap_or_else(|| file.relative_path.clone());
                format!("~/.tron/{filename}")
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
                "displayPath": display_path,
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
                "displayPath": relative_path,
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
