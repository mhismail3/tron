use crate::domains::capability::{
    AuthorityPolicy, ConditionalAuthority, ResourceKindPolicy, SelectorAddition,
    WorkerPackageKindSource, authority_policy, operation_risk,
};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, EngineHostHandle, FunctionId, Invocation,
    SUBAGENT_TASK_KIND, TraceId,
};
use crate::shared::server::error_mapping::engine_error_to_failure;
use crate::shared::server::failure::{
    CAPABILITY_RESULT_INVALID, ENGINE_POLICY_VIOLATION, FailureCategory, FailureEnvelope,
    FailureOrigin,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

pub(super) struct CapabilityRuntimeGrant {
    pub(super) grant_id: AuthorityGrantId,
    pub(super) authority_scopes: Vec<String>,
}

struct ResolvedRuntimeAuthority {
    allowed_capabilities: Vec<String>,
    allowed_authority_scopes: Vec<String>,
    allowed_resource_kinds: Vec<String>,
    resource_selectors: Vec<String>,
    network_policy: &'static str,
}

#[derive(Default)]
struct DynamicAuthorityState {
    web_robots_proof: bool,
    notification_push: bool,
}

struct RuntimeResolutionContext<'a> {
    engine_host: &'a EngineHostHandle,
    session_id: &'a str,
    workspace_id: Option<&'a str>,
    working_directory: &'a str,
    invocation_id: &'a str,
    model_primitive_name: &'a str,
    turn: i64,
    run_id: Option<&'a str>,
    args: &'a Value,
}

type AuthorityResult<T> = Result<T, Box<FailureEnvelope>>;

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
) -> Result<CapabilityRuntimeGrant, FailureEnvelope> {
    let operation = effective_args
        .get("operation")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| *invalid_authority_request("unknown", "operation is required"))?;
    let policy = authority_policy(operation);
    let resolution_context = RuntimeResolutionContext {
        engine_host,
        session_id,
        workspace_id,
        working_directory,
        invocation_id,
        model_primitive_name,
        turn,
        run_id,
        args: effective_args,
    };
    let (resolved, operation_risk) = match policy {
        Some(policy) => {
            let operation_risk = operation_risk(operation).ok_or_else(|| {
                FailureEnvelope::new(
                    ENGINE_POLICY_VIOLATION,
                    FailureCategory::Engine,
                    "Capability runtime authority has no canonical risk for the requested operation",
                    false,
                    false,
                    FailureOrigin::Engine,
                )
            })?;
            let resolved = resolve_runtime_authority(
                policy,
                operation,
                target_function_id,
                target_authority_scopes,
                &resolution_context,
            )
            .await
            .map_err(|failure| *failure)?;
            (resolved, operation_risk)
        }
        None => (
            rejected_operation_authority(target_function_id, target_authority_scopes)
                .map_err(|failure| *failure)?,
            "low",
        ),
    };
    let grant_max_risk = match operation_risk {
        "high" | "critical" => operation_risk,
        _ => "medium",
    };

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
        sha256_hex(idempotency_material.to_string().as_bytes())
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
        "allowedCapabilities": resolved.allowed_capabilities,
        "allowedNamespaces": ["__no_namespace_authority__"],
        "allowedAuthorityScopes": resolved.allowed_authority_scopes,
        "allowedResourceKinds": resolved.allowed_resource_kinds,
        "resourceSelectors": resolved.resource_selectors,
        "fileRoots": [working_directory],
        "networkPolicy": resolved.network_policy,
        "maxRisk": grant_max_risk,
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
            "operationRisk": operation_risk,
            "turn": turn,
            "runId": run_id,
            "workingDirectory": working_directory,
            "networkPolicy": resolved.network_policy
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
    let grant_id = AuthorityGrantId::new(grant_id.to_owned())
        .map_err(|error| engine_error_to_failure(&error))?;
    Ok(CapabilityRuntimeGrant {
        grant_id,
        authority_scopes: resolved.allowed_authority_scopes,
    })
}

