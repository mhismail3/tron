use serde_json::{Value, json};

use crate::engine::{
    EngineGrant, EngineHostHandle, EngineResourceInspection, EngineResourceScope,
    EngineResourceVersion, Invocation, ListResources, SUBAGENT_TASK_KIND, SUBAGENT_TASK_SCHEMA_ID,
};
use crate::shared::server::errors::CapabilityError;

use super::projection::{inspected_task, task_summary};
use super::validation::*;
use super::{READ_SCOPE, SCHEMA_VERSION};

const RESOURCE_READ_SCOPE: &str = "resource.read";

pub(crate) async fn list_subagent_tasks_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let grant = inspect_read_grant(engine_host, invocation, "subagent_task_list").await?;
    require_read_kind_selector(&grant, "subagent_task_list")?;
    let limit = optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(LIST_LIMIT_DEFAULT)
        .clamp(1, LIST_LIMIT_MAX);
    let include_archived = optional_bool(payload, "includeArchived")?.unwrap_or(false);
    let state = optional_string(payload, "state")?;
    if let Some(state) = state.as_deref() {
        validate_state(state)?;
    }
    let lifecycle = match (include_archived, state) {
        (true, _) => None,
        (false, Some(state)) => Some(state),
        (false, None) => None,
    };
    let scope = resource_scope(invocation)?;
    let resources = engine_host
        .list_resources(ListResources {
            kind: Some(SUBAGENT_TASK_KIND.to_owned()),
            scope: Some(scope.clone()),
            lifecycle,
            limit: limit.saturating_add(1),
        })
        .await
        .map_err(engine_error)?;
    let truncated = resources.len() > limit;
    let mut tasks = Vec::new();
    for resource in resources.into_iter().take(limit) {
        let Some(inspection) = engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            continue;
        };
        ensure_subagent_task(&inspection, "subagent_task_list")?;
        ensure_scope(&inspection, &scope, "subagent_task_list")?;
        let (version, payload) = current_payload(&inspection, "subagent_task_list")?;
        if !include_archived && inspection.resource.lifecycle == "archived" {
            continue;
        }
        tasks.push(task_summary(&inspection.resource, version, payload));
    }
    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": "subagent_task_list",
        "scope": scope_ref(&scope),
        "tasks": tasks,
        "limits": {
            "requestedLimit": limit,
            "returned": tasks.len(),
            "truncated": truncated,
            "includeArchived": include_archived
        },
        "activation": activation_proof(),
        "network": network_proof()
    }))
}

pub(crate) async fn inspect_subagent_task_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let grant = inspect_read_grant(engine_host, invocation, "subagent_task_inspect").await?;
    require_read_kind_selector(&grant, "subagent_task_inspect")?;
    let resource_id = required_string(payload, "subagentTaskResourceId")?;
    if !resource_id.starts_with(&format!("{SUBAGENT_TASK_KIND}:")) {
        return Err(invalid(
            "subagentTaskResourceId has unsupported resource kind",
        ));
    }
    let scope = resource_scope(invocation)?;
    let inspection = engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing subagent task resource {resource_id}")))?;
    ensure_subagent_task(&inspection, "subagent_task_inspect")?;
    ensure_scope(&inspection, &scope, "subagent_task_inspect")?;
    let (version, payload) = current_payload(&inspection, "subagent_task_inspect")?;
    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": "subagent_task_inspect",
        "scope": scope_ref(&scope),
        "task": inspected_task(&inspection.resource, version, payload),
        "activation": activation_proof(),
        "network": network_proof()
    }))
}

async fn inspect_read_grant(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    operation: &str,
) -> Result<EngineGrant, CapabilityError> {
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("{operation} authority grant was not found")))?;
    require_explicit_grant_item(&grant.allowed_authority_scopes, READ_SCOPE, operation)?;
    require_explicit_grant_item(
        &grant.allowed_authority_scopes,
        RESOURCE_READ_SCOPE,
        operation,
    )?;
    if grant.network_policy != "none" {
        return Err(invalid(format!("{operation} requires networkPolicy none")));
    }
    Ok(grant)
}

fn require_read_kind_selector(grant: &EngineGrant, operation: &str) -> Result<(), CapabilityError> {
    require_explicit_grant_item(&grant.allowed_resource_kinds, SUBAGENT_TASK_KIND, operation)?;
    require_explicit_subagent_task_selector(&grant.resource_selectors, operation)
}

