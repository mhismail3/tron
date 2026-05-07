use std::path::Path;
use std::sync::Arc;

use crate::skills::registry::SkillRegistry;
use crate::skills::tracker::SkillTracker;
use crate::skills::types::{SkillAddMethod, SkillSource};
use parking_lot::RwLock;
use rusqlite::{OptionalExtension, params};
use serde_json::{Value, json};

use crate::server::services::context::ServerCapabilityContext;
use crate::server::services::context_service::{
    PreparedSessionContext, build_active_skill_context, build_context_manager_for_session,
    build_summarizer, retry_context_read, tool_definitions,
};
use crate::server::services::session_context::{RuleFileLevel, collect_dynamic_rule_paths};
use crate::server::transport::json_rpc::errors::RpcError;

pub(crate) struct ContextQueryService;

impl ContextQueryService {
    pub(crate) async fn get_snapshot(
        ctx: &ServerCapabilityContext,
        session_id: String,
    ) -> Result<Value, RpcError> {
        let session_manager = ctx.session_manager.clone();
        let event_store = ctx.event_store.clone();
        let context_artifacts = ctx.context_artifacts.clone();
        let profile_runtime = ctx.profile_runtime.clone();
        let skill_registry = ctx.skill_registry.clone();
        let memory_registry = ctx.memory_registry.clone();
        let tool_definitions = tool_definitions(ctx);
        let session_id_for_query = session_id.clone();
        ctx.run_blocking("context.get_snapshot", move || {
            retry_context_read("context.get_snapshot", || {
                let mut prepared = build_context_manager_for_session(
                    &session_id_for_query,
                    session_manager.as_ref(),
                    event_store.as_ref(),
                    context_artifacts.as_ref(),
                    profile_runtime.as_ref(),
                    tool_definitions.clone(),
                )?;
                // Skill index + memory content: skip for local models (stripped at turn time)
                if !prepared.context_manager.is_local_model() {
                    let skill_index_content = {
                        let mut registry = skill_registry.write();
                        let _ = registry.refresh_if_stale(&prepared.session.working_directory);
                        let skills = registry.list(None);
                        let index = crate::skills::injector::build_skill_index(&skills);
                        if index.is_empty() { None } else { Some(index) }
                    };
                    prepared
                        .context_manager
                        .set_skill_index_content(skill_index_content);

                    let memory_content = {
                        let mut reg = memory_registry.lock();
                        Some(reg.content(&crate::core::paths::home_dir()).to_string())
                    };
                    prepared.context_manager.set_memory_content(memory_content);
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
        ctx: &ServerCapabilityContext,
        session_id: String,
    ) -> Result<Value, RpcError> {
        let session_manager = ctx.session_manager.clone();
        let event_store = ctx.event_store.clone();
        let context_artifacts = ctx.context_artifacts.clone();
        let profile_runtime = ctx.profile_runtime.clone();
        let skill_registry = ctx.skill_registry.clone();
        let memory_registry = ctx.memory_registry.clone();
        let tool_definitions = tool_definitions(ctx);
        let session_id_for_query = session_id.clone();
        ctx.run_blocking("context.get_detailed_snapshot", move || {
            retry_context_read("context.get_detailed_snapshot", || {
                let prepared = build_context_manager_for_session(
                    &session_id_for_query,
                    session_manager.as_ref(),
                    event_store.as_ref(),
                    context_artifacts.as_ref(),
                    profile_runtime.as_ref(),
                    tool_definitions.clone(),
                )?;
                build_detailed_snapshot_response(
                    event_store.as_ref(),
                    &session_id_for_query,
                    prepared,
                    &skill_registry,
                    &memory_registry,
                )
            })
        })
        .await
    }

    pub(crate) async fn get_audit_trace(
        ctx: &ServerCapabilityContext,
        session_id: String,
        turn: Option<u32>,
    ) -> Result<Value, RpcError> {
        let event_store = ctx.event_store.clone();
        let session_id_for_query = session_id.clone();
        ctx.run_blocking("context.get_audit_trace", move || {
            let conn = event_store
                .pool()
                .get()
                .map_err(|error| RpcError::Internal {
                    message: format!("database connection error: {error}"),
                })?;
            let trace = load_audit_trace(&conn, &session_id_for_query, turn)?;
            trace.ok_or_else(|| RpcError::NotFound {
                code: "CONTEXT_AUDIT_NOT_FOUND".into(),
                message: format!(
                    "No context audit trace found for session `{}`{}",
                    session_id_for_query,
                    turn.map_or_else(String::new, |turn| format!(" turn {turn}"))
                ),
            })
        })
        .await
    }

    pub(crate) async fn should_compact(
        ctx: &ServerCapabilityContext,
        session_id: String,
    ) -> Result<Value, RpcError> {
        let session_manager = ctx.session_manager.clone();
        let event_store = ctx.event_store.clone();
        let context_artifacts = ctx.context_artifacts.clone();
        let profile_runtime = ctx.profile_runtime.clone();
        let tool_definitions = tool_definitions(ctx);
        let session_id_for_query = session_id.clone();
        ctx.run_blocking("context.should_compact", move || {
            retry_context_read("context.should_compact", || {
                let prepared = build_context_manager_for_session(
                    &session_id_for_query,
                    session_manager.as_ref(),
                    event_store.as_ref(),
                    context_artifacts.as_ref(),
                    profile_runtime.as_ref(),
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
        ctx: &ServerCapabilityContext,
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
        ctx: &ServerCapabilityContext,
        session_id: String,
    ) -> Result<Value, RpcError> {
        let session_manager = ctx.session_manager.clone();
        let event_store = ctx.event_store.clone();
        let context_artifacts = ctx.context_artifacts.clone();
        let profile_runtime = ctx.profile_runtime.clone();
        let tool_definitions = tool_definitions(ctx);
        let session_id_for_query = session_id.clone();
        ctx.run_blocking("context.can_accept_turn", move || {
            retry_context_read("context.can_accept_turn", || {
                let prepared = build_context_manager_for_session(
                    &session_id_for_query,
                    session_manager.as_ref(),
                    event_store.as_ref(),
                    context_artifacts.as_ref(),
                    profile_runtime.as_ref(),
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
    ctx: &ServerCapabilityContext,
    task_name: &'static str,
    session_id: &str,
) -> Result<PreparedSessionContext, RpcError> {
    let session_manager = ctx.session_manager.clone();
    let event_store = ctx.event_store.clone();
    let context_artifacts = ctx.context_artifacts.clone();
    let profile_runtime = ctx.profile_runtime.clone();
    let tool_definitions = tool_definitions(ctx);
    let session_id = session_id.to_owned();
    ctx.run_blocking(task_name, move || {
        retry_context_read(task_name, || {
            build_context_manager_for_session(
                &session_id,
                session_manager.as_ref(),
                event_store.as_ref(),
                context_artifacts.as_ref(),
                profile_runtime.as_ref(),
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
    memory_registry: &Arc<parking_lot::Mutex<crate::runtime::memory::MemoryRegistry>>,
) -> Result<Value, RpcError> {
    let PreparedSessionContext {
        session,
        artifacts,
        mut context_manager,
    } = prepared;

    // Skill index + memory content: skip for local models (stripped at turn time)
    let memory_wire_json = if !context_manager.is_local_model() {
        let skill_index_content = {
            let mut registry = skill_registry.write();
            let _ = registry.refresh_if_stale(&session.working_directory);
            let skills = registry.list(None);
            let index = crate::skills::injector::build_skill_index(&skills);
            if index.is_empty() { None } else { Some(index) }
        };
        context_manager.set_skill_index_content(skill_index_content);

        // Load memory + build the iOS wire JSON. Uses a single lock acquisition
        // so the cache refresh happens once per call path.
        let mut reg = memory_registry.lock();
        let home = crate::core::paths::home_dir();
        let content = reg.content(&home).to_string();
        let rule_files = reg.list_rule_files(&home);
        let bootstrapped = reg.memory_md_exists(&home);
        context_manager.set_memory_content(Some(content.clone()));
        let rule_files_json: Vec<Value> = rule_files
            .iter()
            .map(|f| {
                let mut obj = json!({ "name": f.name });
                if let Some(desc) = &f.description {
                    obj["description"] = json!(desc);
                }
                obj
            })
            .collect();
        json!({
            "content": content,
            "ruleFiles": rule_files_json,
            "bootstrapped": bootstrapped,
        })
    } else {
        Value::Null
    };

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
        "memory": memory_wire_json,
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
        .filter_map(|e| match serde_json::from_str::<Value>(&e.payload) {
            Ok(payload) => Some(json!({
                "type": e.event_type,
                "id": e.id,
                "payload": payload,
            })),
            Err(err) => {
                tracing::warn!(
                    event_id = %e.id,
                    event_type = %e.event_type,
                    error = %err,
                    "context_queries: corrupt event payload JSON; dropping from skill tracker"
                );
                None
            }
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

struct AuditResolution {
    id: String,
    occurred_at: String,
    turn: Option<i64>,
    profile: Option<String>,
    provider: Option<String>,
    model: Option<String>,
    effective_hash: Option<String>,
    payload_blob_id: Option<String>,
    metadata: Value,
}

fn load_audit_trace(
    conn: &rusqlite::Connection,
    session_id: &str,
    turn: Option<u32>,
) -> Result<Option<Value>, RpcError> {
    let context = load_context_resolution(conn, session_id, turn)?;
    let Some(context) = context else {
        return Ok(None);
    };
    let blocks = load_context_blocks(conn, &context.id)?;
    let provider_payload = load_provider_payload_resolution(conn, session_id, &context, turn)?;

    Ok(Some(json!({
        "sessionId": session_id,
        "turn": context.turn,
        "contextResolution": resolution_json(&context),
        "contextBlocks": blocks,
        "cachePolicy": blocks.iter().map(|block| json!({
            "blockId": block.get("blockId").cloned().unwrap_or(Value::Null),
            "cacheClass": block.get("cacheClass").cloned().unwrap_or(Value::Null),
            "providerSurface": block.get("providerSurface").cloned().unwrap_or(Value::Null),
        })).collect::<Vec<_>>(),
        "providerPayload": provider_payload,
    })))
}

fn load_context_resolution(
    conn: &rusqlite::Connection,
    session_id: &str,
    turn: Option<u32>,
) -> Result<Option<AuditResolution>, RpcError> {
    let sql = if turn.is_some() {
        "SELECT id, occurred_at, turn, profile, provider, model, effective_hash, payload_blob_id, metadata_json
         FROM constitution_resolution_audit
         WHERE session_id = ?1 AND resolution_type = 'context' AND turn = ?2
         ORDER BY occurred_at DESC
         LIMIT 1"
    } else {
        "SELECT id, occurred_at, turn, profile, provider, model, effective_hash, payload_blob_id, metadata_json
         FROM constitution_resolution_audit
         WHERE session_id = ?1 AND resolution_type = 'context'
         ORDER BY turn DESC, occurred_at DESC
         LIMIT 1"
    };

    let turn_value = turn.map(i64::from);
    let mut stmt = conn.prepare(sql).map_err(sql_error)?;
    let row = if let Some(turn_value) = turn_value {
        stmt.query_row(params![session_id, turn_value], map_resolution_row)
            .optional()
            .map_err(sql_error)?
    } else {
        stmt.query_row(params![session_id], map_resolution_row)
            .optional()
            .map_err(sql_error)?
    };
    Ok(row)
}

fn load_provider_payload_resolution(
    conn: &rusqlite::Connection,
    session_id: &str,
    context: &AuditResolution,
    turn: Option<u32>,
) -> Result<Value, RpcError> {
    let by_context: Option<AuditResolution> = conn
        .query_row(
            "SELECT id, occurred_at, turn, profile, provider, model, effective_hash, payload_blob_id, metadata_json
             FROM constitution_resolution_audit
             WHERE session_id = ?1
               AND resolution_type = 'provider_payload'
               AND json_extract(metadata_json, '$.contextResolutionId') = ?2
             ORDER BY occurred_at DESC
             LIMIT 1",
            params![session_id, context.id.as_str()],
            map_resolution_row,
        )
        .optional()
        .map_err(sql_error)?;

    let provider = match by_context {
        Some(row) => Some(row),
        None => {
            let target_turn = turn.map(i64::from).or(context.turn).unwrap_or_default();
            conn.query_row(
                "SELECT id, occurred_at, turn, profile, provider, model, effective_hash, payload_blob_id, metadata_json
                 FROM constitution_resolution_audit
                 WHERE session_id = ?1 AND resolution_type = 'provider_payload' AND turn = ?2
                 ORDER BY occurred_at DESC
                 LIMIT 1",
                params![session_id, target_turn],
                map_resolution_row,
            )
            .optional()
            .map_err(sql_error)?
        }
    };

    let Some(provider) = provider else {
        return Ok(Value::Null);
    };

    let preview = provider
        .payload_blob_id
        .as_deref()
        .and_then(|blob_id| load_payload_preview(conn, blob_id).transpose())
        .transpose()?
        .unwrap_or(Value::Null);

    Ok(json!({
        "resolution": resolution_json(&provider),
        "redactedPreview": preview,
    }))
}

fn load_context_blocks(
    conn: &rusqlite::Connection,
    resolution_id: &str,
) -> Result<Vec<Value>, RpcError> {
    let mut stmt = conn
        .prepare(
            "SELECT block_id, name, source_home, source_path, source_blob_id, content_hash,
                    token_estimate, sensitivity, inclusion_reason, precedence, cache_class,
                    provider_surface, lifecycle, included, metadata_json
             FROM constitution_context_blocks
             WHERE resolution_id = ?1
             ORDER BY precedence ASC",
        )
        .map_err(sql_error)?;

    let rows = stmt
        .query_map(params![resolution_id], |row| {
            let metadata_json: String = row.get(14)?;
            let metadata = parse_json_value(&metadata_json);
            Ok(json!({
                "blockId": row.get::<_, String>(0)?,
                "name": row.get::<_, String>(1)?,
                "sourceHome": row.get::<_, String>(2)?,
                "sourcePath": row.get::<_, Option<String>>(3)?,
                "sourceBlobId": row.get::<_, Option<String>>(4)?,
                "contentHash": row.get::<_, String>(5)?,
                "tokenEstimate": row.get::<_, i64>(6)?,
                "sensitivity": row.get::<_, String>(7)?,
                "inclusionReason": row.get::<_, String>(8)?,
                "precedence": row.get::<_, i64>(9)?,
                "cacheClass": row.get::<_, String>(10)?,
                "providerSurface": row.get::<_, String>(11)?,
                "lifecycle": row.get::<_, String>(12)?,
                "included": row.get::<_, i64>(13)? == 1,
                "metadata": metadata,
            }))
        })
        .map_err(sql_error)?;

    rows.collect::<Result<Vec<_>, _>>().map_err(sql_error)
}

fn map_resolution_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<AuditResolution> {
    let metadata_json: String = row.get(8)?;
    Ok(AuditResolution {
        id: row.get(0)?,
        occurred_at: row.get(1)?,
        turn: row.get(2)?,
        profile: row.get(3)?,
        provider: row.get(4)?,
        model: row.get(5)?,
        effective_hash: row.get(6)?,
        payload_blob_id: row.get(7)?,
        metadata: parse_json_value(&metadata_json),
    })
}

fn resolution_json(row: &AuditResolution) -> Value {
    json!({
        "id": row.id,
        "occurredAt": row.occurred_at,
        "turn": row.turn,
        "profile": row.profile,
        "provider": row.provider,
        "model": row.model,
        "effectiveHash": row.effective_hash,
        "payloadBlobId": row.payload_blob_id,
        "metadata": row.metadata,
    })
}

fn load_payload_preview(
    conn: &rusqlite::Connection,
    blob_id: &str,
) -> Result<Option<Value>, RpcError> {
    let content = crate::events::sqlite::repositories::blob::BlobRepo::get_content(conn, blob_id)
        .map_err(|error| RpcError::Internal {
        message: format!("audit payload blob lookup error: {error}"),
    })?;
    let Some(content) = content else {
        return Ok(None);
    };
    let mut value = serde_json::from_slice::<Value>(&content).unwrap_or_else(|_| {
        json!({
            "unparsedText": String::from_utf8_lossy(&content),
        })
    });
    redact_json_for_audit(&mut value);
    Ok(Some(value))
}

fn redact_json_for_audit(value: &mut Value) {
    match value {
        Value::Object(map) => {
            for (key, child) in map {
                if is_sensitive_key(key) {
                    *child = Value::String("[REDACTED]".into());
                } else {
                    redact_json_for_audit(child);
                }
            }
        }
        Value::Array(items) => {
            for item in items {
                redact_json_for_audit(item);
            }
        }
        Value::String(text) if text.len() > 500 => {
            text.truncate(500);
            text.push_str("...[truncated]");
        }
        _ => {}
    }
}

fn is_sensitive_key(key: &str) -> bool {
    let key = key.to_ascii_lowercase();
    [
        "token",
        "secret",
        "api_key",
        "apikey",
        "authorization",
        "bearer",
        "password",
        "credential",
    ]
    .iter()
    .any(|needle| key.contains(needle))
}

fn parse_json_value(content: &str) -> Value {
    serde_json::from_str(content).unwrap_or_else(|_| json!({ "unparsed": content }))
}

fn sql_error(error: rusqlite::Error) -> RpcError {
    RpcError::Internal {
        message: format!("context audit query failed: {error}"),
    }
}

fn build_rules_info(
    event_store: &crate::events::EventStore,
    session_id: &str,
    session: &crate::events::sqlite::row_types::SessionRow,
    artifacts: &crate::server::services::session_context::SessionContextArtifacts,
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
                format!("~/.tron/memory/rules/{filename}")
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
