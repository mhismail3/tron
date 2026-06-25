use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, EngineHostHandle, FunctionId, Invocation,
    TraceId,
};
use crate::shared::server::error_mapping::engine_error_to_failure;
use crate::shared::server::failure::{
    CAPABILITY_RESULT_INVALID, ENGINE_POLICY_VIOLATION, FailureCategory, FailureEnvelope,
    FailureOrigin,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

#[allow(clippy::too_many_arguments)]
pub(super) async fn derive_capability_runtime_grant(
    engine_host: &EngineHostHandle,
    actor_id: &ActorId,
    target_function_id: &FunctionId,
    target_authority_scopes: &[String],
    session_id: &str,
    workspace_id: Option<&str>,
    working_directory: &str,
    trace_id: &TraceId,
    invocation_id: &str,
    model_primitive_name: &str,
    turn: i64,
    run_id: Option<&str>,
    effective_args: &Value,
) -> Result<AuthorityGrantId, FailureEnvelope> {
    let operation = effective_args
        .get("operation")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let notification_push_requested = operation == "notification_send"
        && effective_args
            .get("pushRequested")
            .and_then(Value::as_bool)
            .unwrap_or(false);
    let web_fetch_uses_robots_policy = operation == "web_fetch"
        && has_non_empty_string(effective_args, "webRobotsPolicyResourceId")
        && has_non_empty_string(effective_args, "expectedWebRobotsPolicyVersionId");
    let mut allowed_capabilities = vec![
        target_function_id.as_str().to_owned(),
        "state::get".to_owned(),
        "state::set".to_owned(),
        "state::list".to_owned(),
    ];
    allowed_capabilities.sort();
    allowed_capabilities.dedup();
    let mut allowed_authority_scopes = target_authority_scopes.to_vec();
    allowed_authority_scopes.extend(["state.read".to_owned(), "state.write".to_owned()]);
    if operation == "web_fetch" {
        allowed_authority_scopes.extend(["resource.write".to_owned(), "web.write".to_owned()]);
        if web_fetch_uses_robots_policy {
            allowed_authority_scopes.extend(["resource.read".to_owned(), "web.read".to_owned()]);
        }
    } else if operation == "web_robots_check" {
        allowed_authority_scopes.extend([
            "resource.read".to_owned(),
            "resource.write".to_owned(),
            "web.write".to_owned(),
        ]);
    } else if matches!(operation, "web_source_list" | "web_source_inspect") {
        allowed_authority_scopes.extend(["resource.read".to_owned(), "web.read".to_owned()]);
    } else if operation == "web_source_archive" {
        allowed_authority_scopes.extend([
            "resource.read".to_owned(),
            "resource.write".to_owned(),
            "web.read".to_owned(),
            "web.write".to_owned(),
        ]);
    } else if matches!(operation, "media_list" | "media_inspect") {
        allowed_authority_scopes.extend(["media.read".to_owned(), "resource.read".to_owned()]);
    } else if matches!(operation, "media_create" | "media_archive") {
        allowed_authority_scopes.extend([
            "media.read".to_owned(),
            "media.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if matches!(operation, "worker_package_list" | "worker_package_inspect") {
        allowed_authority_scopes.extend([
            "worker.lifecycle.read".to_owned(),
            "resource.read".to_owned(),
        ]);
    } else if matches!(
        operation,
        "procedural_state_list" | "procedural_state_inspect"
    ) {
        allowed_authority_scopes.extend(["procedural.read".to_owned(), "resource.read".to_owned()]);
    } else if matches!(
        operation,
        "subagent_status" | "subagent_result" | "subagent_task_list" | "subagent_task_inspect"
    ) {
        allowed_authority_scopes.extend(["subagents.read".to_owned(), "resource.read".to_owned()]);
    } else if matches!(operation, "subagent_launch" | "subagent_cancel") {
        allowed_authority_scopes.extend([
            "subagents.read".to_owned(),
            "subagents.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
    } else if matches!(operation, "device_list" | "device_inspect") {
        allowed_authority_scopes.extend(["device.read".to_owned(), "resource.read".to_owned()]);
    } else if matches!(operation, "notification_list" | "notification_inspect") {
        allowed_authority_scopes
            .extend(["notifications.read".to_owned(), "resource.read".to_owned()]);
    } else if matches!(
        operation,
        "notification_send" | "notification_mark_read" | "notification_mark_all_read"
    ) {
        allowed_authority_scopes.extend([
            "notifications.read".to_owned(),
            "notifications.write".to_owned(),
            "resource.read".to_owned(),
            "resource.write".to_owned(),
        ]);
        if notification_push_requested {
            allowed_authority_scopes.push("device.read".to_owned());
        }
    }
    allowed_authority_scopes.sort();
    allowed_authority_scopes.dedup();
    let network_policy = if matches!(operation, "web_fetch" | "web_robots_check") {
        "declared"
    } else {
        "none"
    };
    let mut allowed_resource_kinds = vec!["agent_state".to_owned()];
    if operation == "web_robots_check" {
        allowed_resource_kinds.push("web_robots_policy".to_owned());
    } else if matches!(
        operation,
        "web_fetch" | "web_source_list" | "web_source_inspect" | "web_source_archive"
    ) {
        allowed_resource_kinds.push("web_source".to_owned());
        if web_fetch_uses_robots_policy {
            allowed_resource_kinds.push("web_robots_policy".to_owned());
        }
    } else if matches!(
        operation,
        "media_create" | "media_list" | "media_inspect" | "media_archive"
    ) {
        allowed_resource_kinds.push("media_artifact".to_owned());
    } else if operation == "worker_package_list" {
        if let Some(kind) = worker_package_list_kind(effective_args) {
            allowed_resource_kinds.push(kind.to_owned());
        }
    } else if operation == "worker_package_inspect"
        && let Some(kind) = worker_package_inspect_kind(effective_args)
    {
        allowed_resource_kinds.push(kind.to_owned());
    } else if matches!(
        operation,
        "subagent_launch"
            | "subagent_status"
            | "subagent_result"
            | "subagent_cancel"
            | "subagent_task_list"
            | "subagent_task_inspect"
    ) {
        allowed_resource_kinds.push("subagent_task".to_owned());
    } else if matches!(
        operation,
        "procedural_state_list" | "procedural_state_inspect"
    ) && procedural_kind(effective_args).is_some()
    {
        allowed_resource_kinds.push("procedural_record".to_owned());
    } else if matches!(operation, "device_list" | "device_inspect") {
        allowed_resource_kinds.push("device_registration".to_owned());
    } else if operation == "notification_list" {
        allowed_resource_kinds.push("notification".to_owned());
    } else if operation == "notification_inspect" {
        allowed_resource_kinds.extend([
            "notification".to_owned(),
            "notification_delivery".to_owned(),
        ]);
    } else if matches!(
        operation,
        "notification_send" | "notification_mark_read" | "notification_mark_all_read"
    ) {
        allowed_resource_kinds.extend([
            "notification".to_owned(),
            "notification_delivery".to_owned(),
        ]);
        if notification_push_requested {
            allowed_resource_kinds.push("device_registration".to_owned());
        }
    }
    let mut resource_selectors = allowed_resource_kinds
        .iter()
        .map(|kind| format!("kind:{kind}"))
        .collect::<Vec<_>>();
    if matches!(operation, "media_inspect" | "media_archive")
        && let Some(resource_id) = effective_args
            .get("mediaResourceId")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
    {
        resource_selectors.push(format!("resource:{resource_id}"));
    }
    if matches!(
        operation,
        "procedural_state_list" | "procedural_state_inspect"
    ) && let Some(kind) = procedural_kind(effective_args)
    {
        resource_selectors.push(format!("proceduralKind:{kind}"));
    }
    let idempotency_material = json!({
        "version": 1,
        "sessionId": session_id,
        "workspaceId": workspace_id,
        "workingDirectory": working_directory,
        "actorId": actor_id.as_str(),
        "targetFunctionId": target_function_id.as_str(),
        "targetAuthorityScopes": target_authority_scopes,
        "providerInvocationId": invocation_id,
        "modelPrimitiveName": model_primitive_name,
        "operation": operation,
        "turn": turn,
        "runId": run_id
    });
    let idempotency_key = format!(
        "capability-runtime-grant:v1:{}",
        sha256_hex(
            serde_json::to_string(&idempotency_material)
                .unwrap_or_else(|_| "{}".to_owned())
                .as_bytes()
        )
    );
    let derive_context = CausalContext::new(
        ActorId::new("system:capability-runtime")
            .map_err(|error| engine_error_to_failure(&error))?,
        ActorKind::System,
        AuthorityGrantId::new("grant").map_err(|error| engine_error_to_failure(&error))?,
        trace_id.clone(),
    )
    .with_scope("grant.write")
    .with_session_id(session_id.to_owned())
    .with_idempotency_key(idempotency_key);
    let payload = json!({
        "parentGrantId": "agent-capability-runtime",
        "subjectActorId": actor_id.as_str(),
        "allowedCapabilities": allowed_capabilities,
        "allowedNamespaces": ["__no_namespace_authority__"],
        "allowedAuthorityScopes": allowed_authority_scopes,
        "allowedResourceKinds": allowed_resource_kinds,
        "resourceSelectors": resource_selectors,
        "fileRoots": [working_directory],
        "networkPolicy": network_policy,
        "maxRisk": "medium",
        "budget": {
            "remainingInvocations": 2,
            "remainingProcessMs": 120000
        },
        "canDelegate": false,
        "provenance": {
            "source": "agent.capability_runtime",
            "sessionId": session_id,
            "workspaceId": workspace_id,
            "targetFunctionId": target_function_id.as_str(),
            "providerInvocationId": invocation_id,
            "modelPrimitiveName": model_primitive_name,
            "operation": operation,
            "turn": turn,
            "runId": run_id,
            "workingDirectory": working_directory,
            "networkPolicy": network_policy
        }
    });
    let result = engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("grant::derive").map_err(|error| engine_error_to_failure(&error))?,
            payload,
            derive_context,
        ))
        .await;
    if let Some(error) = result.error {
        return Err(engine_error_to_failure(&error));
    }
    let value = result.value.ok_or_else(|| {
        FailureEnvelope::new(
            ENGINE_POLICY_VIOLATION,
            FailureCategory::Engine,
            "Capability runtime grant derivation returned no value",
            false,
            false,
            FailureOrigin::Engine,
        )
    })?;
    let grant_id = value
        .get("grant")
        .and_then(|grant| grant.get("grantId"))
        .and_then(Value::as_str)
        .ok_or_else(|| {
            FailureEnvelope::new(
                CAPABILITY_RESULT_INVALID,
                FailureCategory::Parse,
                "Capability runtime grant derivation returned an invalid grant payload",
                false,
                false,
                FailureOrigin::Engine,
            )
        })?;
    AuthorityGrantId::new(grant_id.to_owned()).map_err(|error| engine_error_to_failure(&error))
}

fn has_non_empty_string(value: &Value, field: &str) -> bool {
    value
        .get(field)
        .and_then(Value::as_str)
        .is_some_and(|item| !item.trim().is_empty())
}

fn procedural_kind(args: &Value) -> Option<&'static str> {
    match args.get("proceduralKind").and_then(Value::as_str) {
        Some("skill") => Some("skill"),
        Some("rule") => Some("rule"),
        Some("hook") => Some("hook"),
        Some("procedure") => Some("procedure"),
        _ => None,
    }
}

fn worker_package_list_kind(args: &Value) -> Option<&'static str> {
    match args
        .get("workerPackageKind")
        .and_then(Value::as_str)
        .unwrap_or("worker_package")
    {
        "worker_package" => Some("worker_package"),
        "worker_package_installation" => Some("worker_package_installation"),
        "worker_package_proposal" => Some("worker_package_proposal"),
        "worker_package_conformance_report" => Some("worker_package_conformance_report"),
        "worker_launch_attempt" => Some("worker_launch_attempt"),
        _ => None,
    }
}

fn worker_package_inspect_kind(args: &Value) -> Option<&'static str> {
    let resource_id = args
        .get("workerPackageResourceId")
        .and_then(Value::as_str)?;
    if resource_id.starts_with("worker_package_installation:") {
        Some("worker_package_installation")
    } else if resource_id.starts_with("worker_package_proposal:") {
        Some("worker_package_proposal")
    } else if resource_id.starts_with("worker_package_conformance_report:") {
        Some("worker_package_conformance_report")
    } else if resource_id.starts_with("worker_launch_attempt:") {
        Some("worker_launch_attempt")
    } else if resource_id.starts_with("worker_package:") {
        Some("worker_package")
    } else {
        None
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) fn stable_capability_invocation_material(
    run_id: Option<&str>,
    session_id: &str,
    turn: i64,
    invocation_id: &str,
    model_primitive_name: &str,
    working_directory: &str,
    workspace_id: Option<&str>,
    effective_args: &Value,
) -> String {
    let payload = json!({
        "runId": run_id,
        "sessionId": session_id,
        "turn": turn,
        "providerCallId": invocation_id,
        "modelPrimitiveName": model_primitive_name,
        "workingDirectory": working_directory,
        "workspaceId": workspace_id,
        "arguments": effective_args
    });
    serde_json::to_string(&payload).unwrap_or_else(|_| {
        format!(
            "{run_id:?}:{session_id}:{turn}:{invocation_id}:{model_primitive_name}:{working_directory}:{workspace_id:?}:{effective_args}",
        )
    })
}

#[allow(clippy::too_many_arguments)]
pub(super) fn model_capability_invocation_idempotency_key(
    run_id: Option<&str>,
    session_id: &str,
    turn: i64,
    invocation_id: &str,
    model_primitive_name: &str,
    working_directory: &str,
    workspace_id: Option<&str>,
    effective_args: &Value,
) -> String {
    let material = stable_capability_invocation_material(
        run_id,
        session_id,
        turn,
        invocation_id,
        model_primitive_name,
        working_directory,
        workspace_id,
        effective_args,
    );
    format!(
        "model-capability-invocation:v1:{}",
        sha256_hex(material.as_bytes())
    )
}

pub(super) fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}
