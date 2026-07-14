use serde_json::Value;

use crate::engine::{
    ActorKind, EngineGrant, EngineHostHandle, Invocation, RiskLevel,
    is_bootstrap_authority_grant_id,
};
use crate::shared::server::errors::CapabilityError;

use super::operation_contract::InvocationScope;
use super::{internal, operation_contract};

pub(super) async fn validate_execute_authority(
    invocation: &Invocation,
    operation: &str,
    engine_host: &EngineHostHandle,
) -> Result<(), CapabilityError> {
    let grant = validate_execute_identity(invocation, operation, engine_host).await?;
    let required_risk = operation_risk_level(operation)?;
    if grant.max_risk < required_risk {
        return Err(invalid(format!(
            "capability::execute grant risk is below the canonical {operation} risk"
        )));
    }
    let policy = operation_contract::authority_policy(operation)
        .ok_or_else(|| invalid(format!("{operation} has no canonical authority policy")))?;
    for required_scope in policy.base_scope_additions() {
        if !grant
            .allowed_authority_scopes
            .iter()
            .any(|scope| scope == required_scope)
        {
            return Err(invalid(format!(
                "capability::execute grant does not allow canonical {operation} scope {required_scope}"
            )));
        }
    }
    for required_kind in policy.resource_kind_policy().base_kinds() {
        if !grant
            .allowed_resource_kinds
            .iter()
            .any(|kind| kind == required_kind)
        {
            return Err(invalid(format!(
                "capability::execute grant does not allow canonical {operation} resource kind {required_kind}"
            )));
        }
        let required_selector = format!("kind:{required_kind}");
        if !grant
            .resource_selectors
            .iter()
            .any(|selector| selector == &required_selector)
        {
            return Err(invalid(format!(
                "capability::execute grant does not select canonical {operation} resource kind {required_kind}"
            )));
        }
    }
    let required_network_policy = policy.network_policy().as_str();
    if grant.network_policy != required_network_policy {
        return Err(invalid(format!(
            "capability::execute grant requires canonical {operation} networkPolicy {required_network_policy}"
        )));
    }
    Ok(())
}

pub(super) async fn validate_execute_identity(
    invocation: &Invocation,
    operation: &str,
    engine_host: &EngineHostHandle,
) -> Result<EngineGrant, CapabilityError> {
    validate_execute_context(invocation, operation)?;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .map_err(|error| internal(format!("inspect capability execute grant: {error}")))?
        .ok_or_else(|| invalid("capability::execute authority grant was not found"))?;
    let claimed_operation = grant
        .provenance
        .get("operation")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| invalid("capability::execute grant requires an exact operation claim"))?;
    if claimed_operation != operation {
        return Err(invalid(
            "capability::execute grant operation claim does not match the requested operation",
        ));
    }
    Ok(grant)
}

fn validate_execute_context(
    invocation: &Invocation,
    operation: &str,
) -> Result<(), CapabilityError> {
    match invocation.causal_context.actor_kind {
        ActorKind::Agent => {
            let session_id = invocation
                .causal_context
                .session_id
                .as_deref()
                .ok_or_else(|| invalid("capability::execute agent context requires session id"))?;
            let expected_actor = format!("agent:{session_id}");
            if invocation.causal_context.actor_id.as_str() != expected_actor {
                return Err(invalid(
                    "capability::execute agent actor must match the current session",
                ));
            }
        }
        ActorKind::System => {}
        _ => {
            return Err(invalid(
                "capability::execute requires a trusted agent or system runtime context",
            ));
        }
    }
    if is_bootstrap_authority_grant_id(&invocation.causal_context.authority_grant_id) {
        return Err(invalid(
            "capability::execute requires a derived least-privilege authority grant",
        ));
    }
    match operation_contract::invocation_scope(operation) {
        InvocationScope::None => {}
        InvocationScope::CurrentSession => require_current_session(invocation, operation)?,
        InvocationScope::SessionOrWorkspace => require_session_or_workspace(invocation, operation)?,
    }
    match operation {
        "state_get" | "state_set" | "state_list" => validate_state_scope(invocation),
        _ => Ok(()),
    }
}