fn require_explicit_subagent_task_selector(
    selectors: &[String],
    operation: &str,
) -> Result<(), CapabilityError> {
    if let Some(selector) = selectors
        .iter()
        .find(|selector| is_broad_resource_selector(selector))
    {
        return Err(invalid(format!(
            "{operation} rejects broad resource selector {selector}"
        )));
    }
    if !allows_explicit_selector(selectors) {
        return Err(invalid(format!(
            "{operation} requires an explicit kind:{SUBAGENT_TASK_KIND} selector"
        )));
    }
    Ok(())
}

fn require_explicit_grant_item(
    values: &[String],
    required: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    if values.iter().any(|value| value == "*") {
        return Err(invalid(format!("{operation} rejects wildcard grants")));
    }
    if !values.iter().any(|value| value == required) {
        return Err(invalid(format!(
            "{operation} requires explicit {required} grant"
        )));
    }
    Ok(())
}

fn allows_explicit_selector(values: &[String]) -> bool {
    values
        .iter()
        .any(|selector| selector == &format!("kind:{SUBAGENT_TASK_KIND}"))
}

fn is_broad_resource_selector(selector: &str) -> bool {
    let trimmed = selector.trim();
    trimmed == "*"
        || trimmed == "kind:*"
        || trimmed == "resource:*"
        || trimmed == "kind:"
        || trimmed == "resource:"
        || trimmed.ends_with(":*")
}

fn ensure_scope(
    inspection: &EngineResourceInspection,
    expected: &EngineResourceScope,
    operation: &str,
) -> Result<(), CapabilityError> {
    if &inspection.resource.scope != expected {
        return Err(invalid(format!(
            "{operation} cannot inspect a subagent task outside the current scope"
        )));
    }
    Ok(())
}

fn ensure_subagent_task(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    if inspection.resource.kind != SUBAGENT_TASK_KIND {
        return Err(invalid(format!(
            "{operation} expected {SUBAGENT_TASK_KIND}"
        )));
    }
    if inspection.resource.schema_id.as_str() != SUBAGENT_TASK_SCHEMA_ID {
        return Err(invalid(format!(
            "{operation} expected schema {SUBAGENT_TASK_SCHEMA_ID}"
        )));
    }
    Ok(())
}

fn current_payload<'a>(
    inspection: &'a EngineResourceInspection,
    operation: &str,
) -> Result<(&'a EngineResourceVersion, &'a Value), CapabilityError> {
    let current = inspection
        .resource
        .current_version_id
        .as_deref()
        .ok_or_else(|| invalid(format!("{operation} resource has no current version")))?;
    let version = inspection
        .versions
        .iter()
        .find(|version| version.version_id == current)
        .ok_or_else(|| invalid(format!("{operation} current version is missing")))?;
    Ok((version, &version.payload))
}

fn scope_record(scope: &EngineResourceScope) -> Value {
    json!({"kind": scope.kind(), "value": scope.value()})
}

fn scope_ref(scope: &EngineResourceScope) -> Value {
    scope_record(scope)
}

fn activation_proof() -> Value {
    json!({
        "performed": false,
        "subagentStarted": false,
        "workerStarted": false,
        "jobStarted": false,
        "catalogRegistration": false,
        "toolExecution": false,
        "resultMerged": false
    })
}

fn network_proof() -> Value {
    json!({"performed": false, "requiredPolicy": "none"})
}

fn engine_error(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn subagent_task_selector_gate_rejects_broad_selectors_mixed_with_exact_kind() {
        for (selector, expected) in [
            ("*", "broad resource selector *"),
            ("kind:*", "broad resource selector kind:*"),
            ("resource:*", "broad resource selector resource:*"),
        ] {
            let selectors = vec![selector.to_owned(), "kind:subagent_task".to_owned()];
            let error = require_explicit_subagent_task_selector(&selectors, "selector_test")
                .expect_err("broad selector denied")
                .to_string();
            assert!(error.contains(expected), "{error}");
        }
    }

    #[test]
    fn subagent_task_selector_gate_preserves_exact_non_wildcard_kind_behavior() {
        let exact = vec!["kind:subagent_task".to_owned()];
        require_explicit_subagent_task_selector(&exact, "selector_test")
            .expect("exact kind selector accepted");

        let missing = vec!["resource:subagent_task:other".to_owned()];
        let error = require_explicit_subagent_task_selector(&missing, "selector_test")
            .expect_err("exact kind selector required")
            .to_string();
        assert!(error.contains("kind:subagent_task"), "{error}");
    }
}
