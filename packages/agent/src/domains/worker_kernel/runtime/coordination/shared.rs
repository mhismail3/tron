//! Closed parsing, validation, topology, relationship, and limit helpers.

use super::*;

/// Public reusable roles are an executable directory, not a diagnostic list.
/// Unhealthy declarations remain visible to authenticated worker inspection
/// and role review, but advertising one here would hand the model a role which
/// `agent_spawn` must reject.
pub(in crate::domains::worker_kernel::runtime) fn is_discoverable_agent_role(
    summary: &crate::domains::worker_kernel::types::WorkerSummary,
) -> bool {
    summary.enabled && !summary.retired && summary.health == "healthy"
}

/// One named reusable role is executable only when both its profile-owned
/// worker lifecycle and its immutable declaration admit model collaboration.
/// Every discovery, spawn, upgrade, and client-action path uses this predicate
/// so an unhealthy or retired active pointer cannot be advertised by one path
/// and rejected by another.
pub(in crate::domains::worker_kernel::runtime) fn is_executable_agent_role(
    summary: &crate::domains::worker_kernel::types::WorkerSummary,
    role: Option<&WorkerAgentRole>,
) -> bool {
    is_discoverable_agent_role(summary)
        && summary.runner_kind == "agent"
        && matches!(
            role,
            Some(WorkerAgentRole::Enabled {
                discoverable: true,
                ..
            })
        )
}

#[cfg(test)]
mod role_discovery_tests {
    use super::{is_discoverable_agent_role, is_executable_agent_role};
    use crate::domains::worker_kernel::types::{WorkerAgentRole, WorkerSummary};

    fn summary(health: &str) -> WorkerSummary {
        WorkerSummary {
            worker_id: "reviewer".to_owned(),
            name: "Reviewer".to_owned(),
            description: "Reviews work".to_owned(),
            tool_name: "worker_reviewer".to_owned(),
            runner_kind: "agent".to_owned(),
            active_version:
                "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".to_owned(),
            enabled: true,
            retired: false,
            health: health.to_owned(),
            trigger_count: 0,
            updated_at: "2026-08-11T00:00:00Z".to_owned(),
            presentation: None,
        }
    }

    #[test]
    fn role_directory_advertises_only_healthy_executable_workers() {
        assert!(is_discoverable_agent_role(&summary("healthy")));
        assert!(!is_discoverable_agent_role(&summary("failed")));
        assert!(!is_discoverable_agent_role(&summary("degraded")));

        let mut disabled = summary("healthy");
        disabled.enabled = false;
        assert!(!is_discoverable_agent_role(&disabled));

        let mut retired = summary("healthy");
        retired.retired = true;
        assert!(!is_discoverable_agent_role(&retired));
    }

    #[test]
    fn executable_role_requires_both_healthy_lifecycle_and_public_declaration() {
        let enabled = WorkerAgentRole::Enabled {
            display_name: "Reviewer".to_owned(),
            summary: "Reviews work".to_owned(),
            discoverable: true,
            collaboration_instructions: "Review the assigned work.".to_owned(),
            default_model: None,
            default_reasoning_level: None,
            tool_ceiling: Vec::new(),
            limits: Default::default(),
            result_mode: Default::default(),
        };
        let mut executable_summary = summary("healthy");
        assert!(is_executable_agent_role(
            &executable_summary,
            Some(&enabled)
        ));

        executable_summary.retired = true;
        assert!(!is_executable_agent_role(
            &executable_summary,
            Some(&enabled)
        ));
        executable_summary.retired = false;
        executable_summary.health = "failed".to_owned();
        assert!(!is_executable_agent_role(
            &executable_summary,
            Some(&enabled)
        ));
        executable_summary.health = "healthy".to_owned();
        assert!(!is_executable_agent_role(
            &executable_summary,
            Some(&WorkerAgentRole::Disabled)
        ));
    }
}

pub(in crate::domains::worker_kernel::runtime) fn decode_directory_cursor(
    cursor: Option<&str>,
) -> Result<usize, String> {
    let Some(cursor) = cursor else {
        return Ok(0);
    };
    cursor
        .strip_prefix("offset:")
        .and_then(|offset| offset.parse::<usize>().ok())
        .ok_or_else(|| "agent discovery cursor is invalid or stale".to_owned())
}