fn operation_risk_level(operation: &str) -> Result<RiskLevel, CapabilityError> {
    match operation_contract::risk(operation) {
        Some("low") => Ok(RiskLevel::Low),
        Some("medium") => Ok(RiskLevel::Medium),
        Some("high") => Ok(RiskLevel::High),
        Some(other) => Err(invalid(format!(
            "{operation} has unsupported canonical risk {other}"
        ))),
        None => Err(invalid(format!("{operation} has no canonical risk policy"))),
    }
}

fn require_session_or_workspace(
    invocation: &Invocation,
    operation: &str,
) -> Result<(), CapabilityError> {
    if invocation.causal_context.session_id.is_none()
        && invocation.causal_context.workspace_id.is_none()
    {
        return Err(invalid(format!(
            "{operation} requires trusted current session or workspace context"
        )));
    }
    Ok(())
}

fn validate_state_scope(invocation: &Invocation) -> Result<(), CapabilityError> {
    match optional_str(&invocation.payload, "scope")?.unwrap_or("session") {
        "session" => require_current_session(invocation, "state operation"),
        "workspace" => {
            if invocation.causal_context.workspace_id.is_none() {
                return Err(invalid(
                    "workspace state requires trusted workspace context",
                ));
            }
            Ok(())
        }
        "system" => Err(invalid(
            "capability::execute cannot read or write system-scoped state",
        )),
        other => Err(invalid(format!("unsupported execute state scope {other}"))),
    }
}

fn require_current_session(
    invocation: &Invocation,
    operation: &str,
) -> Result<(), CapabilityError> {
    if invocation.causal_context.session_id.is_none() {
        return Err(invalid(format!(
            "{operation} requires trusted current session context"
        )));
    }
    Ok(())
}

fn optional_str<'a>(payload: &'a Value, field: &str) -> Result<Option<&'a str>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value)),
        Some(_) => Err(invalid(format!("{field} must be a string"))),
    }
}

fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}

#[cfg(test)]
mod tests {
    use chrono::Utc;
    use serde_json::json;

    use super::*;
    use crate::domains::capability::Deps;
    use crate::domains::session::event_store::AgentTraceListOptions;
    use crate::engine::{
        ActorId, AuthorityGrantId, CausalContext, DeliveryMode, DeriveGrant, FunctionId,
        InvocationId, RUNTIME_METADATA_WORKING_DIRECTORY, TraceId,
    };
    use crate::shared::server::test_support::make_test_context;

    const WRITE_SCOPES: &[&str] = &[
        "capability.execute",
        "filesystem.read",
        "filesystem.write",
        "resource.read",
        "resource.write",
    ];
    const WRITE_KINDS: &[&str] = &["patch_proposal", "materialized_file"];
    const WRITE_SELECTORS: &[&str] = &["kind:patch_proposal", "kind:materialized_file"];

