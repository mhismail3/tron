use super::support::*;

use std::sync::{
    Arc, Mutex, MutexGuard,
    atomic::{AtomicUsize, Ordering},
};

use async_trait::async_trait;
use tokio::time::{Duration, sleep, timeout};

use crate::domains::capability::Deps;
use crate::domains::capability::embeddings::HashEmbeddingProvider;
use crate::domains::capability::registry::open_capability_registry_store;
use crate::engine::{
    ActorKind, ApprovalStatus, AuthorityRequirement, CompensationContract, CompensationKind,
    EffectClass, EngineApprovalRecord, EngineError, EngineHostHandle, IdempotencyContract,
    InProcessFunctionHandler, Invocation, Result as EngineResult, RiskLevel, VisibilityScope,
    WorkerDefinition, WorkerId, WorkerKind,
};

struct SettingsModeGuard {
    _guard: MutexGuard<'static, ()>,
}

impl Drop for SettingsModeGuard {
    fn drop(&mut self) {
        crate::domains::settings::reset_settings();
    }
}

fn set_approval_prompt_mode(
    mode: crate::domains::settings::AutonomyApprovalPromptMode,
) -> SettingsModeGuard {
    let guard = crate::domains::settings::test_settings_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let mut settings = crate::domains::settings::TronSettings::default();
    settings.agent.autonomy.approval_prompt_mode = mode;
    crate::domains::settings::init_settings(settings);
    SettingsModeGuard { _guard: guard }
}