pub(in crate::domains::worker_kernel::runtime) fn validate_agent_model_reasoning(
    model: Option<&str>,
    reasoning_level: Option<&str>,
    auth_path: &std::path::Path,
) -> Result<(), String> {
    if let Some(model) = model {
        if !crate::domains::model::routing::catalog::is_model_supported(model)
            || crate::domains::model::routing::catalog::is_model_retired(model)
        {
            return Err(format!("agent model '{model}' is unavailable"));
        }
        crate::domains::model::routing::catalog::validate_explicit_model(model, auth_path)
            .map_err(|error| format!("agent {error}"))?;
        if let Some(reasoning_level) = reasoning_level {
            crate::domains::model::routing::catalog::validate_explicit_reasoning_level(
                model,
                reasoning_level,
                auth_path,
            )
            .map_err(|error| format!("agent {error}"))?;
        }
    } else if reasoning_level.is_some_and(|level| {
        crate::domains::agent::r#loop::types::ReasoningLevel::from_str_canonical(level).is_none()
    }) {
        // A role may intentionally inherit its eventual model, so activation
        // cannot validate a provider-specific pair yet. It can still reject
        // a spelling no provider-neutral reasoning contract understands.
        return Err("agent reasoningLevel is invalid".to_owned());
    }
    Ok(())
}

pub(in crate::domains::worker_kernel::runtime) fn string_array(value: &Value) -> Vec<String> {
    value
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(ToOwned::to_owned)
        .collect()
}

pub(in crate::domains::worker_kernel::runtime) fn parse_agent_message_kind(
    value: &str,
) -> Result<AgentMessageKind, String> {
    match value {
        "instruction" => Ok(AgentMessageKind::Instruction),
        "request" => Ok(AgentMessageKind::Request),
        "question" => Ok(AgentMessageKind::Question),
        "answer" => Ok(AgentMessageKind::Answer),
        "information" => Ok(AgentMessageKind::Information),
        "update" => Ok(AgentMessageKind::Update),
        other => Err(format!("unsupported agent message kind '{other}'")),
    }
}

pub(in crate::domains::worker_kernel::runtime) fn parse_management_capability(
    value: &str,
) -> Result<AgentManagementCapability, String> {
    match value {
        "assign" => Ok(AgentManagementCapability::Assign),
        "cancel" => Ok(AgentManagementCapability::Cancel),
        "configure" => Ok(AgentManagementCapability::Configure),
        "close" => Ok(AgentManagementCapability::Close),
        other => Err(format!("unsupported agent management capability '{other}'")),
    }
}

pub(in crate::domains::worker_kernel::runtime) fn scope_is_within(
    scope: &str,
    parent: &str,
) -> bool {
    parent == "."
        || scope == parent
        || scope
            .strip_prefix(parent)
            .is_some_and(|suffix| suffix.starts_with('/'))
}

pub(in crate::domains::worker_kernel::runtime) fn causal_parent_execution_id(
    invocation: &Invocation,
) -> Option<String> {
    invocation
        .causal_context
        .agent_execution_id()
        .map(ToOwned::to_owned)
        .or_else(|| {
            invocation
                .causal_context
                .origin_worker_invocation_id()
                .map(|id| format!("execution_{id}"))
        })
}

pub(in crate::domains::worker_kernel::runtime) fn coordination_agent_dependency_id(
    agent_id: &str,
) -> String {
    format!("coordination_agent:{agent_id}")
}

pub(in crate::domains::worker_kernel::runtime) fn coordination_execution_dependency_id(
    execution_id: &str,
) -> String {
    format!("coordination_execution:{execution_id}")
}

pub(in crate::domains::worker_kernel::runtime) fn append_execution_dependency_edges(
    ancestry: &[ExecutionNodeRecord],
    edges: &mut BTreeSet<CoordinationDependencyEdge>,
) -> Result<(), String> {
    for pair in ancestry.windows(2) {
        let [parent, child] = pair else {
            unreachable!("windows(2) always contains two execution nodes")
        };
        if child.parent_execution_id.as_deref() != Some(parent.execution_id.as_str())
            || child.causal_depth <= parent.causal_depth
        {
            return Err(format!(
                "mixed execution ancestry is inconsistent between '{}' and '{}'",
                parent.execution_id, child.execution_id
            ));
        }
        edges.insert(CoordinationDependencyEdge {
            source_dependency_id: coordination_execution_dependency_id(&parent.execution_id),
            target_dependency_id: coordination_execution_dependency_id(&child.execution_id),
            kind: CoordinationDependencyEdgeKind::Causal,
        });
    }
    for node in ancestry {
        // Ordinary command/service workers progress independently of the
        // caller which admitted them. An assignment id is present only when
        // this execution is itself scheduled through an agent transcript
        // (including the direct-agent worker bridge), so only those nodes
        // depend on an agent scheduler.
        if node.assignment_id.is_some() {
            let owner_agent_id = node.owner_agent_id.as_deref().ok_or_else(|| {
                format!(
                    "agent execution '{}' has no stable executor identity",
                    node.execution_id
                )
            })?;
            edges.insert(CoordinationDependencyEdge {
                source_dependency_id: coordination_execution_dependency_id(&node.execution_id),
                target_dependency_id: coordination_agent_dependency_id(owner_agent_id),
                kind: CoordinationDependencyEdgeKind::Executor,
            });
        }
    }
    Ok(())
}