fn rejected_operation_authority(
    target_function_id: &FunctionId,
    target_authority_scopes: &[String],
) -> AuthorityResult<ResolvedRuntimeAuthority> {
    if target_function_id.as_str() != "capability::execute"
        || target_authority_scopes != ["capability.execute"]
    {
        return Err(Box::new(FailureEnvelope::new(
            ENGINE_POLICY_VIOLATION,
            FailureCategory::Engine,
            "Unsupported operations can only receive the rejection-only capability execute authority",
            false,
            false,
            FailureOrigin::Engine,
        )));
    }
    Ok(ResolvedRuntimeAuthority {
        allowed_capabilities: vec!["capability::execute".to_owned()],
        allowed_authority_scopes: vec!["capability.execute".to_owned()],
        allowed_resource_kinds: Vec::new(),
        resource_selectors: Vec::new(),
        network_policy: "none",
    })
}

async fn resolve_runtime_authority(
    policy: AuthorityPolicy,
    operation: &str,
    target_function_id: &FunctionId,
    target_authority_scopes: &[String],
    context: &RuntimeResolutionContext<'_>,
) -> AuthorityResult<ResolvedRuntimeAuthority> {
    let mut allowed_capabilities = vec![target_function_id.as_str().to_owned()];
    allowed_capabilities.extend(
        policy
            .capability_additions()
            .iter()
            .map(|value| (*value).to_owned()),
    );

    let mut allowed_authority_scopes = target_authority_scopes.to_vec();
    allowed_authority_scopes.extend(
        policy
            .base_scope_additions()
            .iter()
            .map(|value| (*value).to_owned()),
    );

    let resource_policy = policy.resource_kind_policy();
    let mut allowed_resource_kinds = resource_policy
        .base_kinds()
        .iter()
        .map(|value| (*value).to_owned())
        .collect::<Vec<_>>();

    let dynamic_authority = apply_conditional_authority(
        policy.conditional_authority(),
        operation,
        context.args,
        &mut allowed_authority_scopes,
        &mut allowed_resource_kinds,
    )?;
    resolve_dynamic_resource_kinds(
        resource_policy,
        operation,
        context.args,
        &dynamic_authority,
        &mut allowed_resource_kinds,
    )?;

    allowed_capabilities.sort();
    allowed_capabilities.dedup();
    allowed_authority_scopes.sort();
    allowed_authority_scopes.dedup();
    allowed_resource_kinds.sort();
    allowed_resource_kinds.dedup();

    let mut resource_selectors = allowed_resource_kinds
        .iter()
        .map(|kind| format!("kind:{kind}"))
        .collect::<Vec<_>>();
    for field in policy.exact_resource_id_fields() {
        if let Some(resource_id) = optional_non_empty_string(context.args, field, operation)? {
            push_resource_selector(&mut resource_selectors, resource_id, operation)?;
        }
    }
    if let Some(arguments) = context.args.as_object() {
        for (field, value) in arguments {
            if !(field.ends_with("ResourceId") || field.ends_with("ResourceRef")) {
                continue;
            }
            if let Some(resource_id) = value.as_str() {
                push_resource_selector(&mut resource_selectors, resource_id, operation)?;
            }
        }
    }
    apply_selector_additions(
        policy.selector_additions(),
        operation,
        context,
        &mut resource_selectors,
    )
    .await?;
    resource_selectors.sort();
    resource_selectors.dedup();

    if resource_selectors
        .iter()
        .any(|selector| selector == "*" || selector.ends_with(":*"))
    {
        return Err(invalid_authority_request(
            operation,
            "wildcard resource selectors are not allowed",
        ));
    }

    Ok(ResolvedRuntimeAuthority {
        allowed_capabilities,
        allowed_authority_scopes,
        allowed_resource_kinds,
        resource_selectors,
        network_policy: policy.network_policy().as_str(),
    })
}

fn apply_conditional_authority(
    authority: ConditionalAuthority,
    operation: &str,
    args: &Value,
    scopes: &mut Vec<String>,
    resource_kinds: &mut Vec<String>,
) -> AuthorityResult<DynamicAuthorityState> {
    let mut state = DynamicAuthorityState::default();
    match authority {
        ConditionalAuthority::None => {}
        ConditionalAuthority::WebRobotsProof {
            resource_id_field,
            version_id_field,
            additional_scopes,
        } => {
            if web_robots_proof(args, resource_id_field, version_id_field, operation)?.is_some() {
                scopes.extend(additional_scopes.iter().map(|value| (*value).to_owned()));
                state.web_robots_proof = true;
            }
        }
        ConditionalAuthority::NotificationPush {
            requested_field,
            additional_scopes,
            additional_resource_kind,
        } => {
            if optional_bool(args, requested_field, operation)? {
                scopes.extend(additional_scopes.iter().map(|value| (*value).to_owned()));
                resource_kinds.push(additional_resource_kind.to_owned());
                state.notification_push = true;
            }
        }
    }
    Ok(state)
}