    struct GrantCase {
        id: &'static str,
        operation: &'static str,
        max_risk: RiskLevel,
        scopes: &'static [&'static str],
        kinds: &'static [&'static str],
        selectors: &'static [&'static str],
        network: &'static str,
        expected_error: &'static str,
    }

    async fn derive_grant(
        engine_host: &EngineHostHandle,
        actor_id: &ActorId,
        root: &str,
        case: &GrantCase,
    ) -> AuthorityGrantId {
        engine_host
            .derive_authority_grant(DeriveGrant {
                grant_id: Some(AuthorityGrantId::new(case.id).expect("grant id")),
                parent_grant_id: AuthorityGrantId::new("agent-capability-runtime")
                    .expect("parent grant"),
                subject_actor_id: Some(actor_id.clone()),
                subject_worker_id: None,
                subject_invocation_id: None,
                allowed_capabilities: vec!["capability::execute".to_owned()],
                allowed_namespaces: vec!["__no_namespace_authority__".to_owned()],
                allowed_authority_scopes: case
                    .scopes
                    .iter()
                    .map(|value| (*value).to_owned())
                    .collect(),
                allowed_resource_kinds: case
                    .kinds
                    .iter()
                    .map(|value| (*value).to_owned())
                    .collect(),
                resource_selectors: case
                    .selectors
                    .iter()
                    .map(|value| (*value).to_owned())
                    .collect(),
                file_roots: vec![root.to_owned()],
                network_policy: case.network.to_owned(),
                max_risk: case.max_risk,
                budget: json!({"remainingInvocations": 3}),
                expires_at: None,
                can_delegate: false,
                provenance: json!({
                    "source": "operation-authority-test",
                    "operation": case.operation
                }),
                trace_id: TraceId::new(format!("trace-{}", case.id)).expect("trace id"),
            })
            .await
            .expect("derive execute grant")
            .grant_id
    }

    #[tokio::test]
    async fn invalid_operation_authority_cannot_write_files_or_trace_payloads() {
        let ctx = make_test_context();
        let deps = Deps {
            engine_host: ctx.engine_host.clone(),
            event_store: ctx.event_store.clone(),
            session_manager: ctx.session_manager.clone(),
            shutdown_coordinator: ctx.shutdown_coordinator.clone(),
            jobs_reconcile: crate::domains::jobs::service::ReconcileContext {
                startup_cutoff: Utc::now(),
            },
            apns_runtime: crate::platform::apns::ApnsRuntime::disabled_for_test(),
        };
        let workspace = tempfile::tempdir().expect("workspace");
        let created = ctx
            .event_store
            .create_session(
                "gpt-5.5",
                workspace.path().to_str().expect("workspace path"),
                Some("operation authority"),
                Some("openai"),
            )
            .expect("create session");
        let actor_id =
            ActorId::new(format!("agent:{}", created.session.id)).expect("agent actor id");
        let root = workspace.path().to_str().expect("workspace path");
        let cases = [
            GrantCase {
                id: "observe-grant",
                operation: "observe",
                max_risk: RiskLevel::High,
                scopes: WRITE_SCOPES,
                kinds: WRITE_KINDS,
                selectors: WRITE_SELECTORS,
                network: "none",
                expected_error: "operation claim",
            },
            GrantCase {
                id: "rejection-grant",
                operation: "definitely_not_a_real_operation",
                max_risk: RiskLevel::Medium,
                scopes: &["capability.execute"],
                kinds: &[],
                selectors: &[],
                network: "none",
                expected_error: "operation claim",
            },
            GrantCase {
                id: "under-risk-grant",
                operation: "filesystem_write",
                max_risk: RiskLevel::Medium,
                scopes: WRITE_SCOPES,
                kinds: WRITE_KINDS,
                selectors: WRITE_SELECTORS,
                network: "none",
                expected_error: "canonical filesystem_write risk",
            },
            GrantCase {
                id: "under-scoped-grant",
                operation: "filesystem_write",
                max_risk: RiskLevel::High,
                scopes: &[
                    "capability.execute",
                    "filesystem.read",
                    "resource.read",
                    "resource.write",
                ],
                kinds: WRITE_KINDS,
                selectors: WRITE_SELECTORS,
                network: "none",
                expected_error: "canonical filesystem_write scope",
            },
            GrantCase {
                id: "under-resourced-grant",
                operation: "filesystem_write",
                max_risk: RiskLevel::High,
                scopes: WRITE_SCOPES,
                kinds: &["materialized_file"],
                selectors: WRITE_SELECTORS,
                network: "none",
                expected_error: "resource kind patch_proposal",
            },
            GrantCase {
                id: "under-selected-grant",
                operation: "filesystem_write",
                max_risk: RiskLevel::High,
                scopes: WRITE_SCOPES,
                kinds: WRITE_KINDS,
                selectors: &["kind:materialized_file"],
                network: "none",
                expected_error: "select canonical filesystem_write resource kind patch_proposal",
            },
            GrantCase {
                id: "wrong-network-grant",
                operation: "filesystem_write",
                max_risk: RiskLevel::High,
                scopes: WRITE_SCOPES,
                kinds: WRITE_KINDS,
                selectors: WRITE_SELECTORS,
                network: "declared",
                expected_error: "canonical filesystem_write networkPolicy none",
            },
        ];

        for (index, case) in cases.iter().enumerate() {
            let grant_id = derive_grant(&ctx.engine_host, &actor_id, root, case).await;
            let target = workspace.path().join(format!("forbidden-{index}.txt"));
            let invocation = Invocation {
                id: InvocationId::new(format!("operation-authority-invocation-{index}"))
                    .expect("invocation id"),
                function_id: FunctionId::new("capability::execute").expect("function id"),
                delivery_mode: DeliveryMode::Sync,
                payload: json!({
                    "operation": "filesystem_write",
                    "path": target.file_name().expect("file name").to_str().expect("file name"),
                    "content": "must not enter a file or trace",
                    "commit": true,
                    "reason": "prove operation authority precedes every mutation",
                    "idempotencyKey": format!("operation-authority-{index}")
                }),
                causal_context: CausalContext::new(
                    actor_id.clone(),
                    ActorKind::Agent,
                    grant_id,
                    TraceId::new(format!("operation-authority-trace-{index}")).expect("trace id"),
                )
                .with_session_id(created.session.id.clone())
                .with_workspace_id(created.session.workspace_id.clone())
                .with_idempotency_key(format!("operation-authority-{index}"))
                .with_runtime_metadata(RUNTIME_METADATA_WORKING_DIRECTORY, root),
            };

            let error = super::super::execute_value(&invocation, &deps)
                .await
                .expect_err("underprivileged operation must fail")
                .to_string();
            assert!(
                error.contains(case.expected_error),
                "unexpected error: {error}"
            );
            assert!(!target.exists(), "rejected operation wrote {target:?}");
        }

        let other = ctx
            .event_store
            .create_session(
                "gpt-5.5",
                workspace.path().to_str().expect("workspace path"),
                Some("other session"),
                Some("openai"),
            )
            .expect("create other session");
        let cross_session_case = GrantCase {
            id: "cross-session-grant",
            operation: "filesystem_write",
            max_risk: RiskLevel::High,
            scopes: WRITE_SCOPES,
            kinds: WRITE_KINDS,
            selectors: WRITE_SELECTORS,
            network: "none",
            expected_error: "agent actor must match the current session",
        };
        let cross_session_grant =
            derive_grant(&ctx.engine_host, &actor_id, root, &cross_session_case).await;
        let cross_session_target = workspace.path().join("cross-session.txt");
        let cross_session_invocation = Invocation {
            id: InvocationId::new("cross-session-authority-invocation").expect("invocation id"),
            function_id: FunctionId::new("capability::execute").expect("function id"),
            delivery_mode: DeliveryMode::Sync,
            payload: json!({
                "operation": "filesystem_write",
                "path": "cross-session.txt",
                "content": "must not enter another session trace",
                "commit": true,
                "idempotencyKey": "cross-session-authority"
            }),
            causal_context: CausalContext::new(
                actor_id,
                ActorKind::Agent,
                cross_session_grant,
                TraceId::new("cross-session-authority-trace").expect("trace id"),
            )
            .with_session_id(other.session.id.clone())
            .with_workspace_id(other.session.workspace_id.clone())
            .with_idempotency_key("cross-session-authority")
            .with_runtime_metadata(RUNTIME_METADATA_WORKING_DIRECTORY, root),
        };
        let error = super::super::execute_value(&cross_session_invocation, &deps)
            .await
            .expect_err("cross-session actor must fail before tracing")
            .to_string();
        assert!(error.contains(cross_session_case.expected_error), "{error}");
        assert!(!cross_session_target.exists());

        let records = ctx
            .event_store
            .list_trace_records(&AgentTraceListOptions {
                session_id: Some(&created.session.id),
                trace_id: None,
                operation: None,
                status: None,
                limit: Some(20),
            })
            .expect("list rejected traces");
        assert!(records.is_empty(), "authority denial persisted trace data");
        let other_records = ctx
            .event_store
            .list_trace_records(&AgentTraceListOptions {
                session_id: Some(&other.session.id),
                trace_id: None,
                operation: None,
                status: None,
                limit: Some(20),
            })
            .expect("list cross-session traces");
        assert!(
            other_records.is_empty(),
            "cross-session denial persisted trace data"
        );
    }
}