pub(in crate::domains::worker_kernel::runtime) fn child_execution_depth(
    invocation: &Invocation,
) -> u32 {
    if causal_parent_execution_id(invocation).is_some() {
        invocation.causal_context.trigger_depth()
    } else {
        invocation.causal_context.trigger_depth().saturating_add(1)
    }
}

pub(in crate::domains::worker_kernel::runtime) fn agent_relationship(
    caller: &AgentInstanceRecord,
    target: &AgentInstanceRecord,
) -> &'static str {
    if caller.agent_id == target.agent_id {
        "self"
    } else if caller.management_owner_agent_id.as_deref() == Some(&target.agent_id) {
        "parent"
    } else if target.management_owner_agent_id.as_deref() == Some(&caller.agent_id) {
        "child"
    } else if caller.root_session_id == target.root_session_id {
        "team"
    } else {
        "peer"
    }
}

pub(in crate::domains::worker_kernel::runtime) fn required_coordination_string(
    payload: &Value,
    key: &str,
) -> Result<String, String> {
    optional_coordination_string(payload, key)?
        .ok_or_else(|| format!("agent coordination requires {key}"))
}

pub(in crate::domains::worker_kernel::runtime) fn optional_coordination_string(
    payload: &Value,
    key: &str,
) -> Result<Option<String>, String> {
    let Some(value) = payload.get(key) else {
        return Ok(None);
    };
    let value = value
        .as_str()
        .ok_or_else(|| format!("agent coordination {key} must be a string"))?
        .trim();
    if value.is_empty() {
        return Err(format!("agent coordination {key} must not be empty"));
    }
    Ok(Some(value.to_owned()))
}

pub(in crate::domains::worker_kernel::runtime) fn optional_string_array(
    payload: &Value,
    key: &str,
) -> Result<Option<Vec<String>>, String> {
    let Some(value) = payload.get(key) else {
        return Ok(None);
    };
    let values = value
        .as_array()
        .ok_or_else(|| format!("agent coordination {key} must be an array"))?;
    let mut unique = BTreeSet::new();
    for value in values {
        let value = value
            .as_str()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| format!("agent coordination {key} entries must be strings"))?;
        unique.insert(value.to_owned());
    }
    Ok(Some(unique.into_iter().collect()))
}

pub(in crate::domains::worker_kernel::runtime) fn canonical_write_scope(
    scope: &str,
) -> Result<String, String> {
    let path = Path::new(scope);
    if path.is_absolute() {
        return Err("agent write scopes must be workspace-relative".to_owned());
    }
    let mut parts = Vec::new();
    for component in path.components() {
        match component {
            Component::Normal(part) => parts.push(part.to_string_lossy().into_owned()),
            Component::CurDir => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                return Err("agent write scopes must not escape the workspace".to_owned());
            }
        }
    }
    if parts.is_empty() {
        Ok(".".to_owned())
    } else {
        Ok(parts.join("/"))
    }
}

pub(in crate::domains::worker_kernel::runtime) fn tighten_limits(
    profile: &Value,
    role: &Value,
    requested: &Value,
) -> Result<Value, String> {
    if !profile.is_object() || !role.is_object() || !requested.is_object() {
        return Err("agent limits must be objects".to_owned());
    }
    let tightened = |field: &str| {
        let profile_value = profile.get(field).and_then(Value::as_u64).unwrap_or(1);
        let role_value = role
            .get(field)
            .and_then(Value::as_u64)
            .unwrap_or(profile_value);
        let requested_value = requested
            .get(field)
            .and_then(Value::as_u64)
            .unwrap_or(role_value);
        profile_value.min(role_value).min(requested_value)
    };
    Ok(json!({
        "maxAssignmentSeconds":tightened("maxAssignmentSeconds"),
        "maxAssignmentTurns":tightened("maxAssignmentTurns"),
        "maxChildExecutions":tightened("maxChildExecutions"),
        "maxQueuedAssignments":tightened("maxQueuedAssignments"),
    }))
}