fn resolve_dynamic_resource_kinds(
    policy: ResourceKindPolicy,
    operation: &str,
    args: &Value,
    dynamic_authority: &DynamicAuthorityState,
    resource_kinds: &mut Vec<String>,
) -> AuthorityResult<()> {
    match policy {
        ResourceKindPolicy::None
        | ResourceKindPolicy::Static(_)
        | ResourceKindPolicy::CapabilityRouteUnion
        | ResourceKindPolicy::CapabilityBinding(_)
        | ResourceKindPolicy::ModuleRuntime(_)
        | ResourceKindPolicy::ModuleProgramExecution(_)
        | ResourceKindPolicy::Subagent(_) => {}
        ResourceKindPolicy::OptionalGoal {
            field, linked_kind, ..
        } => {
            if optional_non_empty_string(args, field, operation)?.is_some() {
                resource_kinds.push(linked_kind.to_owned());
            }
        }
        ResourceKindPolicy::WebFetchRobotsProof { proof_kind, .. } => {
            if dynamic_authority.web_robots_proof {
                resource_kinds.push(proof_kind.to_owned());
            }
        }
        ResourceKindPolicy::NotificationPush { push_kind, .. } => {
            if dynamic_authority.notification_push {
                resource_kinds.push(push_kind.to_owned());
            }
        }
        ResourceKindPolicy::Procedural {
            kind_field,
            resources,
        } => {
            procedural_kind(args, kind_field, operation)?;
            resource_kinds.extend(
                resources
                    .resource_kinds()
                    .iter()
                    .map(|value| (*value).to_owned()),
            );
        }
        ResourceKindPolicy::WorkerPackage(source) => {
            let kind = worker_package_kind(args, source, operation)?;
            if !source.allowed_resource_kinds().contains(&kind) {
                return Err(invalid_authority_field(operation, "workerPackageKind"));
            }
            resource_kinds.push(kind.to_owned());
        }
    }
    Ok(())
}

async fn apply_selector_additions(
    additions: &[SelectorAddition],
    operation: &str,
    context: &RuntimeResolutionContext<'_>,
    selectors: &mut Vec<String>,
) -> AuthorityResult<()> {
    for addition in additions {
        match *addition {
            SelectorAddition::Session => {
                selectors.push(format!("session:{}", context.session_id));
            }
            SelectorAddition::WebRobotsProof {
                resource_id_field,
                version_id_field,
            } => {
                if let Some(resource_id) =
                    web_robots_proof(context.args, resource_id_field, version_id_field, operation)?
                {
                    push_resource_selector(selectors, resource_id, operation)?;
                }
            }
            SelectorAddition::ProceduralKind { field } => {
                let kind = procedural_kind(context.args, field, operation)?;
                selectors.push(format!("proceduralKind:{kind}"));
            }
            SelectorAddition::DerivedModuleLifecycleState {
                install_decision_field,
            } => {
                if let Some(resource_id) =
                    optional_non_empty_string(context.args, install_decision_field, operation)?
                {
                    push_resource_selector(
                        selectors,
                        &module_lifecycle_state_resource_id(context.session_id, resource_id),
                        operation,
                    )?;
                }
            }
            SelectorAddition::DerivedModuleRuntimeState {
                lifecycle_field,
                request_id_field,
                idempotency_field,
            } => push_module_runtime_state_selector(
                selectors,
                context.session_id,
                context.args,
                lifecycle_field,
                request_id_field,
                idempotency_field,
                operation,
            )?,
            SelectorAddition::DerivedSubagentTask { task_id_field } => {
                push_subagent_launch_selector(selectors, context, task_id_field, operation)?;
            }
            SelectorAddition::DelegatedSubagentResources {
                task_resource_field,
            } => {
                push_delegated_subagent_followup_selectors(
                    context.engine_host,
                    selectors,
                    context.args,
                    task_resource_field,
                    operation,
                )
                .await?;
            }
        }
    }
    Ok(())
}

