use super::*;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let payload = &invocation.payload;
    match method {
        "skill.list" => Ok(skill_list_value(Some(payload), deps)),
        "skill.get" => skill_get_value(Some(payload), deps),
        "skill.refresh" => skill_refresh_value(Some(payload), deps).await,
        "skill.activate" => skill_activate_value(Some(payload), deps),
        "skill.deactivate" => skill_deactivate_value(Some(payload), deps),
        "skill.active" => skill_active_value(Some(payload), deps),
        _ => Err(RpcError::Internal {
            message: format!("skills method {method} is not engine-owned"),
        }),
    }
}

fn skill_list_value(params: Option<&Value>, deps: &RpcEngineDeps) -> Value {
    let working_dir = resolve_skill_working_dir(params, deps);
    let mut registry = deps.skill_registry.write();
    let _ = registry.refresh_if_stale(&working_dir);
    let skills = registry.list(None);
    json!({ "skills": skills })
}

fn skill_get_value(params: Option<&Value>, deps: &RpcEngineDeps) -> Result<Value, RpcError> {
    let name = require_string_param(params, "name")?;
    let working_dir = resolve_skill_working_dir(params, deps);

    let mut registry = deps.skill_registry.write();
    let _ = registry.refresh_if_stale(&working_dir);

    let skill = registry.get(&name).ok_or_else(|| RpcError::NotFound {
        code: errors::NOT_FOUND.into(),
        message: format!("Skill '{name}' not found"),
    })?;

    Ok(json!({
        "skill": skill_to_wire(skill),
        "found": true,
    }))
}

async fn skill_refresh_value(
    params: Option<&Value>,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let working_dir = resolve_skill_working_dir(params, deps);
    let skill_registry = Arc::clone(&deps.skill_registry);
    let count = run_blocking_task("skill.refresh", move || {
        let mut registry = skill_registry.write();
        registry.refresh(&working_dir);
        Ok(registry.list(None).len())
    })
    .await?;
    Ok(json!({ "success": true, "skillCount": count }))
}

fn skill_activate_value(params: Option<&Value>, deps: &RpcEngineDeps) -> Result<Value, RpcError> {
    let session_id = require_string_param(params, "sessionId")?;
    let skill_name = require_string_param(params, "skillName")?;

    deps.session_manager
        .get_session(&session_id)
        .map_err(|error| RpcError::Internal {
            message: error.to_string(),
        })?
        .ok_or_else(|| RpcError::NotFound {
            code: errors::NOT_FOUND.into(),
            message: format!("Session '{session_id}' not found"),
        })?;

    let (source, service, tokens) = {
        let registry = deps.skill_registry.read();
        let skill = registry
            .get(&skill_name)
            .ok_or_else(|| RpcError::NotFound {
                code: errors::NOT_FOUND.into(),
                message: format!("Skill '{skill_name}' not found"),
            })?;
        (
            skill.source.to_string(),
            skill.service.clone(),
            skill.content.len() as u64 / 4,
        )
    };

    let already_active = crate::server::rpc::skill_state::reconstruct_tracker(
        &deps.event_store,
        &session_id,
        &crate::settings::types::CompactionPolicy::ClearAll,
    )
    .has_skill(&skill_name);

    if already_active {
        return Ok(json!({
            "success": true,
            "alreadyActive": true,
            "skill": {
                "name": skill_name,
                "source": source,
                "service": service,
                "tokens": tokens,
            }
        }));
    }

    let _ = deps.event_store.append(&crate::events::AppendOptions {
        session_id: &session_id,
        event_type: crate::events::EventType::SkillActivated,
        payload: json!({
            "skillName": skill_name,
            "source": source,
        }),
        parent_id: None,
        sequence: None,
    });
    deps.session_manager.invalidate_session(&session_id);

    Ok(json!({
        "success": true,
        "skill": {
            "name": skill_name,
            "source": source,
            "service": service,
            "tokens": tokens,
        }
    }))
}

