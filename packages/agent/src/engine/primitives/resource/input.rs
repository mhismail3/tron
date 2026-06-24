use super::*;

pub(super) fn resource_scope_from_payload(
    invocation: &Invocation,
    allow_absent: bool,
) -> Result<EngineResourceScope> {
    let explicit = optional_string(invocation.payload.get("scope"))?;
    match explicit.as_deref() {
        Some("system") => Ok(EngineResourceScope::System),
        Some("workspace") => {
            let workspace_id = optional_string(invocation.payload.get("workspaceId"))?
                .or(invocation.causal_context.workspace_id.clone())
                .ok_or_else(|| {
                    EngineError::PolicyViolation(
                        "workspace-scoped resource requires workspaceId".to_owned(),
                    )
                })?;
            Ok(EngineResourceScope::Workspace(non_empty_scope_id(
                "workspaceId",
                workspace_id,
            )?))
        }
        Some("session") => {
            let session_id = optional_string(invocation.payload.get("sessionId"))?
                .or(invocation.causal_context.session_id.clone())
                .ok_or_else(|| {
                    EngineError::PolicyViolation(
                        "session-scoped resource requires sessionId".to_owned(),
                    )
                })?;
            Ok(EngineResourceScope::Session(non_empty_scope_id(
                "sessionId",
                session_id,
            )?))
        }
        Some(other) => Err(EngineError::PolicyViolation(format!(
            "unsupported resource scope {other}"
        ))),
        None if allow_absent => Err(EngineError::PolicyViolation(
            "resource scope filter absent".to_owned(),
        )),
        None => {
            if let Some(workspace_id) = &invocation.causal_context.workspace_id {
                Ok(EngineResourceScope::Workspace(non_empty_scope_id(
                    "workspaceId",
                    workspace_id.clone(),
                )?))
            } else if let Some(session_id) = &invocation.causal_context.session_id {
                Ok(EngineResourceScope::Session(non_empty_scope_id(
                    "sessionId",
                    session_id.clone(),
                )?))
            } else {
                Ok(EngineResourceScope::System)
            }
        }
    }
}

pub(super) fn non_empty_scope_id(field: &str, value: String) -> Result<String> {
    if value.trim().is_empty() {
        return Err(EngineError::PolicyViolation(format!(
            "{field} must not be empty"
        )));
    }
    Ok(value)
}

pub(super) fn versioning_mode(payload: &Value) -> Result<EngineResourceVersioningMode> {
    match optional_string(payload.get("versioningMode"))?
        .unwrap_or_else(|| "append_only".to_owned())
        .as_str()
    {
        "append_only" => Ok(EngineResourceVersioningMode::AppendOnly),
        "current_pointer" => Ok(EngineResourceVersioningMode::CurrentPointer),
        other => Err(EngineError::PolicyViolation(format!(
            "unsupported resource versioning mode {other}"
        ))),
    }
}

pub(super) fn locations(payload: &Value) -> Result<Vec<EngineResourceLocation>> {
    payload
        .get("locations")
        .cloned()
        .map(serde_json::from_value)
        .transpose()
        .map_err(|error| {
            EngineError::PolicyViolation(format!("invalid resource locations: {error}"))
        })
        .map(Option::unwrap_or_default)
}

pub(super) fn string_array(payload: &Value, field: &str) -> Result<Vec<String>> {
    optional_string_array(payload, field)?.ok_or_else(|| {
        EngineError::PolicyViolation(format!("required field {field} must be a string array"))
    })
}

pub(super) fn optional_string_array(payload: &Value, field: &str) -> Result<Option<Vec<String>>> {
    let Some(value) = payload.get(field) else {
        return Ok(None);
    };
    let Some(items) = value.as_array() else {
        return Err(EngineError::PolicyViolation(format!(
            "field {field} must be an array"
        )));
    };
    items
        .iter()
        .map(|item| {
            item.as_str().map(str::to_owned).ok_or_else(|| {
                EngineError::PolicyViolation(format!("field {field} must be a string array"))
            })
        })
        .collect::<Result<Vec<_>>>()
        .map(Some)
}

pub(super) fn optional_worker_id(payload: &Value, field: &str) -> Result<Option<WorkerId>> {
    optional_string(payload.get(field))?
        .map(WorkerId::new)
        .transpose()
}