fn web_robots_proof<'a>(
    args: &'a Value,
    resource_id_field: &str,
    version_id_field: &str,
    operation: &str,
) -> AuthorityResult<Option<&'a str>> {
    let resource_id = optional_non_empty_string(args, resource_id_field, operation)?;
    let version_id = optional_non_empty_string(args, version_id_field, operation)?;
    match (resource_id, version_id) {
        (None, None) => Ok(None),
        (Some(resource_id), Some(_)) => Ok(Some(resource_id)),
        _ => Err(invalid_authority_request(
            operation,
            "robots policy resource and version proof must be supplied together",
        )),
    }
}

fn optional_bool(args: &Value, field: &str, operation: &str) -> AuthorityResult<bool> {
    match args.get(field) {
        None | Some(Value::Null) => Ok(false),
        Some(Value::Bool(value)) => Ok(*value),
        Some(_) => Err(invalid_authority_field(operation, field)),
    }
}

fn optional_non_empty_string<'a>(
    args: &'a Value,
    field: &str,
    operation: &str,
) -> AuthorityResult<Option<&'a str>> {
    match args.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if !value.trim().is_empty() => Ok(Some(value)),
        Some(_) => Err(invalid_authority_field(operation, field)),
    }
}

fn procedural_kind<'a>(
    args: &'a Value,
    field: &str,
    operation: &str,
) -> AuthorityResult<&'static str> {
    match optional_non_empty_string(args, field, operation)? {
        Some("skill") => Ok("skill"),
        Some("rule") => Ok("rule"),
        Some("hook") => Ok("hook"),
        Some("procedure") => Ok("procedure"),
        _ => Err(invalid_authority_field(operation, field)),
    }
}

fn worker_package_kind(
    args: &Value,
    source: WorkerPackageKindSource,
    operation: &str,
) -> AuthorityResult<&'static str> {
    match source {
        WorkerPackageKindSource::ListArgument { field } => {
            match optional_non_empty_string(args, field, operation)? {
                None | Some("worker_package") => Ok("worker_package"),
                Some("worker_package_installation") => Ok("worker_package_installation"),
                Some("worker_package_proposal") => Ok("worker_package_proposal"),
                Some("worker_package_conformance_report") => {
                    Ok("worker_package_conformance_report")
                }
                Some("worker_launch_attempt") => Ok("worker_launch_attempt"),
                Some(_) => Err(invalid_authority_field(operation, field)),
            }
        }
        WorkerPackageKindSource::InspectResourceIdPrefix { field } => {
            let resource_id = optional_non_empty_string(args, field, operation)?
                .ok_or_else(|| invalid_authority_field(operation, field))?;
            if resource_id.starts_with("worker_package_installation:") {
                Ok("worker_package_installation")
            } else if resource_id.starts_with("worker_package_proposal:") {
                Ok("worker_package_proposal")
            } else if resource_id.starts_with("worker_package_conformance_report:") {
                Ok("worker_package_conformance_report")
            } else if resource_id.starts_with("worker_launch_attempt:") {
                Ok("worker_launch_attempt")
            } else if resource_id.starts_with("worker_package:") {
                Ok("worker_package")
            } else {
                Err(invalid_authority_field(operation, field))
            }
        }
    }
}

fn push_resource_selector(
    selectors: &mut Vec<String>,
    resource_id: &str,
    operation: &str,
) -> AuthorityResult<()> {
    if resource_id.trim().is_empty() || resource_id.contains('*') {
        return Err(invalid_authority_request(
            operation,
            "resource identifiers must be exact and non-empty",
        ));
    }
    selectors.push(format!("resource:{resource_id}"));
    Ok(())
}

fn push_module_runtime_state_selector(
    selectors: &mut Vec<String>,
    session_id: &str,
    args: &Value,
    lifecycle_field: &str,
    request_id_field: &str,
    idempotency_field: &str,
    operation: &str,
) -> AuthorityResult<()> {
    let Some(lifecycle_resource_id) = optional_non_empty_string(args, lifecycle_field, operation)?
    else {
        return Ok(());
    };
    let runtime_request_id = optional_non_empty_string(args, request_id_field, operation)?
        .or(optional_non_empty_string(
            args,
            idempotency_field,
            operation,
        )?)
        .unwrap_or("runtime");
    push_resource_selector(
        selectors,
        &module_runtime_state_resource_id(session_id, lifecycle_resource_id, runtime_request_id),
        operation,
    )
}