fn skill_deactivate_value(params: Option<&Value>, deps: &RpcEngineDeps) -> Result<Value, RpcError> {
    let session_id = require_string_param(params, "sessionId")?;
    let skill_name = require_string_param(params, "skillName")?;

    deps.session_manager
        .get_session(&session_id)
        .map_err(|error| RpcError::Internal {
            message: error.to_string(),
        })?
        .ok_or_else(|| RpcError::NotFound {
            code: errors::NOT_FOUND.into(),
            message: format!("Session '{session_id}' not found"),
        })?;

    let is_active = crate::server::rpc::skill_state::reconstruct_tracker(
        &deps.event_store,
        &session_id,
        &crate::settings::types::CompactionPolicy::ClearAll,
    )
    .has_skill(&skill_name);

    if !is_active {
        return Ok(json!({
            "success": true,
            "wasActive": false,
            "deactivatedSkill": skill_name,
        }));
    }

    let _ = deps.event_store.append(&crate::events::AppendOptions {
        session_id: &session_id,
        event_type: crate::events::EventType::SkillDeactivated,
        payload: json!({ "skillName": skill_name }),
        parent_id: None,
        sequence: None,
    });
    deps.session_manager.invalidate_session(&session_id);

    Ok(json!({
        "success": true,
        "wasActive": true,
        "deactivatedSkill": skill_name,
    }))
}

fn skill_active_value(params: Option<&Value>, deps: &RpcEngineDeps) -> Result<Value, RpcError> {
    let session_id = require_string_param(params, "sessionId")?;
    deps.session_manager
        .get_session(&session_id)
        .map_err(|error| RpcError::Internal {
            message: error.to_string(),
        })?
        .ok_or_else(|| RpcError::NotFound {
            code: errors::NOT_FOUND.into(),
            message: format!("Session '{session_id}' not found"),
        })?;

    let tracker = crate::server::rpc::skill_state::reconstruct_tracker(
        &deps.event_store,
        &session_id,
        &crate::settings::types::CompactionPolicy::ClearAll,
    );
    let registry = deps.skill_registry.read();
    let skills: Vec<Value> = tracker
        .added_skills()
        .iter()
        .map(|skill| {
            let added_via = match skill.added_via {
                crate::skills::types::SkillAddMethod::Mention => "mention",
                crate::skills::types::SkillAddMethod::Explicit => "explicit",
            };
            let service = registry
                .get(&skill.name)
                .map(|metadata| metadata.service.clone())
                .unwrap_or_else(|| "unknown".to_owned());
            json!({
                "name": skill.name,
                "source": skill.source.to_string(),
                "service": service,
                "addedVia": added_via,
                "tokens": skill.tokens,
            })
        })
        .collect();

    Ok(json!({ "skills": skills }))
}

fn skill_to_wire(skill: &crate::skills::types::SkillMetadata) -> Value {
    let mut value = json!({
        "name": skill.name,
        "displayName": skill.display_name,
        "description": skill.description,
        "source": skill.source,
        "service": skill.service,
        "tags": skill.frontmatter.tags,
        "content": skill.content,
        "path": skill.path,
        "additionalFiles": skill.additional_files,
    });
    if !skill.scope_dir.is_empty() {
        value["scopeDir"] = json!(skill.scope_dir);
    }
    value
}

fn resolve_skill_working_dir(params: Option<&Value>, deps: &RpcEngineDeps) -> String {
    if let Some(wd) = params
        .and_then(|value| value.get("workingDirectory"))
        .and_then(Value::as_str)
    {
        return wd.to_owned();
    }
    if let Some(session_id) = params
        .and_then(|value| value.get("sessionId"))
        .and_then(Value::as_str)
    {
        if let Ok(Some(session)) = deps.session_manager.get_session(session_id) {
            return session.working_directory;
        }
    }
    "/tmp".to_owned()
}
