use super::prepare::set_volatile_tokens_from_session;
use super::{
    Path, PreparedSessionContext, RuleFileLevel, RwLock, SkillAddMethod, SkillSource, SkillTracker,
    build_active_skill_context, collect_dynamic_rule_paths,
};
use crate::domains::skills::registry::SkillRegistry;
use crate::shared::server::errors::CapabilityError;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;

pub(super) fn snapshot_response(
    snapshot: &crate::domains::agent::runner::context::types::ContextSnapshot,
) -> Value {
    json!({
        "currentTokens": snapshot.current_tokens,
        "contextLimit": snapshot.context_limit,
        "usagePercent": snapshot.usage_percent,
        "thresholdLevel": snapshot.threshold_level,
        "isLocalModel": snapshot.is_local_model,
        "breakdown": {
            "systemPrompt": snapshot.breakdown.system_prompt,
            "capabilities": snapshot.breakdown.capabilities,
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

pub(super) fn build_detailed_snapshot_response(
    event_store: &crate::domains::session::event_store::EventStore,
    session_id: &str,
    prepared: PreparedSessionContext,
    skill_registry: &Arc<RwLock<SkillRegistry>>,
    memory_registry: &Arc<
        parking_lot::Mutex<crate::domains::agent::runner::memory::MemoryRegistry>,
    >,
) -> Result<Value, CapabilityError> {
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
            let index = crate::domains::skills::injector::build_skill_index(&skills);
            if index.is_empty() { None } else { Some(index) }
        };
        context_manager.set_skill_index_content(skill_index_content);

        // Load memory + build the iOS wire JSON. Uses a single lock acquisition
        // so the cache refresh happens once per call path.
        let mut reg = memory_registry.lock();
        let home = crate::shared::paths::home_dir();
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
            "capabilities": detailed.snapshot.breakdown.capabilities,
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
        "capabilityClarificationContent": detailed.capability_clarification_content,
        "capabilitiesContent": detailed.capabilities_content,
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
    messages: &[crate::domains::agent::runner::context::types::DetailedMessageInfo],
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
            if let Some(capability_invocations) = message.capability_invocations.as_ref() {
                value["capabilityInvocations"] = json!(
                    capability_invocations
                        .iter()
                        .map(|capability_invocation| json!({
                            "id": capability_invocation.id,
                            "name": capability_invocation.name,
                            "tokens": capability_invocation.tokens,
                            "arguments": capability_invocation.arguments,
                        }))
                        .collect::<Vec<_>>()
                );
            }
            if let Some(invocation_id) = message.invocation_id.as_ref() {
                value["invocationId"] = json!(invocation_id);
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

pub(super) fn build_added_skills(
    event_store: &crate::domains::session::event_store::EventStore,
    session_id: &str,
    skill_registry: &Arc<RwLock<SkillRegistry>>,
) -> Result<Vec<Value>, CapabilityError> {
    let policy = {
        let settings = crate::domains::settings::get_settings();
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
        .map_err(|error| CapabilityError::Internal {
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
    context_manager: &crate::domains::agent::runner::context::context_manager::ContextManager,
    session: &crate::domains::session::event_store::sqlite::row_types::SessionRow,
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

    crate::domains::model::providers::compose_context_parts(&composed_context).join("\n\n")
}

fn build_rules_info(
    event_store: &crate::domains::session::event_store::EventStore,
    session_id: &str,
    session: &crate::domains::session::event_store::sqlite::row_types::SessionRow,
    artifacts: &crate::domains::session::context::SessionContextArtifacts,
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
    memories: &[crate::domains::agent::runner::context::types::SessionMemoryEntry],
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