fn push_subagent_launch_selector(
    selectors: &mut Vec<String>,
    context: &RuntimeResolutionContext<'_>,
    task_id_field: &str,
    operation: &str,
) -> AuthorityResult<()> {
    let task_id = optional_non_empty_string(context.args, task_id_field, operation)?
        .unwrap_or(context.invocation_id);
    let idempotency_key = model_capability_invocation_idempotency_key(
        context.run_id,
        context.session_id,
        context.turn,
        context.invocation_id,
        context.model_primitive_name,
        context.working_directory,
        context.workspace_id,
        context.args,
    );
    push_resource_selector(
        selectors,
        &subagent_task_resource_id(context.session_id, task_id, &idempotency_key),
        operation,
    )
}

async fn push_delegated_subagent_followup_selectors(
    engine_host: &EngineHostHandle,
    selectors: &mut Vec<String>,
    args: &Value,
    task_resource_field: &str,
    operation: &str,
) -> AuthorityResult<()> {
    let Some(resource_id) = optional_non_empty_string(args, task_resource_field, operation)? else {
        return Ok(());
    };
    let Some(inspection) = engine_host
        .inspect_resource(resource_id)
        .await
        .map_err(|error| engine_error_to_failure(&error))?
    else {
        return Ok(());
    };
    if inspection.resource.kind != SUBAGENT_TASK_KIND {
        return Ok(());
    }
    let Some(payload) = inspection
        .versions
        .iter()
        .find(|version| {
            inspection
                .resource
                .current_version_id
                .as_ref()
                .is_some_and(|current| current == &version.version_id)
        })
        .or_else(|| inspection.versions.last())
        .map(|version| &version.payload)
    else {
        return Ok(());
    };
    for pointer in [
        "/delegation/moduleRuntimeResourceId",
        "/delegation/jobResourceId",
        "/delegation/programExecutionResourceId",
    ] {
        if let Some(resource_id) = payload
            .pointer(pointer)
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
        {
            push_resource_selector(selectors, resource_id, operation)?;
        }
    }
    Ok(())
}

fn module_lifecycle_state_resource_id(
    session_id: &str,
    install_decision_resource_id: &str,
) -> String {
    format!(
        "module_lifecycle_state:{}",
        sha256_hex(format!("session:{session_id}:{install_decision_resource_id}").as_bytes())
    )
}

fn module_runtime_state_resource_id(
    session_id: &str,
    lifecycle_resource_id: &str,
    runtime_request_id: &str,
) -> String {
    format!(
        "module_runtime_state:{}",
        sha256_hex(
            format!("session:{session_id}:{lifecycle_resource_id}:{runtime_request_id}").as_bytes()
        )
    )
}

fn subagent_task_resource_id(session_id: &str, task_id: &str, idempotency_key: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"session");
    hasher.update(b":");
    hasher.update(session_id.as_bytes());
    hasher.update(b":");
    hasher.update(task_id.as_bytes());
    hasher.update(b":");
    hasher.update(idempotency_key.as_bytes());
    format!("subagent_task:{:x}", hasher.finalize())
}

fn invalid_authority_field(operation: &str, field: &str) -> Box<FailureEnvelope> {
    invalid_authority_request(
        operation,
        &format!("authority field '{field}' is missing or invalid"),
    )
}

fn invalid_authority_request(operation: &str, reason: &str) -> Box<FailureEnvelope> {
    Box::new(FailureEnvelope::new(
        ENGINE_POLICY_VIOLATION,
        FailureCategory::InvalidRequest,
        format!("Capability authority for '{operation}' was rejected: {reason}"),
        false,
        true,
        FailureOrigin::Capability,
    ))
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
    payload.to_string()
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
    if let (Some(operation), Some(caller_key)) = (
        effective_args.get("operation").and_then(Value::as_str),
        effective_args.get("idempotencyKey").and_then(Value::as_str),
    ) {
        let material = json!({
            "version": 1,
            "sessionId": session_id,
            "operation": operation,
            "callerKey": caller_key
        });
        return format!(
            "model-capability-caller-idempotency:v1:{}",
            sha256_hex(material.to_string().as_bytes())
        );
    }
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