#[tokio::test]
async fn approval_required_execute_auto_decides_without_prompt_in_product_mode() {
    let _settings =
        set_approval_prompt_mode(crate::domains::settings::AutonomyApprovalPromptMode::Disabled);
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let captured = Arc::new(Mutex::new(Vec::new()));
    let calls = Arc::new(AtomicUsize::new(0));
    let expected_implementation = "first_party.danger.v1.write";
    handle
        .register_worker_for_setup(
            WorkerDefinition::new(
                WorkerId::new("danger").unwrap(),
                WorkerKind::InProcess,
                ActorId::new("owner").unwrap(),
                AuthorityGrantId::new("grant").unwrap(),
            )
            .with_namespace_claim("danger"),
            false,
        )
        .unwrap();
    handle
        .register_function_for_setup(
            approval_gated_function(),
            Some(Arc::new(CausalCaptureHandler {
                calls: Arc::clone(&calls),
                invocations: Arc::clone(&captured),
            })),
            false,
        )
        .unwrap();

    let deps = test_deps(handle.clone());
    let execute_invocation = Invocation::new_sync(
        FunctionId::new("capability::execute").unwrap(),
        json!({
            "target": "danger::write",
            "operation": "run",
            "arguments": {"value": 9},
            "idempotencyKey": "auto-child-key"
        }),
        CausalContext::new(
            ActorId::new("agent-auto").unwrap(),
            ActorKind::Agent,
            AuthorityGrantId::new("grant").unwrap(),
            TraceId::new("trace-auto-execute").unwrap(),
        )
        .with_session_id("session-auto")
        .with_workspace_id("workspace-auto")
        .with_scope("capability.execute")
        .with_scope("danger.write")
        .with_scope("contract.allow:*")
        .with_scope("contract.allow:danger::write")
        .with_scope("implementation.allow:*")
        .with_scope(format!("implementation.allow:{expected_implementation}"))
        .with_scope("plugin.allow:*")
        .with_scope("plugin.allow:first_party.danger"),
    );
    let execute_invocation_id = execute_invocation.id.clone();
    let execute_trace = execute_invocation.causal_context.trace_id.clone();

    let execute_value = timeout(
        Duration::from_secs(5),
        execute_value(&execute_invocation, &deps),
    )
    .await
    .expect("auto-decided execute should not wait for an approval prompt")
    .expect("execute should return a capability result");
    let result: CapabilityResult = serde_json::from_value(execute_value).unwrap();
    let details = result.details.unwrap();
    assert_eq!(details["status"], "ok");
    assert_eq!(details["traceId"], execute_trace.as_str());
    assert_eq!(details["rootInvocationId"], execute_invocation_id.as_str());
    assert_eq!(details["approvalRequired"], true);
    assert_eq!(details["approvalCreated"], true);
    assert_eq!(details["approvalExecuted"], true);
    assert_eq!(details["approvalState"]["status"], "executed");
    assert_eq!(details["approvalState"]["traceId"], execute_trace.as_str());
    assert_eq!(details["approvalState"]["idempotencyKey"], "auto-child-key");
    assert_eq!(details["childInvocationCreated"], true);

    let approvals = handle
        .list_approvals(None, Some("session-auto"), 10)
        .await
        .unwrap();
    assert_eq!(approvals.len(), 1);
    let approval = &approvals[0];
    assert_eq!(approval.status, ApprovalStatus::Executed);
    assert_eq!(
        approval
            .decision_actor_id
            .as_ref()
            .map(|actor| actor.as_str()),
        Some("system")
    );
    assert_eq!(
        handle
            .list_approvals(Some(ApprovalStatus::Pending), Some("session-auto"), 10)
            .await
            .unwrap(),
        Vec::<EngineApprovalRecord>::new()
    );

    let invocation_records = handle.invocation_records().await;
    assert!(
        invocation_records
            .iter()
            .all(|record| record.function_id.as_str() != "approval::resolve"),
        "product-mode auto decision must not route through manual approval resolution: {invocation_records:?}"
    );

    let captured_invocations = captured.lock().unwrap();
    assert_eq!(captured_invocations.len(), 1);
    let child = &captured_invocations[0];
    assert_eq!(child.function_id, FunctionId::new("danger::write").unwrap());
    assert_eq!(child.causal_context.trace_id, execute_trace);
    assert_eq!(
        child.causal_context.parent_invocation_id.as_ref(),
        Some(&execute_invocation_id)
    );
    assert_eq!(
        child.causal_context.session_id.as_deref(),
        Some("session-auto")
    );
    assert_eq!(
        child.causal_context.workspace_id.as_deref(),
        Some("workspace-auto")
    );
    assert_eq!(
        child.causal_context.idempotency_key.as_deref(),
        Some("auto-child-key")
    );
    assert!(
        child
            .causal_context
            .authority_scopes
            .iter()
            .any(|scope| scope == "approval.auto_decision")
    );
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn approval_required_execute_resumes_child_with_original_causal_context() {
    let _settings =
        set_approval_prompt_mode(crate::domains::settings::AutonomyApprovalPromptMode::Testing);
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let captured = Arc::new(Mutex::new(Vec::new()));
    let calls = Arc::new(AtomicUsize::new(0));
    let function = approval_gated_function();
    let expected_implementation = "first_party.danger.v1.write";
    handle
        .register_worker_for_setup(
            WorkerDefinition::new(
                WorkerId::new("danger").unwrap(),
                WorkerKind::InProcess,
                ActorId::new("owner").unwrap(),
                AuthorityGrantId::new("grant").unwrap(),
            )
            .with_namespace_claim("danger"),
            false,
        )
        .unwrap();
    handle
        .register_function_for_setup(
            function,
            Some(Arc::new(CausalCaptureHandler {
                calls: Arc::clone(&calls),
                invocations: Arc::clone(&captured),
            })),
            false,
        )
        .unwrap();

    let deps = test_deps(handle.clone());
    let execute_invocation = Invocation::new_sync(
        FunctionId::new("capability::execute").unwrap(),
        json!({
            "target": "danger::write",
            "operation": "run",
            "arguments": {"value": 1},
            "idempotencyKey": "hmh-f2-child-key"
        }),
        CausalContext::new(
            ActorId::new("agent-f2").unwrap(),
            ActorKind::Agent,
            AuthorityGrantId::new("grant").unwrap(),
            TraceId::new("trace-hmh-f2-execute").unwrap(),
        )
        .with_session_id("session-f2")
        .with_workspace_id("workspace-f2")
        .with_scope("capability.execute")
        .with_scope("danger.write")
        .with_scope("contract.allow:*")
        .with_scope("contract.allow:danger::write")
        .with_scope("implementation.allow:*")
        .with_scope(format!("implementation.allow:{expected_implementation}"))
        .with_scope("plugin.allow:*")
        .with_scope("plugin.allow:first_party.danger"),
    );
    let execute_invocation_id = execute_invocation.id.clone();
    let execute_trace = execute_invocation.causal_context.trace_id.clone();
    let execute_grant = execute_invocation.causal_context.authority_grant_id.clone();

    let execute_task = tokio::spawn({
        let deps = deps.clone();
        let invocation = execute_invocation.clone();
        async move { execute_value(&invocation, &deps).await }
    });

    let pending = match wait_for_pending_approval(&handle).await {
        Some(approval) => approval,
        None => {
            let result = timeout(Duration::from_secs(1), execute_task)
                .await
                .expect("execute should have returned when no approval was created")
                .expect("execute task should not panic");
            panic!("approval-required execute did not create a pending approval: {result:?}");
        }
    };
    assert_eq!(pending.status, ApprovalStatus::Pending);
    assert_eq!(
        pending.function_id,
        FunctionId::new("danger::write").unwrap()
    );
    assert_eq!(pending.trace_id, execute_trace);
    assert_eq!(
        pending.parent_invocation_id.as_ref(),
        Some(&execute_invocation_id)
    );
    assert_eq!(pending.authority_grant_id, execute_grant);
    assert_eq!(pending.session_id.as_deref(), Some("session-f2"));
    assert_eq!(pending.workspace_id.as_deref(), Some("workspace-f2"));
    assert_eq!(pending.idempotency_key.as_deref(), Some("hmh-f2-child-key"));
    assert!(
        pending
            .authority_scopes
            .iter()
            .any(|scope| scope == "danger.write")
    );

    let agent_rejected = handle
        .invoke(host_invocation(
            "approval::resolve",
            json!({"approvalId": pending.approval_id, "decision": "approve"}),
            CausalContext::new(
                ActorId::new("agent-f2").unwrap(),
                ActorKind::Agent,
                AuthorityGrantId::new("grant").unwrap(),
                TraceId::new("trace-hmh-f2-agent-resolve").unwrap(),
            )
            .with_scope("approval.resolve")
            .with_idempotency_key("hmh-f2-agent-resolve-key"),
        ))
        .await;
    assert!(
        matches!(
            agent_rejected.error,
            Some(EngineError::PolicyViolation(ref message))
                if message.contains("admin, system, or user-authorized actor")
        ),
        "agent self-resolution should fail before changing approval state: {agent_rejected:?}"
    );
    assert_eq!(
        handle
            .get_approval(&pending.approval_id)
            .await
            .unwrap()
            .unwrap()
            .status,
        ApprovalStatus::Pending
    );

    let user_resolved = handle
        .invoke(host_invocation(
            "engine::invoke",
            json!({
                "functionId": "approval::resolve",
                "payload": {"approvalId": pending.approval_id, "decision": "approve"},
                "idempotencyKey": "hmh-f2-user-resolve-key"
            }),
            CausalContext::new(
                ActorId::new("engine-user").unwrap(),
                ActorKind::User,
                AuthorityGrantId::new("grant").unwrap(),
                TraceId::new("trace-hmh-f2-user-resolve").unwrap(),
            )
            .with_scope("approval.resolve")
            .with_session_id("session-f2"),
        ))
        .await;
    assert_eq!(user_resolved.error, None);
    assert_eq!(
        user_resolved.value.as_ref().unwrap()["child"]["value"]["approval"]["status"],
        "executed",
        "user resolve should execute the approved child: {user_resolved:?}"
    );

    let execute_value = timeout(Duration::from_secs(5), execute_task)
        .await
        .expect("execute should finish after approval resolution")
        .expect("execute task should not panic")
        .expect("execute should return a capability result");
    let result: CapabilityResult = serde_json::from_value(execute_value).unwrap();
    let details = result.details.unwrap();
    assert_eq!(details["status"], "ok");
    assert_eq!(details["traceId"], execute_trace.as_str());
    assert_eq!(details["rootInvocationId"], execute_invocation_id.as_str());
    assert_eq!(details["approvalRequired"], true);
    assert_eq!(details["approvalExecuted"], true);
    assert_eq!(details["approvalState"]["approvalId"], pending.approval_id);
    assert_eq!(details["approvalState"]["traceId"], execute_trace.as_str());
    assert_eq!(
        details["approvalState"]["idempotencyKey"],
        "hmh-f2-child-key"
    );
    assert_eq!(
        details["orchestration"]["executeInvocationId"],
        execute_invocation_id.as_str()
    );

    let captured_invocations = captured.lock().unwrap();
    assert_eq!(captured_invocations.len(), 1);
    let child = &captured_invocations[0];
    assert_eq!(child.function_id, FunctionId::new("danger::write").unwrap());
    assert_eq!(child.causal_context.trace_id, execute_trace);
    assert_eq!(
        child.causal_context.parent_invocation_id.as_ref(),
        Some(&execute_invocation_id)
    );
    assert_eq!(child.causal_context.authority_grant_id, execute_grant);
    assert_eq!(
        child.causal_context.session_id.as_deref(),
        Some("session-f2")
    );
    assert_eq!(
        child.causal_context.workspace_id.as_deref(),
        Some("workspace-f2")
    );
    assert_eq!(
        child.causal_context.idempotency_key.as_deref(),
        Some("hmh-f2-child-key")
    );

    let child_record = handle
        .invocation_records()
        .await
        .into_iter()
        .find(|record| {
            record.function_id.as_str() == "danger::write"
                && record.parent_invocation_id.as_ref() == Some(&execute_invocation_id)
                && record.trace_id == execute_trace
        })
        .expect("resumed child invocation should be recorded under the original execute context");
    assert_eq!(child_record.authority_grant_id, execute_grant);
    assert_eq!(child_record.session_id.as_deref(), Some("session-f2"));
    assert_eq!(child_record.workspace_id.as_deref(), Some("workspace-f2"));
    assert_eq!(
        child_record.idempotency_key.as_deref(),
        Some("hmh-f2-child-key")
    );
    assert!(child_record.succeeded);

    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

fn approval_gated_function() -> FunctionDefinition {
    FunctionDefinition::new(
        FunctionId::new("danger::write").unwrap(),
        WorkerId::new("danger").unwrap(),
        "approval-gated write",
        VisibilityScope::Agent,
        EffectClass::IrreversibleSideEffect,
    )
    .with_required_authority(AuthorityRequirement::scope("danger.write").with_approval_required())
    .with_risk(RiskLevel::High)
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_compensation(CompensationContract::new(
        CompensationKind::ManualOnly,
        "HMH-F2 test write is manually compensated",
    ))
    .with_request_schema(json!({
        "type": "object",
        "required": ["value"],
        "additionalProperties": false,
        "properties": {"value": {"type": "integer"}}
    }))
}

fn test_deps(handle: EngineHostHandle) -> Deps {
    let home = crate::shared::server::test_support::unique_tron_home();
    Deps {
        engine_host: handle,
        registry_store: open_capability_registry_store(None).unwrap(),
        embedding_provider: Arc::new(HashEmbeddingProvider::new(64)),
        profile_runtime: crate::shared::server::test_support::test_profile_runtime(&home),
    }
}

async fn wait_for_pending_approval(handle: &EngineHostHandle) -> Option<EngineApprovalRecord> {
    for _ in 0..80 {
        let approvals = handle
            .list_approvals(Some(ApprovalStatus::Pending), Some("session-f2"), 10)
            .await
            .unwrap();
        if let Some(approval) = approvals.into_iter().next() {
            return Some(approval);
        }
        sleep(Duration::from_millis(25)).await;
    }
    None
}

fn host_invocation(function_id: &str, payload: Value, context: CausalContext) -> Invocation {
    Invocation::new_sync(FunctionId::new(function_id).unwrap(), payload, context)
}

#[derive(Clone)]
struct CausalCaptureHandler {
    calls: Arc<AtomicUsize>,
    invocations: Arc<Mutex<Vec<Invocation>>>,
}

#[async_trait]
impl InProcessFunctionHandler for CausalCaptureHandler {
    async fn invoke(&self, invocation: Invocation) -> EngineResult<Value> {
        let call = self.calls.fetch_add(1, Ordering::SeqCst) + 1;
        self.invocations.lock().unwrap().push(invocation.clone());
        Ok(json!({
            "call": call,
            "payload": invocation.payload,
            "traceId": invocation.causal_context.trace_id.as_str(),
            "parentInvocationId": invocation
                .causal_context
                .parent_invocation_id
                .as_ref()
                .map(|id| id.as_str()),
            "idempotencyKey": invocation.causal_context.idempotency_key,
        }))
    }
}
